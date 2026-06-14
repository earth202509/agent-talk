function New-AgentTalkFixtureState {
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$AgentVersion = '1.0.0',
        [string]$LastInputText = ''
    )

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-talk-fixture-" + [guid]::NewGuid())
    $stateDir = Join-Path $work 'state'
    $metaDir = Join-Path $stateDir 'meta'
    New-Item -ItemType Directory -Force -Path $metaDir | Out-Null

    $session = [pscustomobject]@{
        session_id = 'pane-fixture'
        app = $App
        agent_version = $AgentVersion
        title = "$App fixture"
        status = 'unknown'
        transport = [pscustomobject]@{
            kind = 'wt-conpty'
            handle = 'pane-fixture'
            pid = 0
            log_path = $LogPath
            meta_path = (Join-Path $metaDir 'pane-fixture.json')
            workspace = 'C:\workspace\practice'
        }
        created_at = '2026-06-08T00:00:00Z'
        updated_at = '2026-06-08T00:00:00Z'
    }
    if ($LastInputText) {
        $session | Add-Member -NotePropertyName last_sent_text -NotePropertyValue $LastInputText -Force
        $session | Add-Member -NotePropertyName last_sent_at -NotePropertyValue '2026-06-08T00:00:01Z' -Force
    }
    @($session) | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $stateDir 'sessions.json')

    return [pscustomobject]@{
        Work = $work
        StateDir = $stateDir
    }
}

function Invoke-AgentTalkFixtureWaitReply {
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [string]$AgentVersion = '1.0.0',
        [string]$LastInputText = ''
    )

    $talkie = Join-Path $RepoRoot 'src\scripts\talkie.ps1'
    $logPath = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-talk-fixture-log-" + [guid]::NewGuid() + '.log')
    $fixture = $null
    $oldStateDir = $env:WT_CONPTY_CC_STATE_DIR
    try {
        Set-Content -Encoding UTF8 -LiteralPath $logPath -Value $Lines
        $fixture = New-AgentTalkFixtureState -App $App -LogPath $logPath -AgentVersion $AgentVersion -LastInputText $LastInputText
        $env:WT_CONPTY_CC_STATE_DIR = $fixture.StateDir
        return ((& $talkie wait-reply pane-fixture 8 2>&1) -join "`n")
    } finally {
        if ($null -ne $oldStateDir) { $env:WT_CONPTY_CC_STATE_DIR = $oldStateDir } else { Remove-Item Env:\WT_CONPTY_CC_STATE_DIR -ErrorAction SilentlyContinue }
        if ($fixture -and (Test-Path -LiteralPath $fixture.Work)) { Remove-Item -LiteralPath $fixture.Work -Recurse -Force }
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
    }
}

Test-Case 'agent-talk current command surface is talkie-only' {
    $scriptDir = Join-Path $RepoRoot 'src\scripts'
    Assert (Test-Path -LiteralPath (Join-Path $scriptDir 'talkie.ps1')) 'talkie.ps1 should exist'
    Assert (Test-Path -LiteralPath (Join-Path $scriptDir 'agents\shared.ps1')) 'agents\shared.ps1 should exist'
    Assert (Test-Path -LiteralPath (Join-Path $scriptDir 'terminals\wt-conpty.ps1')) 'wt-conpty terminal should exist'
    foreach ($legacy in @('spawn_worker.ps1', 'send_to_worker.ps1', 'orchestrate.ps1', 'transport.ps1', 'wt_conpty_cc.ps1')) {
        Assert (-not (Test-Path -LiteralPath (Join-Path $scriptDir $legacy))) "legacy script should not exist: $legacy"
    }
}

Test-Case 'public files avoid machine-specific maintainer paths' {
    $profilePathPattern = ('C:' + '\\Users\\' + '[^\\]+')
    foreach ($relative in @('README.md', 'AGENTS.md', 'scripts\deploy-skills.ps1')) {
        $text = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot $relative)
        Assert (-not ($text -match $profilePathPattern)) "$relative should not contain a maintainer user profile path"
        Assert (-not ($text -match 'D:\\work')) "$relative should not contain a maintainer workspace path"
    }
}

Test-Case 'agent-talk exposes local agent discovery' {
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')
    Assert ($talkieText.Contains("'list-agents'")) 'talkie command validation should include list-agents'
    Assert ($talkieText.Contains('function Invoke-ListAgents')) 'talkie should implement list-agents'
    Assert ($talkieText.Contains('function Get-AgentAdapterRecords')) 'talkie should collect adapter records'
    Assert ($talkieText.Contains('available') -and $talkieText.Contains('compatible')) 'list-agents records should expose availability and compatibility'
    Assert ($talkieText.Contains("throw 'list-agents only supports json output'")) 'list-agents should not expose extra output formats'
}

Test-Case 'agent-talk ignores unrelated adapter load failures during resolution' {
    . (Join-Path $RepoRoot 'src\scripts\agents\shared.ps1')
    $adapterDir = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-talk-adapters-' + [guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Force -Path $adapterDir | Out-Null
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $adapterDir 'broken.ps1') -Value "throw 'unavailable command'"
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $adapterDir 'pi.ps1') -Value @'
param([string]$ExtraArgs)
@{
    App = 'pi'
    Aliases = @()
    AdapterVersion = '1.0.0'
}
'@

        $selection = Resolve-AgentTalkAdapter -AdapterDir $adapterDir -Name 'pi' -AgentVersion '1.0.0'
        Assert ($selection.Adapter.App -eq 'pi') 'resolver should select pi when an unrelated adapter fails to load'
    } finally {
        if (Test-Path -LiteralPath $adapterDir) {
            Remove-Item -LiteralPath $adapterDir -Recurse -Force
        }
    }
}

Test-Case 'agent-talk wait-reply extracts Claude replies with bullet variants' {
    $dash = [string]([char]0x2500) * 80
    $bulletChar = [char]0x25CF
    $promptChar = [char]0x276F
    $lines = @(
        '[conpty] size=100x24',
        'Claude Code v2.1.140',
        'Sonnet 4.6',
        '',
        ($bulletChar + ' I''m running Claude Haiku 4.5 (claude-haiku-4-5-20251001).'),
        '',
        $dash,
        $promptChar,
        $dash,
        '? for shortcuts'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'claude' -Lines $lines -AgentVersion '2.1.140'
    Assert ($text -match 'Claude Haiku 4.5') "wait-reply should keep the Claude reply body: $text"
    Assert ($text -notmatch 'Claude Code v2.1.140') "wait-reply should strip chrome: $text"
    Assert ($text -notmatch 'Sonnet 4.6') "wait-reply should strip model chrome: $text"
    Assert (-not $text.Contains($promptChar)) "wait-reply should strip the prompt line: $text"
}

Test-Case 'agent-talk claude submits with a separate enter key' {
    . (Join-Path $RepoRoot 'src\scripts\agents\shared.ps1')
    $adapter = & (Join-Path $RepoRoot 'src\scripts\agents\claude.ps1') -ExtraArgs ''

    Assert ($adapter.AppendMessageNewline -eq $false) 'claude should not append newline to the message text'
    Assert ($adapter.SubmitSequenceSeparate -eq $true) 'claude should submit with a separate Enter sequence'
    Assert ([int][char]$adapter.SubmitSequence -eq 13) 'claude submit sequence should be carriage return only'
}

Test-Case 'agent-talk send stores last input for wait-reply' {
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')
    Assert ($talkieText.Contains('function Set-SessionLastSentText')) 'talkie should have a helper for last input state'
    Assert ($talkieText.Contains('last_sent_text')) 'talkie should store last_sent_text in session state'
    Assert ($talkieText.Contains('$lastSentText = $message')) 'send should capture decoded text before submit/newline mutation'
    Assert ($talkieText.Contains('Set-SessionLastSentText -PipeName $pipe -Text $lastSentText')) 'send should persist last input after successful terminal send'
    Assert ($talkieText.Contains('$lastInputText = if ($session)')) 'wait-reply should read last input from session state'
    Assert ($talkieText.Contains('Get-ReplyText $text $adapter $lastInputText')) 'wait-reply should pass last input into the adapter'
}

Test-Case 'agent-talk send defaults to bracketed paste' {
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')
    Assert ($talkieText.Contains("`$pasteMode = 'bracketed'")) 'send should default to bracketed paste'
    Assert ($talkieText.Contains("Get-Prop `$adapter 'PasteMode'")) 'send should read adapter paste mode'
    Assert ($talkieText.Contains("'bracketed'")) 'send should support bracketed paste mode'
    Assert ($talkieText.Contains('[200~')) 'send should start bracketed paste before payload'
    Assert ($talkieText.Contains('[201~')) 'send should end bracketed paste after payload'
}

Test-Case 'agent-talk wait-reply keeps default scrollback configurable' {
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')
    Assert ($talkieText.Contains('$scrollbackRows = 400')) 'wait-reply should default to 400 scrollback rows'
    Assert ($talkieText.Contains('AGENT_TALK_SCROLLBACK_ROWS')) 'wait-reply scrollback should remain configurable'
}

Test-Case 'agent-talk wait-reply has a shorter stable idle window than new-session' {
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')
    Assert ($talkieText.Contains('function Get-WaitReplyStableIdleMilliseconds')) 'wait-reply should have its own stable idle helper'
    Assert ($talkieText.Contains('AGENT_TALK_WAIT_REPLY_STABLE_IDLE_MS')) 'wait-reply stable idle window should have its own environment override'
    Assert ($talkieText.Contains('$milliseconds = 1000')) 'wait-reply stable idle default should be short for response collection'
    Assert ($talkieText.Contains('$stableIdleMilliseconds = Get-WaitReplyStableIdleMilliseconds')) 'wait-reply should use its own stable idle helper'
}

Test-Case 'agent-talk new-session creates unique ids' {
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')
    Assert ($talkieText.Contains('function New-SessionId')) 'talkie should create unique session ids'
    Assert ($talkieText.Contains('[guid]::NewGuid()')) 'new session ids should include random entropy'
    Assert ($talkieText.Contains('$pipe = New-SessionId')) 'new-session should not reuse deterministic pipe ids'
    Assert ($talkieText.Contains('function Wait-NewSessionStatus')) 'new-session should wait with status reporting'
    Assert ($talkieText.Contains('Wait-NewSessionStatus -PipeName $pipe')) 'new-session should not lose pane id on non-ready states'
    Assert ($talkieText.Contains('"STATUS=$status"')) 'new-session should report ready/unknown/busy/error status'
    Assert ($talkieText.Contains('function Get-NewSessionStableIdleMilliseconds')) 'new-session should have its own stable idle helper'
    Assert ($talkieText.Contains('AGENT_TALK_STABLE_IDLE_MS')) 'new-session stable idle window should allow environment override'
    Assert ($talkieText.Contains('$milliseconds = 3000')) 'stable idle default should be long enough for startup repaint jitter'
    Assert ($talkieText.Contains('$stableIdleMilliseconds = Get-NewSessionStableIdleMilliseconds')) 'new-session should use its own stable idle helper'
    Assert ($talkieText.Contains("if (`$lastStatus -eq 'error')")) 'new-session should return error immediately without waiting for stability'
}

Test-Case 'agent-talk codex reply uses last input and bullet anchor' {
    $promptChar = [char]0x203A
    $replyBullet = [char]0x2022
    $middleDot = [char]0x00B7
    $lines = @(
        '[conpty] size=100x24',
        ($promptChar + ' hello'),
        '',
        ($replyBullet + ' Hello.'),
        '',
        ($promptChar + ' '),
        ('gpt-5.4-mini medium ' + $middleDot + ' C:\workspace\practice')
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'codex' -Lines $lines -AgentVersion '0.136.0' -LastInputText 'hello'
    Assert ($text -eq 'Hello.') ('codex should extract the bullet reply after last input: ' + $text)
}

Test-Case 'agent-talk codex closes completion popup before submit' {
    . (Join-Path $RepoRoot 'src\scripts\agents\shared.ps1')
    $adapter = & (Join-Path $RepoRoot 'src\scripts\agents\codex.ps1') -ExtraArgs ''
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')

    Assert ($adapter.SubmitSequenceSeparate -eq $true) 'codex should submit with a separate key sequence'
    Assert ([int][char]$adapter.SubmitSequenceParts[0][0] -eq 27) 'codex submit should start with Escape to close slash/model completion'
    Assert ($adapter.SubmitSequenceParts[1] -eq "`r`n") 'codex submit should finish with CRLF'
    Assert ($adapter.SubmitSequencePartDelayMilliseconds -ge 300) 'codex should pause between Escape and Enter'
    Assert ($talkieText.Contains('SubmitSequenceParts')) 'send should support split submit sequences'
    Assert ($talkieText.Contains('SubmitSequencePartDelayMilliseconds')) 'send should support delays between split submit sequences'
}

Test-Case 'agent-talk pi reply uses last input and thinking anchor' {
    $dash = [string]([char]0x2500) * 80
    $lines = @(
        '[conpty] size=100x24',
        'hello',
        'Thinking...',
        'Hello from Pi.',
        '',
        $dash,
        '',
        $dash,
        '? for shortcuts'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'pi' -Lines $lines -AgentVersion '0.78.0' -LastInputText 'hello'
    Assert ($text -eq 'Hello from Pi.') ('pi should extract text after the thinking anchor: ' + $text)
}

Test-Case 'agent-talk pi reply preserves scrolled long replies' {
    $dash = [string]([char]0x2500) * 80
    $lines = @(
        '[conpty] size=80x6',
        'hello',
        'Thinking...',
        'draft line before final spinner',
        'Working...',
        'Final answer line 1.',
        'Final answer line 2.',
        'Final answer line 3.',
        'Final answer line 4.',
        'Final answer line 5.',
        'Final answer line 6.',
        '',
        $dash,
        '',
        $dash,
        '? for shortcuts'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'pi' -Lines $lines -AgentVersion '0.78.0' -LastInputText 'hello'
    Assert ($text -notmatch 'draft line before final spinner') ('pi should use the last busy anchor after input: ' + $text)
    Assert ($text -match 'Final answer line 1\.') ('pi should keep the start of the final scrolled reply: ' + $text)
    Assert ($text -match 'Final answer line 6\.') ('pi should keep the end of the final scrolled reply: ' + $text)
}

Test-Case 'agent-talk pi reply preserves report separators inside replies' {
    $dash = [string]([char]0x2500) * 80
    $lines = @(
        '[conpty] size=100x12',
        'inspect webserver',
        'Thinking...',
        '### One',
        '| name | value |',
        '| ---- | ----- |',
        '| routes | 36 |',
        '',
        $dash,
        '',
        '### Two',
        'Migration notes stay in the same reply.',
        '',
        $dash,
        '',
        $dash,
        '? for shortcuts'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'pi' -Lines $lines -AgentVersion '0.78.0' -LastInputText 'inspect webserver'
    Assert ($text -match '### One') ('pi should keep content before report separators: ' + $text)
    Assert ($text -match 'routes \| 36') ('pi should keep markdown table content before separators: ' + $text)
    Assert ($text -match '### Two') ('pi should keep content after report separators: ' + $text)
}

Test-Case 'agent-talk pi reply falls back to adapter anchor when input echo is missing' {
    $dash = [string]([char]0x2500) * 80
    $lines = @(
        '[conpty] size=100x12',
        'Thinking...',
        'Fallback reply line 1.',
        'Fallback reply line 2.',
        '',
        $dash,
        '',
        $dash,
        '? for shortcuts'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'pi' -Lines $lines -AgentVersion '0.78.0' -LastInputText 'missing prompt'
    $expected = 'Fallback reply line 1.' + ([string][char]10) + 'Fallback reply line 2.'
    Assert ($text -eq $expected) ('pi should use the last adapter anchor when the input echo is missing: ' + $text)
}

Test-Case 'agent-talk pi reply returns empty when input echo and adapter anchor are missing' {
    $dash = [string]([char]0x2500) * 80
    $lines = @(
        '[conpty] size=100x12',
        'Unanchored reply line.',
        '',
        $dash,
        '',
        $dash,
        '? for shortcuts'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'pi' -Lines $lines -AgentVersion '0.78.0' -LastInputText 'missing prompt'
    Assert ($text -eq '') ('pi should not guess a reply when both input echo and adapter anchors are missing: ' + $text)
}

Test-Case 'agent-talk pi submits with a separate enter key' {
    . (Join-Path $RepoRoot 'src\scripts\agents\shared.ps1')
    $adapter = & (Join-Path $RepoRoot 'src\scripts\agents\pi.ps1') -ExtraArgs ''

    Assert ($adapter.AppendMessageNewline -eq $false) 'pi should not append newline to the message text'
    Assert ($adapter.SubmitSequenceSeparate -eq $true) 'pi should submit with a separate Enter sequence'
    Assert ([int][char]$adapter.SubmitSequence -eq 13) 'pi submit sequence should be carriage return only'
}

Test-Case 'agent-talk cleans session artifacts on lifecycle commands' {
    $talkieText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\talkie.ps1')

    Assert ($talkieText.Contains('function Remove-SessionArtifacts')) 'talkie should define per-session artifact cleanup'
    Assert ($talkieText.Contains('function Remove-OrphanSessionArtifacts')) 'talkie should define orphan artifact cleanup'
    Assert ($talkieText.Contains('Remove-SessionArtifacts $session')) 'kill-session should remove the killed session log/meta'
    Assert ($talkieText.Contains('function Invoke-NewSession') -and $talkieText.Contains('Remove-OrphanSessionArtifacts')) 'new-session/list-sessions should clean orphan artifacts'
}

Test-Case 'agent-talk conpty log uses streaming UTF-8 decoder' {
    $shimText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\terminals\wt-conpty-shim.ps1')

    Assert ($shimText.Contains('utf8.GetDecoder()')) 'ConPTY output logging should decode UTF-8 across read boundaries'
    Assert ($shimText.Contains('decoder.GetChars(buffer, 0, n, chars, 0, false)')) 'ConPTY output logging should not call GetString on partial byte chunks'
}

Test-Case 'agent-talk agy reply starts after latest user input and prefers bullet replies' {
    $dash = [string]([char]0x2500) * 80
    $bulletChar = [char]0x25CF
    $lines = @(
        '[conpty] size=120x30',
        '> analyze repo',
        'Running 1 shell command...',
        '  Get-ChildItem -Recurse',
        ($bulletChar + ' Final answer only'),
        'second line',
        '',
        $dash,
        '>',
        $dash,
        '? for shortcuts                  Gemini 3.5 Flash (High)'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'agy' -Lines $lines -AgentVersion '1.0.4' -LastInputText 'analyze repo'
    $expected = 'Final answer only' + ([string][char]10) + 'second line'
    $detail = 'agy should prefer the final bullet reply after the latest input: ' + $text
    Assert ($text -eq $expected) $detail
}

Test-Case 'agent-talk agy reply handles prompt on its own input line' {
    $dash = [string]([char]0x2500) * 80
    $bulletChar = [char]0x25CF
    $lines = @(
        '[conpty] size=160x40',
        '>',
        '  Please check the major global equity market close today,',
        '  including A-shares, Hong Kong, and US markets.',
        '',
        'Thought for 2s, 663 tokens',
        'Gathering Market Data',
        'o WebSearch("Hang Seng close 2026-06-08 up down") (ctrl+o to expand)',
        'Worked.',
        ($bulletChar + ' Markets summary:'),
        'A-shares were mixed, Hong Kong was weak, and US markets were still open.',
        '',
        $dash,
        '>',
        $dash,
        '? for shortcuts                  Gemini 3.5 Flash (High)'
    )
    $lastInput = 'Please check the major global equity market close today, including A-shares, Hong Kong, and US markets.'

    $text = Invoke-AgentTalkFixtureWaitReply -App 'agy' -Lines $lines -AgentVersion '1.0.6' -LastInputText $lastInput
    $expected = 'Markets summary:' + ([string][char]10) + 'A-shares were mixed, Hong Kong was weak, and US markets were still open.'
    Assert ($text -eq $expected) ('agy should scope replies after a split input prompt: ' + $text)
}

Test-Case 'agent-talk agy reply skips visible multiline input echo' {
    $dash = [string]([char]0x2500) * 80
    $lines = @(
        '[conpty] size=120x30',
        '> Please write a long reply using this format:',
        'First line must be START-MULTILINE-ECHO.',
        'Then write items 1 to 3.',
        'Last line must be END-MULTILINE-ECHO.',
        'Do not run commands or edit files.',
        '',
        'START-MULTILINE-ECHO',
        '1. First reply item.',
        '2. Second reply item.',
        '3. Third reply item.',
        'END-MULTILINE-ECHO',
        '',
        $dash,
        '>',
        $dash,
        '? for shortcuts                  Gemini 3.5 Flash (High)'
    )
    $lastInput = @'
Please write a long reply using this format:
First line must be START-MULTILINE-ECHO.
Then write items 1 to 3.
Last line must be END-MULTILINE-ECHO.
Do not run commands or edit files.
'@.Trim()

    $text = Invoke-AgentTalkFixtureWaitReply -App 'agy' -Lines $lines -AgentVersion '1.0.6' -LastInputText $lastInput
    Assert ($text.StartsWith('START-MULTILINE-ECHO')) ('agy should skip all visible input echo lines: ' + $text)
    Assert ($text -notmatch 'First line must be START-MULTILINE-ECHO') ('agy should not include multiline input echo: ' + $text)
    Assert ($text -match 'END-MULTILINE-ECHO') ('agy should keep the complete reply: ' + $text)
}

Test-Case 'agent-talk agy reply keeps plain text when no bullet reply exists' {
    $dash = [string]([char]0x2500) * 80
    $lines = @(
        '[conpty] size=120x30',
        '> say OK',
        '',
        '  OK',
        '',
        $dash,
        '> say hi',
        '',
        '  hi',
        '',
        $dash,
        '>',
        $dash,
        '? for shortcuts                  Gemini 3.5 Flash (High)'
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'agy' -Lines $lines -AgentVersion '1.0.4' -LastInputText 'say hi'
    Assert ($text -eq 'hi') "agy should return the latest plain text reply: $text"
}

Test-Case 'agent-talk agy ready status accepts ascii and heavy prompts' {
    . (Join-Path $RepoRoot 'src\scripts\agents\shared.ps1')
    $adapter = & (Join-Path $RepoRoot 'src\scripts\agents\antigravity.ps1') -ExtraArgs ''
    $dash = [string]([char]0x2500) * 80
    $heavy = [char]0x276F
    $lf = [string][char]10
    $asciiScreen = 'Antigravity CLI 1.0.4' + $lf + $dash + $lf + '>' + $lf + $dash + $lf + '? for shortcuts'
    $heavyScreen = 'Antigravity CLI 1.0.4' + $lf + $dash + $lf + $heavy + $lf + $dash + $lf + '? for shortcuts'

    Assert ((& $adapter.GetStatus $asciiScreen) -eq 'ready') 'agy should treat > prompt as ready'
    Assert ((& $adapter.GetStatus $heavyScreen) -eq 'ready') 'agy should treat heavy prompt as ready'
}

Test-Case 'agent-talk agy adapter skips permission prompts by default' {
    $adapterDir = Join-Path $RepoRoot 'src\scripts\agents'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('aib-agy-cli-' + [guid]::NewGuid())
    $oldPath = $env:PATH
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $tmp 'agy.cmd') -Value '@echo off'
        $env:PATH = $tmp + ';' + $oldPath

        $agy = & (Join-Path $adapterDir 'antigravity.ps1') -ExtraArgs ''
        Assert ($agy.AppendMessageNewline -eq $false) 'agy should not append newline to the message text'
        Assert ($agy.SubmitSequenceSeparate -eq $true) 'agy should submit with a separate Enter sequence'
        Assert ([int][char]$agy.SubmitSequence -eq 13) 'agy submit sequence should be carriage return only'
        Assert ($agy.Args -match '\s-EncodedCommand\s') 'agy adapter should launch via encoded command'
        $encoded = [regex]::Match($agy.Args, '-EncodedCommand\s+(\S+)').Groups[1].Value
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $permissionArg = ([string][char]39) + '--dangerously-skip-permissions' + ([string][char]39)
        Assert ($decoded.Contains($permissionArg)) 'agy adapter should pass --dangerously-skip-permissions by default'
    } finally {
        $env:PATH = $oldPath
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
}

Test-Case 'agent-talk shim leaves Windows Terminal mouse scrolling enabled by default' {
    $shimText = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RepoRoot 'src\scripts\terminals\wt-conpty-shim.ps1')

    Assert ($shimText.Contains('function Close-WindowsTerminalTabByTitle')) 'shim should include tab close helper'
    Assert ($shimText.Contains('function Remove-ConptySessionRecord')) 'shim should remove its transport session on child exit'
    Assert ($shimText.Contains('WT_CONPTY_FORWARD_MOUSE')) 'shim should expose mouse forwarding opt-in'
    $quote = [string][char]34
    $mouseOptInNeedle = 'Environment.GetEnvironmentVariable(' + $quote + 'WT_CONPTY_FORWARD_MOUSE' + $quote + ') == ' + $quote + '1' + $quote
    Assert ($shimText.Contains($mouseOptInNeedle)) 'mouse forwarding should require explicit opt-in'
    Assert ($shimText.Contains('else mode &= ~ENABLE_MOUSE_INPUT')) 'mouse input should be disabled by default so terminal scrolling works'
    Assert (-not ($shimText -match 'mode \|= ENABLE_EXTENDED_FLAGS \| ENABLE_MOUSE_INPUT \| ENABLE_VIRTUAL_TERMINAL_INPUT')) 'shim should not unconditionally enable mouse input'
}

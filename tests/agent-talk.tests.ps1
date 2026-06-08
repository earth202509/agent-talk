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
            workspace = 'D:\work\practice'
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
        return ((& $talkie wait-reply pane-fixture 4 2>&1) -join "`n")
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
        ('gpt-5.4-mini medium ' + $middleDot + ' D:\work\practice')
    )

    $text = Invoke-AgentTalkFixtureWaitReply -App 'codex' -Lines $lines -AgentVersion '0.136.0' -LastInputText 'hello'
    Assert ($text -eq 'Hello.') ('codex should extract the bullet reply after last input: ' + $text)
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

Test-Case 'agent-talk pi submits with a separate enter key' {
    . (Join-Path $RepoRoot 'src\scripts\agents\shared.ps1')
    $adapter = & (Join-Path $RepoRoot 'src\scripts\agents\pi.ps1') -ExtraArgs ''

    Assert ($adapter.AppendMessageNewline -eq $false) 'pi should not append newline to the message text'
    Assert ($adapter.SubmitSequenceSeparate -eq $true) 'pi should submit with a separate Enter sequence'
    Assert ([int][char]$adapter.SubmitSequence -eq 13) 'pi submit sequence should be carriage return only'
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

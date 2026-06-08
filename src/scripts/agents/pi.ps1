param([string]$ExtraArgs)

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Split-ExtraArgs {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    $tokens = @()
    $current = New-Object System.Text.StringBuilder
    $quote = [char]0
    $escaped = $false

    foreach ($ch in $Value.ToCharArray()) {
        if ($escaped) {
            [void]$current.Append($ch)
            $escaped = $false
            continue
        }
        if ($ch -eq '\') {
            $escaped = $true
            continue
        }
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) {
                $quote = [char]0
            } else {
                [void]$current.Append($ch)
            }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
            continue
        }
        if ([char]::IsWhiteSpace($ch)) {
            if ($current.Length -gt 0) {
                $tokens += $current.ToString()
                [void]$current.Clear()
            }
            continue
        }
        [void]$current.Append($ch)
    }
    if ($escaped) { [void]$current.Append('\') }
    if ($current.Length -gt 0) { $tokens += $current.ToString() }
    return $tokens
}

$cmd = Get-Command pi.cmd -ErrorAction SilentlyContinue
if (-not $cmd) { $cmd = Get-Command pi.exe -ErrorAction SilentlyContinue }
if (-not $cmd) { $cmd = Get-Command pi -ErrorAction SilentlyContinue }
if (-not $cmd) { $cmd = Get-Command pi.ps1 -ErrorAction SilentlyContinue }
if (-not $cmd) { throw 'pi command not found' }
$piPath = if ($cmd.Path) { $cmd.Path } elseif ($cmd.Source) { $cmd.Source } else { [string]$cmd.Definition }

$piArgs = @()
if ($ExtraArgs -and $ExtraArgs -ne '__default__' -and $ExtraArgs -ne '--no-extra' -and $ExtraArgs -ne 'none') {
    $piArgs += @(Split-ExtraArgs $ExtraArgs)
}
$piArgsLiteral = if ($piArgs.Count -gt 0) {
    '@(' + (($piArgs | ForEach-Object { Quote-PowerShellLiteral $_ }) -join ', ') + ')'
} else {
    '@()'
}
$launchScript = @(
    '$ErrorActionPreference = ''Stop''',
    '[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)',
    '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
    '$OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
    '$piPath = ' + (Quote-PowerShellLiteral $piPath),
    '$piArgs = ' + $piArgsLiteral,
    'if ([System.IO.Path]::GetExtension($piPath) -ieq ''.ps1'') {',
    '    $childPowerShell = Join-Path $env:SystemRoot ''System32\WindowsPowerShell\v1.0\powershell.exe''',
    '    & $childPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $piPath @piArgs',
    '} else {',
    '    & $piPath @piArgs',
    '}'
) -join "`r`n"
$encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($launchScript))
$args = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

@{
    App      = 'pi'
    AdapterVersion = '1.0.0'
    AgentCommand = 'pi'
    AgentVersionArgs = @('--version')
    AgentVersionPattern = '(?<version>\d+(?:\.\d+){1,3})'
    AgentVersionMin = '0.78.0'
    File     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Args     = $args
    UsesFullScreenTui = { $false }
    AppendMessageNewline = $false
    SubmitSequence = "`r"
    SubmitSequenceSeparate = $true

    GetStatus = {
        param([string]$Text)
        if (-not $Text) { return 'unknown' }
        $hasInputArea = Test-InputAreaReady $Text

        # Pi can leave stale busy text in scrollback. Treat only tail busy
        # indicators without a ready input area as active work.
        if (-not $hasInputArea -and (Test-TailBusy $Text @('Working\.\.\.', 'Thinking\.\.\.'))) { return 'busy' }
        if ($hasInputArea) { return 'ready' }
        return 'unknown'
    }

    GetReply = {
        param([string]$Text, [string]$LastInputText)
        return Get-AgentTalkReplyBlock `
            -Text $Text `
            -BusyPatterns @('Working\.\.\.', 'Thinking\.\.\.') `
            -BoundaryPatterns @('^[A-Z]:\\') `
            -LastInputText $LastInputText `
            -ReplyAnchorPatterns @('Working\.\.\.', 'Thinking\.\.\.') `
            -ReplyAnchorConsumesLine
    }
}




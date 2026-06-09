param([string]$ExtraArgs)

. (Join-Path $PSScriptRoot 'shared.ps1')

@{
    App      = 'codex'
    AdapterVersion = '1.0.0'
    AgentCommand = 'codex'
    AgentVersionArgs = @('--version')
    AgentVersionPattern = '(?<version>\d+(?:\.\d+){1,3})'
    AgentVersionMin = '0.136.0'
    File     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Args     = New-AgentTalkPowerShellArgs -CommandName 'codex' -ExtraArgs $ExtraArgs
    AppendMessageNewline = $false
    SubmitSequence = "`r`n"
    SubmitSequenceParts = @("$([char]27)", "`r`n")
    SubmitSequenceSeparate = $true
    SubmitDelayMilliseconds = 800
    SubmitSequencePartDelayMilliseconds = 300
    UsesFullScreenTui = { $true }

    GetStatus = {
        param([string]$Text)
        if (-not $Text) { return 'unknown' }
        $promptChar = [char]0x203A  # ›
        $middleDot = [char]0x00B7
        if (Test-TailBusy $Text @('Thinking\.\.\.', 'Working \(')) { return 'busy' }

        $lines = @($Text -split "`n")
        $tailStart = [Math]::Max(0, $lines.Count - 8)
        $tail = ($lines[$tailStart..($lines.Count - 1)] -join "`n")
        $hasPrompt = Test-AnyMatch $tail @("^$promptChar\s(?!\d+\.)")
        $hasStatus = Test-AnyMatch $tail @("^\s*\S.+\s$middleDot\s[A-Z]:\\")
        if ($hasPrompt -and $hasStatus) { return 'ready' }
        return 'unknown'
    }

    GetReply = {
        param([string]$Text, [string]$LastInputText)
        $promptChar = [char]0x203A  # ›
        $replyBullet = [char]0x2022 # •
        $noticeBlock = [char]0x25A0 # ■
        $middleDot = [char]0x00B7
        return Get-AgentTalkReplyBlock `
            -Text $Text `
            -BusyPatterns @('Thinking\.\.\.', 'Working \(', 'Starting MCP servers') `
            -BoundaryPatterns @(
                "^$promptChar(?:\s|`$)"
                "^\s*\S.+\s$middleDot\s[A-Z]:\\"
                "^$([char]0x26A0)"
                "^$([char]0x25E6)"
                'Update available'
                'Update now'
                'Skip until next version'
                'Press enter to continue'
            ) `
            -LastInputText $LastInputText `
            -InputPrefixPattern "^$promptChar\s+" `
            -ReplyPrefixPattern "^[$replyBullet$noticeBlock](?:\s|$)"
    }
}




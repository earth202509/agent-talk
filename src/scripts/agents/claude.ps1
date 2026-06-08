param([string]$ExtraArgs)

. (Join-Path $PSScriptRoot 'shared.ps1')

@{
    App      = 'claude'
    AdapterVersion = '1.0.0'
    AgentCommand = 'claude'
    AgentVersionArgs = @('--version')
    AgentVersionPattern = '(?<version>\d+(?:\.\d+){1,3})'
    AgentVersionMin = '2.1.0'
    File     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Args     = New-AgentTalkPowerShellArgs -CommandName 'claude' -BaseArgs @('--dangerously-skip-permissions') -ExtraArgs $ExtraArgs
    UsesFullScreenTui = { $true }
    InterruptSequence = { "$([char]27)[27u" }
    AppendMessageNewline = $false
    SubmitSequence = "`r"
    SubmitSequenceSeparate = $true

    GetStatus = {
        param([string]$Text)
        if (-not $Text) { return 'unknown' }
        $promptHeavy = [char]0x276F
        if (-not (Test-InputAreaReady $Text)) { return 'unknown' }
        # Only 'esc to interrupt' is a reliable busy signal.
        # Box-drawing dash lines are UI chrome present in both idle and busy states.
        if (Test-TailBusy $Text @('esc to interrupt')) { return 'busy' }
        if (Test-AnyMatch $Text @("^$promptHeavy(?:\s|`$)")) { return 'ready' }
        return 'unknown'
    }

    GetReply = {
        param([string]$Text, [string]$LastInputText)
        $bullet = [char]0x25CF
        $promptHeavy = [char]0x276F
        $replyPrefix = "^$bullet(?:\s|`$)"                  # Claude assistant reply marker: ●
        $promptPat    = "^$promptHeavy(?:\s|`$)"
        $timingPat    = "^$([char]0x273B)\s"                # ✻ Brewed/Churned timing line
        return Get-AgentTalkReplyBlock `
            -Text $Text `
            -BusyPatterns @('Thinking\.\.\.', 'esc to interrupt') `
            -BoundaryPatterns @($promptPat, $timingPat) `
            -LastInputText $LastInputText `
            -InputPrefixPattern "^$promptHeavy\s+" `
            -ReplyPrefixPattern $replyPrefix `
            -EndAnchorPatterns @($timingPat)
    }
}




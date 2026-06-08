param([string]$ExtraArgs)

. (Join-Path $PSScriptRoot 'shared.ps1')

@{
    App      = 'agy'
    Aliases  = @('agy', 'gemini')
    AdapterVersion = '1.0.0'
    AgentCommand = 'agy'
    AgentVersionArgs = @('--version')
    AgentVersionPattern = '(?<version>\d+(?:\.\d+){1,3})'
    AgentVersionMin = '1.0.0'
    File     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Args     = New-AgentTalkPowerShellArgs -CommandName 'agy' -BaseArgs @('--dangerously-skip-permissions') -ExtraArgs $ExtraArgs
    AppendMessageNewline = $false
    SubmitSequence = "`r`n"
    SubmitSequenceSeparate = $true
    UsesFullScreenTui = { $true }

    GetStatus = {
        param([string]$Text)
        if (-not $Text) { return 'unknown' }
        $promptHeavy = [char]0x276F
        if (-not (Test-InputAreaReady $Text)) { return 'unknown' }
        if (Test-TailBusy $Text @('Thinking\.\.\.', 'Loading\.\.\.', 'Generating\.\.\.', 'esc to cancel')) { return 'busy' }
        if (Test-AnyMatch $Text @("^[>$promptHeavy]\s*$")) { return 'ready' }
        return 'unknown'
    }

    GetReply = {
        param([string]$Text, [string]$LastInputText)
        $promptHeavy = [char]0x276F
        return Get-AgentTalkReplyBlock `
            -Text $Text `
            -BusyPatterns @('Thinking\.\.\.', 'Loading\.\.\.', 'Generating\.\.\.', 'esc to cancel') `
            -BoundaryPatterns @("^[>$promptHeavy](?:\s|`$)", "^$([char]0x273B)\s", '^\(Google AI', '^Antigravity CLI', '^Gemini \d', '^\? for shortcuts', '^esc to cancel') `
            -LastInputText $LastInputText `
            -InputPrefixPattern "^[>$promptHeavy](?:\s+|`$)" `
            -StartAfterLastPatterns @("^[>$promptHeavy]\s+\S") `
            -ReplyPrefixPattern "^$([char]0x25CF)(?:\s|`$)" `
            -PreferReplyPrefixAfterStart
    }
}




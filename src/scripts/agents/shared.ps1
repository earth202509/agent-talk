# ---------------------------------------------------------------------------
# Status helpers — adapters call these inside their GetStatus scriptblock.
# ---------------------------------------------------------------------------

function Test-TailBusy {
    # Returns $true if any $Patterns match the last $Lines lines of $Text.
    # Active spinners (Working…/Thinking…) sit near the screen bottom, so a
    # tail check avoids false positives from scrolled-away historical matches.
    param([string]$Text, [string[]]$Patterns, [int]$Lines = 10)
    $all = $Text -split "`n"
    $tail = if ($all.Count -le $Lines) { $Text } else {
        ($all[($all.Count - $Lines)..($all.Count - 1)]) -join "`n"
    }
    foreach ($p in $Patterns) {
        if ($tail -match "(?mi)$p") { return $true }
    }
    return $false
}

function Test-AnyMatch {
    # Returns $true if any $Patterns match anywhere in $Text.
    param([string]$Text, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($Text -match "(?m)$p") { return $true }
    }
    return $false
}

function Test-InputAreaReady {
    # Detects the common ready input area:
    #   separator
    #   at most one non-empty input line
    #   separator
    #   at most a few status/help lines below
    param(
        [string]$Text,
        [int]$TailLines = 18,
        [int]$MaxBetweenLines = 1,
        [int]$MaxAfterLines = 3
    )
    if (-not $Text) { return $false }
    $dash = [char]0x2500
    $sepPat = "^[$dash]{10,}$"
    $allLines = $Text -split "`n"
    $tailStart = [Math]::Max(0, $allLines.Count - $TailLines)

    for ($i = $tailStart; $i -lt $allLines.Count; $i++) {
        if ($allLines[$i].Trim() -notmatch $sepPat) { continue }

        $betweenCount = 0
        for ($j = $i + 1; $j -lt $allLines.Count; $j++) {
            $lt = $allLines[$j].Trim()
            if ($lt -match $sepPat) {
                if ($betweenCount -gt $MaxBetweenLines) { break }

                $afterCount = 0
                for ($k = $j + 1; $k -lt $allLines.Count; $k++) {
                    if ($allLines[$k].Trim()) { $afterCount++ }
                    if ($afterCount -gt $MaxAfterLines) { break }
                }
                if ($afterCount -le $MaxAfterLines) { return $true }
                break
            }
            if ($lt) { $betweenCount++ }
            if ($betweenCount -gt $MaxBetweenLines) { break }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Reply helpers — adapters call these inside their GetReply scriptblock.
# ---------------------------------------------------------------------------

function Skip-BeforeLastThinking {
    # Strips everything up to and including the last "Thinking..." line.
    param([string]$Text)
    $idx = $Text.LastIndexOf('Thinking...', [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -ge 0) {
        $nl = $Text.IndexOf("`n", $idx)
        if ($nl -ge 0) { return $Text.Substring($nl + 1) }
    }
    return $Text
}

function Skip-BeforeLastPattern {
    param([string]$Text, [string[]]$Patterns)
    if (-not $Text -or -not $Patterns) { return $Text }
    $lastIdx = -1
    foreach ($pattern in $Patterns) {
        if (-not $pattern) { continue }
        $matches = [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($m in $matches) {
            if ($m.Index -gt $lastIdx) { $lastIdx = $m.Index }
        }
    }
    if ($lastIdx -ge 0) {
        $nl = $Text.IndexOf("`n", $lastIdx)
        if ($nl -ge 0) { return $Text.Substring($nl + 1) }
    }
    return $Text
}

function Remove-AgentTalkInputAreaTail {
    param(
        [string]$Text,
        [int]$TailLines = 18,
        [int]$MaxBetweenLines = 1,
        [int]$MaxAfterLines = 3
    )
    if (-not $Text) { return '' }
    $dash = [char]0x2500
    $sepPat = "^[$dash]{10,}$"
    $allLines = @($Text -split "`n")
    $tailStart = [Math]::Max(0, $allLines.Count - $TailLines)
    $bestStart = -1

    for ($i = $tailStart; $i -lt $allLines.Count; $i++) {
        if ($allLines[$i].Trim() -notmatch $sepPat) { continue }
        $betweenCount = 0
        for ($j = $i + 1; $j -lt $allLines.Count; $j++) {
            $lt = $allLines[$j].Trim()
            if ($lt -match $sepPat) {
                if ($betweenCount -gt $MaxBetweenLines) { break }
                $afterCount = 0
                for ($k = $j + 1; $k -lt $allLines.Count; $k++) {
                    if ($allLines[$k].Trim()) { $afterCount++ }
                    if ($afterCount -gt $MaxAfterLines) { break }
                }
                if ($afterCount -le $MaxAfterLines) { $bestStart = $i }
                break
            }
            if ($lt) { $betweenCount++ }
            if ($betweenCount -gt $MaxBetweenLines) { break }
        }
    }
    if ($bestStart -le 0) { return $Text }
    return (($allLines[0..($bestStart - 1)]) -join "`n").Trim()
}

function Normalize-AgentTalkReplyText {
    param([string]$Text)
    if (-not $Text) { return '' }
    return (($Text -replace '\s+', ' ').Trim())
}

function Get-AgentTalkFirstContentLine {
    param([string]$Text)
    if (-not $Text) { return '' }
    foreach ($line in ($Text -split "(`r`n|`n|`r)")) {
        $t = $line.Trim()
        if ($t) { return $t }
    }
    return ''
}

function Test-AgentTalkInputMatch {
    param([string]$ScreenInput, [string]$LastInput, [bool]$AllowPartial = $true)
    $left = Normalize-AgentTalkReplyText $ScreenInput
    $right = Normalize-AgentTalkReplyText (Get-AgentTalkFirstContentLine $LastInput)
    if (-not $left -or -not $right) { return $false }
    # We scan from bottom to top, so this anchors to the latest matching input.
    # Compare only the first 20 chars for long prompts to tolerate VT line-wrap
    # padding artifacts corrupting characters near the wrap boundary.
    $prefixLen = 20
    if ($left.Length -ge $prefixLen -and $right.Length -ge $prefixLen) {
        return $left.Substring(0, $prefixLen).Equals($right.Substring(0, $prefixLen), [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($left.Equals($right, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if (-not $AllowPartial) { return $false }
    return ($left.StartsWith($right, [System.StringComparison]::OrdinalIgnoreCase) -or $right.StartsWith($left, [System.StringComparison]::OrdinalIgnoreCase))
}

function Find-AgentTalkSplitInputEnd {
    param(
        [string[]]$Lines,
        [int]$PromptIndex,
        [string]$LastInputText
    )
    $expected = Normalize-AgentTalkReplyText (Get-AgentTalkFirstContentLine $LastInputText)
    if (-not $Lines -or $PromptIndex -ge ($Lines.Count - 1) -or -not $expected) { return -1 }

    $parts = @()
    $bestEnd = -1
    for ($j = $PromptIndex + 1; $j -lt $Lines.Count; $j++) {
        $t = $Lines[$j].Trim()
        if (-not $t) {
            if ($bestEnd -ge 0) { return $bestEnd }
            if ($parts.Count -eq 0) { continue }
            break
        }

        $parts += $t
        $candidate = Normalize-AgentTalkReplyText ($parts -join ' ')
        if (-not $candidate) { continue }
        if ($candidate.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) { return $j }
        if ($candidate.StartsWith($expected, [System.StringComparison]::OrdinalIgnoreCase)) { return $j }
        if ($expected.StartsWith($candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            $bestEnd = $j
            continue
        }
        break
    }
    return $bestEnd
}

function Limit-AgentTalkReplyToLastInput {
    param(
        [string]$Text,
        [string]$LastInputText,
        [string]$InputPrefixPattern = ''
    )
    if (-not $Text -or -not $LastInputText) { return $Text }
    $allLines = @($Text -split "`n")
    for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
        $raw = $allLines[$i].Trim()
        if (-not $raw) { continue }

        $candidate = ''
        if ($InputPrefixPattern) {
            if ($raw -notmatch $InputPrefixPattern) { continue }
            $candidate = ($raw -replace $InputPrefixPattern, '').Trim()
        } else {
            $candidate = $raw
        }

        if (Test-AgentTalkInputMatch -ScreenInput $candidate -LastInput $LastInputText -AllowPartial ([bool]$InputPrefixPattern)) {
            if ($i -ge ($allLines.Count - 1)) { return '' }
            return (($allLines[($i + 1)..($allLines.Count - 1)]) -join "`n").Trim()
        }
        if ($InputPrefixPattern -and -not $candidate) {
            $inputEnd = Find-AgentTalkSplitInputEnd -Lines $allLines -PromptIndex $i -LastInputText $LastInputText
            if ($inputEnd -ge $i) {
                if ($inputEnd -ge ($allLines.Count - 1)) { return '' }
                return (($allLines[($inputEnd + 1)..($allLines.Count - 1)]) -join "`n").Trim()
            }
        }
    }
    return ''
}

function Limit-AgentTalkReplyToLastAnchor {
    param(
        [string]$Text,
        [string[]]$AnchorPatterns = @()
    )
    if (-not $Text -or -not $AnchorPatterns) { return $Text }
    $allLines = @($Text -split "`n")
    for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
        $t = $allLines[$i].Trim()
        foreach ($pattern in $AnchorPatterns) {
            if ($pattern -and $t -match $pattern) {
                return (($allLines[$i..($allLines.Count - 1)]) -join "`n").Trim()
            }
        }
    }
    return $Text
}

function Limit-AgentTalkReplyBeforeFirstAnchor {
    param(
        [string]$Text,
        [string[]]$AnchorPatterns = @()
    )
    if (-not $Text -or -not $AnchorPatterns) { return $Text }
    $allLines = @($Text -split "`n")
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        $t = $allLines[$i].Trim()
        foreach ($pattern in $AnchorPatterns) {
            if ($pattern -and $t -match $pattern) {
                if ($i -le 0) { return '' }
                return (($allLines[0..($i - 1)]) -join "`n").Trim()
            }
        }
    }
    return $Text
}

function Get-AgentTalkReplyBlock {
    param(
        [string]$Text,
        [string[]]$BusyPatterns = @(),
        [string[]]$BoundaryPatterns = @(),
        [string]$ReplyPrefixPattern = '',
        [string]$LastInputText = '',
        [string]$InputPrefixPattern = '',
        [string[]]$StartAfterLastPatterns = @(),
        [string[]]$ReplyAnchorPatterns = @(),
        [string[]]$EndAnchorPatterns = @(),
        [switch]$ReplyAnchorConsumesLine,
        [switch]$PreferReplyPrefixAfterStart,
        [switch]$RequireReplyPrefix
    )
    if (-not $Text) { return '' }
    $dash = [char]0x2500
    $upperBlock = [char]0x2594
    $Text = Remove-AgentTalkInputAreaTail $Text

    $startedAfterInput = $false
    if ($LastInputText) {
        $Text = Limit-AgentTalkReplyToLastInput -Text $Text -LastInputText $LastInputText -InputPrefixPattern $InputPrefixPattern
        if (-not $Text) { return '' }
        $startedAfterInput = $true
    } elseif ($StartAfterLastPatterns -and @($StartAfterLastPatterns).Count -gt 0) {
        $Text = Limit-AgentTalkReplyToLastAnchor -Text $Text -AnchorPatterns $StartAfterLastPatterns
        if ($Text) {
            $lines = @($Text -split "`n")
            if ($lines.Count -le 1) { return '' }
            $Text = (($lines[1..($lines.Count - 1)]) -join "`n").Trim()
            $startedAfterInput = $true
        }
    }

    $anchors = @($ReplyAnchorPatterns)
    if ($ReplyPrefixPattern -and ($PreferReplyPrefixAfterStart -or -not $RequireReplyPrefix)) {
        $anchors += $ReplyPrefixPattern
    }
    if ($anchors.Count -gt 0) { $Text = Limit-AgentTalkReplyToLastAnchor -Text $Text -AnchorPatterns $anchors }
    if ($ReplyAnchorConsumesLine -and $Text) {
        $lines = @($Text -split "`n")
        if ($lines.Count -le 1) { return '' }
        $Text = (($lines[1..($lines.Count - 1)]) -join "`n").Trim()
    }
    if ($EndAnchorPatterns.Count -gt 0) { $Text = Limit-AgentTalkReplyBeforeFirstAnchor -Text $Text -AnchorPatterns $EndAnchorPatterns }
    if (-not $startedAfterInput) { $Text = Skip-BeforeLastPattern $Text $BusyPatterns }

    $boundaries = @($BoundaryPatterns) + @('^[\s\-' + $dash + $upperBlock + ']+$')
    if ($RequireReplyPrefix -and $ReplyPrefixPattern) {
        $allLines = @($Text -split "`n")
        $startIndex = -1
        for ($i = 0; $i -lt $allLines.Count; $i++) {
            if ($allLines[$i] -match $ReplyPrefixPattern) { $startIndex = $i }
        }
        if ($startIndex -lt 0) { return '' }

        $result = New-Object 'System.Collections.Generic.List[string]'
        for ($i = $startIndex; $i -lt $allLines.Count; $i++) {
            $raw = $allLines[$i].TrimEnd()
            $t = $raw.Trim()
            if (-not $t) { continue }

            if ($i -eq $startIndex) {
                $content = ($raw -replace $ReplyPrefixPattern, '').TrimStart()
                if ($content) { [void]$result.Add($content) }
                continue
            }

            $isBoundary = $false
            foreach ($bp in $boundaries) {
                if ($bp -and $t -match $bp) { $isBoundary = $true; break }
            }
            if ($isBoundary) { break }
            [void]$result.Add($t)
        }
        if ($result.Count -eq 0) { return '' }
        return ($result -join "`n")
    }

    $replyBlocks = New-Object 'System.Collections.Generic.List[string]'
    $currentReply = New-Object 'System.Collections.Generic.List[string]'
    $inReply = $false

    foreach ($line in ($Text -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }

        $isBoundary = $false
        foreach ($bp in $boundaries) {
            if ($bp -and $t -match $bp) { $isBoundary = $true; break }
        }
        if ($isBoundary) {
            if ($inReply -and $currentReply.Count -gt 0) {
                [void]$replyBlocks.Add(($currentReply -join "`n"))
            }
            $currentReply.Clear()
            $inReply = $false
            continue
        }

        if ($ReplyPrefixPattern -and -not $inReply -and $t -match $ReplyPrefixPattern) {
            if ($inReply -and $currentReply.Count -gt 0) {
                [void]$replyBlocks.Add(($currentReply -join "`n"))
            }
            $currentReply.Clear()
            $content = ($t -replace $ReplyPrefixPattern, '').TrimStart()
            if ($content) { [void]$currentReply.Add($content) }
            $inReply = $true
            continue
        }

        if ($RequireReplyPrefix -and -not $inReply) { continue }
        [void]$currentReply.Add($t)
        $inReply = $true
    }

    if ($inReply -and $currentReply.Count -gt 0) {
        [void]$replyBlocks.Add(($currentReply -join "`n"))
    }
    if ($replyBlocks.Count -eq 0) { return '' }
    return $replyBlocks[$replyBlocks.Count - 1]
}

function Select-ContentLines {
    # Filters out busy/noise/separator/chrome lines, returns remaining trimmed lines.
    param([string]$Text, [string[]]$BusyPatterns, [string[]]$NoiseFilters, [string]$PromptPattern)
    $result = @()
    foreach ($line in ($Text -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $skip = $false
        foreach ($bp in $BusyPatterns)  { if ($t -match $bp) { $skip = $true; break } }
        if (-not $skip) { foreach ($nf in $NoiseFilters) { if ($t -match $nf) { $skip = $true; break } } }
        if (-not $skip -and ($t -match ('^[\s\-' + [char]0x2500 + ']+$'))) { $skip = $true }
        if (-not $skip -and ($t -match '^\S:\\'))  { $skip = $true }
        if (-not $skip -and $PromptPattern -and ($t -match $PromptPattern)) { $skip = $true }
        if (-not $skip) { $result += $t }
    }
    return $result
}

# ---------------------------------------------------------------------------

function Quote-AgentTalkPowerShellLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Split-AgentTalkExtraArgs {
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

function Resolve-AgentTalkCliPath {
    param([Parameter(Mandatory = $true)][string]$CommandName)
    foreach ($candidate in @("$CommandName.cmd", "$CommandName.exe", $CommandName, "$CommandName.ps1")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            if ($cmd.Path) { return $cmd.Path }
            if ($cmd.Source) { return $cmd.Source }
            return [string]$cmd.Definition
        }
    }
    throw "$CommandName command not found"
}

function ConvertTo-AgentTalkVersionParts {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $m = [regex]::Match($Value, '\d+(?:\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value -split '\.' | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return ,@($parts[0..3])
}

function Compare-AgentTalkVersion {
    param([string]$Left, [string]$Right)
    $l = ConvertTo-AgentTalkVersionParts $Left
    $r = ConvertTo-AgentTalkVersionParts $Right
    if (-not $l -and -not $r) { return 0 }
    if (-not $l) { return -1 }
    if (-not $r) { return 1 }
    for ($i = 0; $i -lt 4; $i++) {
        if ($l[$i] -lt $r[$i]) { return -1 }
        if ($l[$i] -gt $r[$i]) { return 1 }
    }
    return 0
}

function Get-AgentTalkVersionSortKey {
    param([string]$Version)
    $parts = ConvertTo-AgentTalkVersionParts $Version
    if (-not $parts) { $parts = @(0, 0, 0, 0) }
    return ('{0:D8}.{1:D8}.{2:D8}.{3:D8}' -f $parts[0], $parts[1], $parts[2], $parts[3])
}

function Test-AgentTalkVersionMin {
    param(
        [string]$Version,
        [string]$Min
    )
    if ([string]::IsNullOrWhiteSpace($Min)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Min) -and (Compare-AgentTalkVersion $Version $Min) -lt 0) {
        return $false
    }
    return $true
}

function Get-AgentTalkAdapterCommandName {
    param([hashtable]$Adapter)
    if ($Adapter.AgentCommand) { return [string]$Adapter.AgentCommand }
    if ($Adapter.App) { return [string]$Adapter.App }
    return ''
}

function Get-AgentTalkAgentVersion {
    param([hashtable]$Adapter)
    if ($Adapter.GetAgentVersion -is [scriptblock]) {
        return [string](& $Adapter.GetAgentVersion)
    }
    $commandName = Get-AgentTalkAdapterCommandName $Adapter
    if (-not $commandName) { return '' }
    $versionArgs = @('--version')
    if ($Adapter.AgentVersionArgs) { $versionArgs = @($Adapter.AgentVersionArgs) }
    $versionPattern = if ($Adapter.AgentVersionPattern) { [string]$Adapter.AgentVersionPattern } else { '\d+(?:\.\d+){1,3}' }

    $commandPath = Resolve-AgentTalkCliPath $commandName
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $commandPath @versionArgs 2>&1 | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($out -match $versionPattern) {
        if ($Matches['version']) { return [string]$Matches['version'] }
        return [string]$Matches[0]
    }
    return ''
}

function Test-AgentTalkAdapterName {
    param([hashtable]$Adapter, [string]$Name)
    if (-not $Adapter -or -not $Name) { return $false }
    if ([string]$Adapter.App -eq $Name) { return $true }
    if ($Adapter.Aliases -and @($Adapter.Aliases) -contains $Name) { return $true }
    return $false
}

function Resolve-AgentTalkAdapter {
    param(
        [Parameter(Mandatory = $true)][string]$AdapterDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExtraArgs = '',
        [string]$AgentVersion
    )

    $candidates = @()
    foreach ($script in Get-ChildItem -LiteralPath $AdapterDir -Filter '*.ps1') {
        if ($script.BaseName -eq 'shared') { continue }
        $adapter = & $script.FullName -ExtraArgs $ExtraArgs
        if (-not (Test-AgentTalkAdapterName $adapter $Name)) { continue }
        $candidates += [pscustomobject]@{
            Path = $script.FullName
            Adapter = $adapter
        }
    }
    if ($candidates.Count -eq 0) { throw "adapter '$Name' not found" }

    $versionCache = @{}
    $resolved = @()
    foreach ($candidate in $candidates) {
        $adapter = [hashtable]$candidate.Adapter
        $commandName = Get-AgentTalkAdapterCommandName $adapter
        $actualVersion = $AgentVersion
        if (-not $actualVersion) {
            if (-not $versionCache.ContainsKey($commandName)) {
                $versionCache[$commandName] = Get-AgentTalkAgentVersion $adapter
            }
            $actualVersion = [string]$versionCache[$commandName]
        }
        $adapterVersion = if ($adapter.AdapterVersion) { [string]$adapter.AdapterVersion } else { '0.0.0' }
        $minVersion = if ($adapter.AgentVersionMin) { [string]$adapter.AgentVersionMin } else { '' }
        $resolved += [pscustomobject]@{
            Path = $candidate.Path
            Adapter = $adapter
            AgentVersion = $actualVersion
            AdapterVersion = $adapterVersion
            AgentVersionMin = $minVersion
            Compatible = (Test-AgentTalkVersionMin -Version $actualVersion -Min $minVersion)
        }
    }

    $compatible = @($resolved | Where-Object { $_.Compatible })
    if ($compatible.Count -gt 0) {
        return @($compatible | Sort-Object `
            @{ Expression = { Get-AgentTalkVersionSortKey $_.AdapterVersion }; Descending = $true }, `
            @{ Expression = { Get-AgentTalkVersionSortKey $_.AgentVersionMin }; Descending = $true } |
            Select-Object -First 1)[0]
    }

    $details = ($resolved | ForEach-Object {
        $min = if ($_.AgentVersionMin) { $_.AgentVersionMin } else { '*' }
        ('{0} adapter={1} supports=>={2}' -f (Split-Path -Leaf $_.Path), $_.AdapterVersion, $min)
    }) -join '; '
    $seenVersion = if ($resolved.Count -gt 0) { [string]$resolved[0].AgentVersion } else { '' }
    throw "No compatible adapter for '$Name' agent version '$seenVersion'. Candidates: $details"
}

function New-AgentTalkPowerShellArgs {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string[]]$BaseArgs = @(),
        [string]$ExtraArgs = ''
    )

    $appPath = Resolve-AgentTalkCliPath $CommandName
    $appArgs = @($BaseArgs)
    if ($ExtraArgs -and $ExtraArgs -ne '__default__' -and $ExtraArgs -ne '--no-extra' -and $ExtraArgs -ne 'none') {
        $appArgs += @(Split-AgentTalkExtraArgs $ExtraArgs)
    }
    $appArgsLiteral = if ($appArgs.Count -gt 0) {
        '@(' + (($appArgs | ForEach-Object { Quote-AgentTalkPowerShellLiteral $_ }) -join ', ') + ')'
    } else {
        '@()'
    }
    $launchScript = @(
        '$ErrorActionPreference = ''Stop''',
        '[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)',
        '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
        '$OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
        '$appPath = ' + (Quote-AgentTalkPowerShellLiteral $appPath),
        '$appArgs = ' + $appArgsLiteral,
        'if ([System.IO.Path]::GetExtension($appPath) -ieq ''.ps1'') {',
        '    $childPowerShell = Join-Path $env:SystemRoot ''System32\WindowsPowerShell\v1.0\powershell.exe''',
        '    & $childPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $appPath @appArgs',
        '} else {',
        '    & $appPath @appArgs',
        '}'
    ) -join "`r`n"
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($launchScript))
    return "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
}

param(
    [string[]]$Skill,
    [string]$SourceRoot      = (Join-Path $PSScriptRoot '..\src'),
    [string]$CodexRoot       = (Join-Path $env:USERPROFILE '.codex\skills'),
    [string]$ClaudeRoot      = (Join-Path $env:USERPROFILE '.claude\skills'),
    [string]$GeminiRoot      = (Join-Path $env:USERPROFILE '.gemini\config\plugins\my-skills\skills'),
    [string]$PiRoot          = (Join-Path $env:USERPROFILE '.pi\agent\skills'),
    [string]$MarketplaceRoot = (Join-Path $env:USERPROFILE '.claude\plugins\marketplaces'),
    [switch]$IgnoreMarketplaceConflicts,
    [switch]$SkipCodex,
    [switch]$SkipClaude,
    [switch]$SkipGemini,
    [switch]$SkipPi
)

$ErrorActionPreference = 'Stop'

$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path

function Assert-SkillName {
    param([string]$Name)
    if ($Name -notmatch '^[a-z0-9-]+$') {
        throw "Invalid skill name: $Name"
    }
}

function Copy-Skill {
    param([string]$Name, [string]$TargetRoot)

    Assert-SkillName $Name
    $src = $SourceRoot
    $dst = Join-Path $TargetRoot $Name

    if (-not (Test-Path -LiteralPath (Join-Path $src 'SKILL.md'))) {
        throw "Missing SKILL.md for skill: $Name"
    }

    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem -LiteralPath $dst -Force | ForEach-Object {
        if ($Name -eq 'agent-talk' -and $_.Name -eq 'state') {
            return
        }
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
    Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
        if ($Name -eq 'agent-talk' -and $_.Name -eq 'state') {
            New-Item -ItemType Directory -Force -Path (Join-Path $dst 'state') | Out-Null
            return
        }
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force
    }
    "DEPLOYED=$Name"
}

function Find-MarketplaceConflicts {
    param([string[]]$Names, [string]$Root)
    $conflicts = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $conflicts }
    foreach ($mp in Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue) {
        $pluginsDir = Join-Path $mp.FullName 'plugins'
        if (-not (Test-Path -LiteralPath $pluginsDir)) { continue }
        foreach ($plugin in Get-ChildItem -LiteralPath $pluginsDir -Directory -ErrorAction SilentlyContinue) {
            $skillsDir = Join-Path $plugin.FullName 'skills'
            if (-not (Test-Path -LiteralPath $skillsDir)) { continue }
            foreach ($skillDir in Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue) {
                if ($Names -contains $skillDir.Name) {
                    $conflicts += [pscustomobject]@{
                        Skill       = $skillDir.Name
                        Marketplace = $mp.Name
                        Plugin      = $plugin.Name
                        Path        = $skillDir.FullName
                    }
                }
            }
        }
    }
    return $conflicts
}

if (-not ($Skill -and $Skill.Count -gt 0)) {
    $Skill = @('agent-talk')
}

if (-not $SkipClaude) {
    $conflicts = @(Find-MarketplaceConflicts -Names $Skill -Root $MarketplaceRoot)
    if ($conflicts.Count -gt 0) {
        foreach ($c in $conflicts) {
            Write-Host ("WARN conflict skill='{0}' marketplace='{1}' plugin='{2}' path='{3}'" -f $c.Skill, $c.Marketplace, $c.Plugin, $c.Path)
            Write-Host ("     -> /plugin uninstall {0}@{1}  (or run with -IgnoreMarketplaceConflicts)" -f $c.Plugin, $c.Marketplace)
        }
        if (-not $IgnoreMarketplaceConflicts) {
            throw "Refusing to deploy: $($conflicts.Count) skill name(s) already exist under a local marketplace. Resolve via /plugin uninstall or rerun with -IgnoreMarketplaceConflicts."
        }
    }
}

$targets = @()
if (-not $SkipCodex)  { $targets += $CodexRoot }
if (-not $SkipClaude) { $targets += $ClaudeRoot }
if (-not $SkipGemini) { $targets += $GeminiRoot }
if (-not $SkipPi)     { $targets += $PiRoot }

foreach ($root in $targets) {
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Force -Path $root | Out-Null
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $root).Path
    foreach ($name in $Skill) {
        Copy-Skill -Name $name -TargetRoot $resolvedRoot
    }
}

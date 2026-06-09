param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$SkipIntegration,
    [string]$Skill = '',
    [string]$Only = ''
)

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Pass($Name) {
    $script:Passed += 1
    "PASS $Name"
}

function Fail($Name, $Message) {
    $script:Failed += 1
    "FAIL $Name - $Message"
}

function Skip($Name, $Message) {
    throw "__SKIP__:$Message"
}

function Test-Case($Name, [scriptblock]$Body) {
    if ($Only -and ($Name -notlike "*$Only*")) {
        return
    }
    try {
        & $Body
        Pass $Name
    } catch {
        $message = $_.Exception.Message
        if ($message -like '__SKIP__:*') {
            $script:Skipped += 1
            "SKIP $Name - $($message.Substring('__SKIP__:'.Length))"
        } else {
            Fail $Name $message
        }
    }
}

function Assert($Condition, $Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Get-FileHashWithRetry {
    param([Parameter(Mandatory = $true)][string]$Path)
    $lastError = $null
    for ($i = 0; $i -lt 5; $i++) {
        try {
            return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 200
        }
    }
    throw $lastError
}

function Get-SkillFrontmatter($SkillPath) {
    $skillMd = Join-Path $SkillPath 'SKILL.md'
    Assert (Test-Path -LiteralPath $skillMd) "Missing SKILL.md: $SkillPath"
    $text = Get-Content -Encoding UTF8 -Raw -LiteralPath $skillMd
    $match = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
    Assert $match.Success "Invalid frontmatter block: $skillMd"
    return $match.Groups[1].Value
}

function Invoke-SkillTestFiles {
    param([string]$SkillFilter = '')

    $skillTestsRoot = $PSScriptRoot
    $files = @(Get-ChildItem -LiteralPath $skillTestsRoot -File -Filter '*.tests.ps1' | Sort-Object Name)
    if ($SkillFilter) {
        $files = @($files | Where-Object { $_.BaseName -eq "$SkillFilter.tests" -or $_.BaseName -eq $SkillFilter })
        if ($files.Count -eq 0) {
            throw "no test file found for skill: $SkillFilter"
        }
    }

    foreach ($file in $files) {
        . $file.FullName
    }
}

if ($Skill) {
    Invoke-SkillTestFiles -SkillFilter $Skill
    "RESULT passed=$script:Passed failed=$script:Failed skipped=$script:Skipped"
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}

Invoke-SkillTestFiles

Test-Case 'PowerShell scripts parse' {
    $scripts = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notlike '*\.git\*' }
    foreach ($script in $scripts) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        Assert ($errors.Count -eq 0) "Parse errors in $($script.FullName): $($errors[0].Message)"
    }
}

Test-Case 'Skill frontmatter is valid' {
    $skillsRoot = Join-Path $RepoRoot 'src'
    foreach ($skillDir in @(Get-Item -LiteralPath $skillsRoot)) {
        $frontmatter = Get-SkillFrontmatter $skillDir.FullName
        $name = [regex]::Match($frontmatter, '(?m)^name:\s*([a-z0-9-]+)\s*$').Groups[1].Value
        Assert ($name -match '^[a-z0-9-]+$') "Invalid skill name: $name"
        $descMatch = [regex]::Match($frontmatter, '(?ms)^description:\s*>\s*\r?\n(?<d>(?:  .*\r?\n?)+)')
        if ($descMatch.Success) {
            $descBlock = $descMatch.Groups['d'].Value
            $description = (($descBlock -split "\r?\n" | ForEach-Object { $_ -replace '^  ', '' }) -join ' ').Trim()
        } else {
            $description = [regex]::Match($frontmatter, '(?m)^description:\s*(.+?)\s*$').Groups[1].Value.Trim()
        }
        Assert ($description.Length -gt 0) "Missing description: $name"
        Assert ($description.Length -le 1024) "Description too long: $name"
        Assert ($description -notmatch '[<>]') "Description contains angle brackets: $name"
    }
}

Test-Case 'Skill templates have no TODO leftovers' {
    $files = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Recurse -File |
        Where-Object { $_.Extension -in @('.md', '.yaml', '.yml', '.ps1', '.sh') }
    foreach ($file in $files) {
        $text = Get-Content -Encoding UTF8 -Raw -LiteralPath $file.FullName
        Assert ($text -notmatch '\[TODO:|Structuring This Skill|Resources \(optional\)') "Template text left in $($file.FullName)"
    }
}

Test-Case 'Deploy script copies agent-talk and skips runtime state' {
    $deploy = Join-Path $RepoRoot 'scripts\deploy-skills.ps1'
    $target = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-talk-skills-test-" + [guid]::NewGuid())
    try {
        & $deploy -CodexRoot $target -SkipClaude -SkipGemini -SkipPi | Out-Null
        Assert (Test-Path -LiteralPath (Join-Path $target 'agent-talk\SKILL.md')) 'agent-talk was not deployed'
        Assert (Test-Path -LiteralPath (Join-Path $target 'agent-talk\state')) 'agent-talk state dir missing'
        $stale = Join-Path $target 'agent-talk\scripts\stale.ps1'
        Set-Content -Encoding UTF8 -LiteralPath $stale -Value 'old'
        & $deploy -CodexRoot $target -SkipClaude -SkipGemini -SkipPi | Out-Null
        Assert (-not (Test-Path -LiteralPath $stale)) 'deploy should remove stale files from target skill'
        Assert (-not (Test-Path -LiteralPath (Join-Path $target 'agent-talk\state\sessions.json'))) 'sessions.json should not deploy from repo'

        $sourceFiles = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Recurse -File |
            Where-Object { $_.FullName -notlike '*\state\*' }
        foreach ($sourceFile in $sourceFiles) {
            $relative = 'agent-talk\' + $sourceFile.FullName.Substring((Join-Path $RepoRoot 'src').Length + 1)
            $targetFile = Join-Path $target $relative
            Assert (Test-Path -LiteralPath $targetFile) "Missing deployed file: $relative"
            $sourceHash = Get-FileHashWithRetry $sourceFile.FullName
            $targetHash = Get-FileHashWithRetry $targetFile
            Assert ($sourceHash -eq $targetHash) "Deployed file hash mismatch: $relative"
        }
    } finally {
        if ($target.StartsWith([System.IO.Path]::GetTempPath()) -and (Test-Path -LiteralPath $target)) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }
}

Test-Case 'Deploy script refuses marketplace conflicts' {
    $deploy = Join-Path $RepoRoot 'scripts\deploy-skills.ps1'
    $target = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-talk-conflict-" + [guid]::NewGuid())
    $mpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-talk-mp-" + [guid]::NewGuid())
    $conflictSkill = Join-Path $mpRoot 'local-migrated-skills\plugins\agent-talk\skills\agent-talk'
    try {
        New-Item -ItemType Directory -Force -Path $conflictSkill | Out-Null
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $conflictSkill 'SKILL.md') -Value 'placeholder'
        $threw = $false
        $err = $null
        try {
            & $deploy -CodexRoot $target -ClaudeRoot $target -MarketplaceRoot $mpRoot -SkipGemini -SkipPi *> $null
        } catch {
            $threw = $true
            $err = $_.Exception.Message
        }
        Assert $threw 'deploy-skills should refuse when marketplace shadows agent-talk'
        Assert ($err -match 'Refusing to deploy') "unexpected error message: $err"
        Assert (-not (Test-Path -LiteralPath (Join-Path $target 'agent-talk\SKILL.md'))) 'should not have written any skill on refusal'
    } finally {
        foreach ($p in @($target, $mpRoot)) {
            if ($p.StartsWith([System.IO.Path]::GetTempPath()) -and (Test-Path -LiteralPath $p)) {
                Remove-Item -LiteralPath $p -Recurse -Force
            }
        }
    }
}

Test-Case 'Deploy script proceeds past marketplace conflicts when ignored' {
    $deploy = Join-Path $RepoRoot 'scripts\deploy-skills.ps1'
    $target = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-talk-ignore-" + [guid]::NewGuid())
    $mpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-talk-mp-ignore-" + [guid]::NewGuid())
    $conflictSkill = Join-Path $mpRoot 'local-migrated-skills\plugins\agent-talk\skills\agent-talk'
    try {
        New-Item -ItemType Directory -Force -Path $conflictSkill | Out-Null
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $conflictSkill 'SKILL.md') -Value 'placeholder'
        & $deploy -CodexRoot $target -ClaudeRoot $target -MarketplaceRoot $mpRoot -IgnoreMarketplaceConflicts -SkipGemini -SkipPi | Out-Null
        Assert (Test-Path -LiteralPath (Join-Path $target 'agent-talk\SKILL.md')) 'IgnoreMarketplaceConflicts did not unblock deploy'
    } finally {
        foreach ($p in @($target, $mpRoot)) {
            if ($p.StartsWith([System.IO.Path]::GetTempPath()) -and (Test-Path -LiteralPath $p)) {
                Remove-Item -LiteralPath $p -Recurse -Force
            }
        }
    }
}

Test-Case 'SkipIntegration is accepted for compatibility' {
    if ($SkipIntegration) {
        Skip 'SkipIntegration is accepted for compatibility' 'SkipIntegration was set'
    }
}

"RESULT passed=$script:Passed failed=$script:Failed skipped=$script:Skipped"
if ($script:Failed -gt 0) {
    exit 1
}

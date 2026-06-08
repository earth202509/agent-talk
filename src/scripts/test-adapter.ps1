<#
.SYNOPSIS
    App adapter basic test. Verifies GetStatus / GetReply / send / wait-reply and unknown-state detection.
.PARAMETER App
    Adapter name: pi, claude, codex, agy.
.PARAMETER Task
    Test task text. Default: simple math question.
.PARAMETER Timeout
    wait-reply timeout in seconds. Default 60.
.PARAMETER WorkDir
    If specified, start session in this directory (for trust-folder unknown test).
.PARAMETER SkipTrustDirCheck
    Skip the automatic new-directory startup unknown check.
.EXAMPLE
    .\test-adapter.ps1 pi
    .\test-adapter.ps1 claude -WorkDir "$env:TEMP\test-adapter-tmp"
#>
param(
    [Parameter(Mandatory=$true)][string]$App,
    [string]$Task = '1+1=?, answer number only',
    [int]$Timeout = 20,
    [string]$WorkDir,
    [switch]$KeepPaneOnUnknown,
    [switch]$SkipTrustDirCheck
)

$ErrorActionPreference = 'Stop'
$TALKIE = Join-Path $PSScriptRoot 'talkie.ps1'
$pass = 0; $fail = 0; $pane = $null; $keepPane = $false
$origDir = (Get-Location).Path

function Report {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host ('  [FAIL] ' + $Name + ' -- ' + $Detail) -ForegroundColor Red
        $script:fail++
    }
}

function WaitForStatus {
    param([string]$Pane, [scriptblock]$StatusFn, [string]$Expected, [int]$MaxSeconds = 15)
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    $s = 'unknown'
    while ((Get-Date) -lt $deadline) {
        $scr = & $TALKIE get-screen $Pane
        $s = & $StatusFn $scr
        if ($s -eq $Expected) { return $s }
        Start-Sleep -Milliseconds 500
    }
    return $s
}

function ScreenTail {
    param([string]$Text, [int]$N = 5)
    $lines = $Text -split "`n" | Select-Object -Last $N
    return ($lines -join ' | ')
}

function Get-CurrentScreen {
    param([string]$Pane)
    return ((& $TALKIE get-screen $Pane) -join "`n")
}

function Get-SessionLogPath {
    param([string]$Pane)
    try {
        $json = & $TALKIE list-sessions json 2>$null
        if (-not $json) { return '' }
        $sessions = @($json | ConvertFrom-Json)
        $session = @($sessions | Where-Object { $_.session_id -eq $Pane -or $_.transport.handle -eq $Pane } | Select-Object -First 1)
        if ($session) { return [string]$session.transport.log_path }
    } catch {}
    return ''
}

function Stop-ManualInspection {
    param([string]$Step, [string]$Pane, [string]$Status, [string]$Screen)
    $script:fail++
    Write-Host ('  [UNKNOWN] ' + $Step + ' -- manual inspection required; got: ' + $Status) -ForegroundColor Yellow
    Write-Host ('    pane: ' + $Pane) -ForegroundColor Yellow
    $logPath = Get-SessionLogPath $Pane
    if ($logPath) { Write-Host ('    log: ' + $logPath) -ForegroundColor Yellow }
    Write-Host '    tail:' -ForegroundColor Yellow
    (($Screen -split "`n") | Select-Object -Last 20) | ForEach-Object {
        Write-Host ('    ' + $_) -ForegroundColor DarkGray
    }
    if ($KeepPaneOnUnknown) { $script:keepPane = $true }
    throw "manual inspection required at step: $Step"
}

function Require-State {
    param([string]$Step, [string]$Pane, [scriptblock]$StatusFn, [string[]]$Allowed)
    $screen = Get-CurrentScreen $Pane
    $status = & $StatusFn $screen
    if ($status -in $Allowed) {
        Report $Step $true ('got: ' + $status)
        return [pscustomobject]@{ Status = $status; Screen = $screen }
    }
    if ($status -eq 'unknown') {
        Stop-ManualInspection -Step $Step -Pane $Pane -Status $status -Screen $screen
    }
    Report $Step $false ('got: ' + $status)
    return [pscustomobject]@{ Status = $status; Screen = $screen }
}

function Wait-ForAllowedState {
    param([string]$Pane, [scriptblock]$StatusFn, [string[]]$Allowed, [int]$MaxSeconds = 15)
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    $screen = ''
    $status = 'unknown'
    while ((Get-Date) -lt $deadline) {
        $screen = Get-CurrentScreen $Pane
        $status = & $StatusFn $screen
        if ($status -in $Allowed) {
            return [pscustomobject]@{ Status = $status; Screen = $screen }
        }
        Start-Sleep -Milliseconds 500
    }
    return [pscustomobject]@{ Status = $status; Screen = $screen }
}

function Resolve-TestAdapterScript {
    param([string]$Name)
    return (Resolve-AgentTalkAdapter -AdapterDir $adapterDir -Name $Name -ExtraArgs '').Path
}

function Resolve-TestAdapter {
    param([string]$Name)
    return Resolve-AgentTalkAdapter -AdapterDir $adapterDir -Name $Name -ExtraArgs ''
}

function Recover-PaneByTitle {
    param([string]$Title)
    $sessions = & $TALKIE list-sessions tsv 2>&1 | Out-String
    foreach ($line in ($sessions -split "`n")) {
        if ($line -match ('^(wtcc-[0-9a-f]+)\t' + [regex]::Escape($Title) + '\t')) {
            return $Matches[1]
        }
    }
    return $null
}

function Start-TestSession {
    param([string]$AppName, [string]$Title)
    $out = & $TALKIE new-session $AppName $Title 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $paneId = $null
    if ($out -match 'PANE=(wtcc-[0-9a-f]+)') { $paneId = $Matches[1] }

    if ($exitCode -ne 0 -and -not $paneId) {
        # new-session timed out on a non-ready UI (trust/update/model prompt). Recover pane from list-sessions.
        Write-Host '    new-session timed out on non-ready UI, recovering pane...' -ForegroundColor DarkGray
        $paneId = Recover-PaneByTitle $Title
        if ($paneId) { Write-Host ('    recovered pane: ' + $paneId) -ForegroundColor DarkGray }
    }

    return [pscustomobject]@{
        Pane = $paneId
        ExitCode = $exitCode
        Output = $out
    }
}

function Remove-TestDirectory {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $tempRoot = [System.IO.Path]::GetTempPath().TrimEnd('\')
    $leaf = Split-Path -Leaf $resolved
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith('agent-talk-trust-', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected test directory: $resolved"
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ($true) {
        try {
            Remove-Item -LiteralPath $resolved -Recurse -Force
            return
        } catch {
            if ((Get-Date) -ge $deadline) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Invoke-TrustDirStartupCheck {
    param([string]$AppName, [hashtable]$Adapter)
    if ($SkipTrustDirCheck) { return }
    if ([string]$Adapter.App -eq 'pi') {
        Write-Host "`n== 0. trust-dir startup unknown ==" -ForegroundColor Cyan
        Write-Host '  skipped for pi' -ForegroundColor DarkGray
        return
    }

    Write-Host "`n== 0. trust-dir startup unknown ==" -ForegroundColor Cyan
    $trustDir = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-talk-trust-' + $Adapter.App + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $trustDir -Force | Out-Null
    Write-Host ('    WorkDir: ' + $trustDir) -ForegroundColor DarkGray
    $trustPane = $null
    $previousTimeout = $env:AGENT_TALK_NEW_SESSION_READY_TIMEOUT_SEC
    try {
        Set-Location $trustDir
        $env:AGENT_TALK_NEW_SESSION_READY_TIMEOUT_SEC = '12'
        $title = 'test-adapter-' + $AppName + '-trust-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $result = Start-TestSession -AppName $AppName -Title $title
        $trustPane = $result.Pane

        Report 'trust-dir pane exists' ($null -ne $trustPane) ('output: ' + $result.Output)
        if ($trustPane) {
            $screen = Get-CurrentScreen $trustPane
            $status = & $Adapter.GetStatus $screen
            Report 'GetStatus == unknown (new trust dir startup)' ($status -eq 'unknown') ('got: ' + $status)
            Write-Host ('    tail: ' + (ScreenTail $screen)) -ForegroundColor DarkGray
            if ($result.ExitCode -eq 0 -and $status -ne 'unknown') {
                Write-Host '    new-session reached ready in a fresh directory; no startup trust UI was detected.' -ForegroundColor Yellow
            }
        }
    } finally {
        if ($null -eq $previousTimeout) {
            Remove-Item Env:\AGENT_TALK_NEW_SESSION_READY_TIMEOUT_SEC -ErrorAction SilentlyContinue
        } else {
            $env:AGENT_TALK_NEW_SESSION_READY_TIMEOUT_SEC = $previousTimeout
        }
        Set-Location $origDir
        if ($trustPane) {
            try { & $TALKIE kill-session $trustPane 2>&1 | Out-Null } catch {}
            Write-Host '    trust-dir session killed' -ForegroundColor DarkGray
        }
        Remove-TestDirectory $trustDir
        Write-Host '    trust-dir removed' -ForegroundColor DarkGray
    }
}

# ── load adapter ──
$adapterDir = Join-Path $PSScriptRoot 'agents'
. (Join-Path $adapterDir 'shared.ps1')
$adapterSelection = Resolve-TestAdapter $App
$adapter = [hashtable]$adapterSelection.Adapter
Write-Host ('Adapter: {0} adapter={1} agent={2}' -f (Split-Path -Leaf $adapterSelection.Path), $adapterSelection.AdapterVersion, $adapterSelection.AgentVersion) -ForegroundColor DarkGray

Invoke-TrustDirStartupCheck -AppName $App -Adapter $adapter

# ── switch to WorkDir if specified ──
if ($WorkDir) {
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    Set-Location $WorkDir
    Write-Host ('WorkDir: ' + $WorkDir) -ForegroundColor DarkGray
}

try {

# ━━ 1. new-session ━━
Write-Host "`n== 1. new-session ==" -ForegroundColor Cyan
$title = 'test-adapter-' + $App
$session = Start-TestSession -AppName $App -Title $title
$out = $session.Output
$exitCode = $session.ExitCode
$pane = $session.Pane

Report 'pane exists' ($null -ne $pane) ('output: ' + $out)
if (-not $pane) { throw 'no pane, cannot continue' }

if ($exitCode -ne 0) {
    # ── 1a. startup unknown ──
    Write-Host "`n== 1a. startup unknown ==" -ForegroundColor Cyan
    $screen = & $TALKIE get-screen $pane
    $status = & $adapter.GetStatus $screen
    Report 'GetStatus == unknown (startup UI)' ($status -eq 'unknown') ('got: ' + $status)
    Write-Host ('    tail: ' + (ScreenTail $screen)) -ForegroundColor DarkGray
    Write-Host '    !! startup UI detected. Inspect pane/log and send the appropriate response if needed.' -ForegroundColor Yellow
    Write-Host '    !! then re-run the adapter test.' -ForegroundColor Yellow
} else {
    Report 'READY=1' ($out -match 'READY=1') ('output: ' + $out)
}

# ── remaining tests only if session started successfully ──
if ($exitCode -eq 0) {

# ━━ 2. idle status ━━
Write-Host "`n== 2. idle status ==" -ForegroundColor Cyan
Start-Sleep -Seconds 2
$idle = Require-State 'GetStatus == ready' $pane $adapter.GetStatus @('ready')

# ━━ 3. send ━━
Write-Host "`n== 3. send ==" -ForegroundColor Cyan
$enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Task))
$sendOut = & $TALKIE send $pane ('@base64:' + $enc) 2>&1 | Out-String
Report 'send succeeds' ($sendOut -match 'SENT=') ('output: ' + $sendOut)

# ━━ 4. busy detection (best-effort) ━━
Write-Host "`n== 4. busy detection (best-effort) ==" -ForegroundColor Cyan
Start-Sleep -Seconds 1
$screen = & $TALKIE get-screen $pane
$status = & $adapter.GetStatus $screen
$busyOk = ($status -eq 'busy') -or ($status -eq 'unknown') -or ($status -eq 'ready')
Report 'GetStatus is valid state' $busyOk ('got: ' + $status)
Write-Host ('    observed: ' + $status) -ForegroundColor DarkGray

# ━━ 5. wait-reply ━━
Write-Host "`n== 5. wait-reply ==" -ForegroundColor Cyan
$reply = (& $TALKIE wait-reply $pane $Timeout 2>&1 | Out-String).Trim()
Report 'reply non-empty' ($reply.Length -gt 0) 'empty reply'
Write-Host ('    reply: ' + $reply) -ForegroundColor DarkGray
if ($reply.Length -eq 0) {
    $screen = Get-CurrentScreen $pane
    $status = & $adapter.GetStatus $screen
    if ($status -eq 'unknown') {
        Stop-ManualInspection -Step 'wait-reply after first task' -Pane $pane -Status $status -Screen $screen
    }
}

# ━━ 6. post-reply ready ━━
Write-Host "`n== 6. post-reply status ==" -ForegroundColor Cyan
$postReply = Require-State 'GetStatus == ready' $pane $adapter.GetStatus @('ready')
$screen = $postReply.Screen

# ━━ 7. GetReply ━━
Write-Host "`n== 7. GetReply ==" -ForegroundColor Cyan
$extracted = & $adapter.GetReply $screen
Report 'GetReply non-empty' ($extracted.Length -gt 0) 'empty'
Write-Host ('    extracted: ' + $extracted) -ForegroundColor DarkGray

# ━━ 8. /model unknown ━━
Write-Host "`n== 8. /model unknown ==" -ForegroundColor Cyan
$modelEnc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('/model'))
& $TALKIE send $pane ('@base64:' + $modelEnc) 2>&1 | Out-Null
Start-Sleep -Seconds 3
$screen = & $TALKIE get-screen $pane
$status = & $adapter.GetStatus $screen
Report 'GetStatus == unknown (/model UI)' ($status -eq 'unknown') ('got: ' + $status)
Write-Host ('    tail: ' + (ScreenTail $screen)) -ForegroundColor DarkGray

# ━━ 9. recover from /model ━━
Write-Host "`n== 9. recover from /model ==" -ForegroundColor Cyan
& $TALKIE interrupt $pane 2>&1 | Out-Null
$state = Wait-ForAllowedState -Pane $pane -StatusFn $adapter.GetStatus -Allowed @('ready') -MaxSeconds 15
Report 'GetStatus == ready (after interrupt)' ($state.Status -eq 'ready') ('got: ' + $state.Status)
if ($state.Status -eq 'unknown') {
    Stop-ManualInspection -Step 'recover from /model' -Pane $pane -Status $state.Status -Screen $state.Screen
}

# ━━ 10. second round-trip ━━
Write-Host "`n== 10. second round-trip ==" -ForegroundColor Cyan
$task2 = '2+3=?, answer number only'
$enc2 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($task2))
& $TALKIE send $pane ('@base64:' + $enc2) 2>&1 | Out-Null
$reply2 = (& $TALKIE wait-reply $pane $Timeout 2>&1 | Out-String).Trim()
Report 'second reply non-empty' ($reply2.Length -gt 0) 'empty reply'
Write-Host ('    reply: ' + $reply2) -ForegroundColor DarkGray
$screen2 = Get-CurrentScreen $pane
$status2 = & $adapter.GetStatus $screen2
Report 'ready after second reply' ($status2 -eq 'ready') ('got: ' + $status2)
if ($reply2.Length -eq 0 -or $status2 -eq 'unknown') {
    Stop-ManualInspection -Step 'second round-trip' -Pane $pane -Status $status2 -Screen $screen2
}

}  # end if exitCode -eq 0

} finally {
    Set-Location $origDir
    if ($pane -and -not $keepPane) {
        Write-Host "`n== cleanup ==" -ForegroundColor Cyan
        try { & $TALKIE kill-session $pane 2>&1 | Out-Null } catch {}
        Write-Host '  session killed'
    } elseif ($pane) {
        Write-Host "`n== cleanup ==" -ForegroundColor Cyan
        Write-Host ('  keeping session for inspection: ' + $pane) -ForegroundColor Yellow
    }
}

# ━━ summary ━━
Write-Host "`n======================" -ForegroundColor White
$total = $pass + $fail
$color = if ($fail -eq 0) { 'Green' } else { 'Yellow' }
Write-Host ('  ' + $App + ' adapter: ' + $pass + '/' + $total + ' passed') -ForegroundColor $color
if ($fail -gt 0) { exit 1 }

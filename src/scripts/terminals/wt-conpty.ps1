param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('spawn', 'send', 'interrupt', 'kill', '_health-check')]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$ShimScript = Join-Path $PSScriptRoot 'wt-conpty-shim.ps1'
$WtProfileName = 'Agent Talk ConPTY'
$WtProfileGuid = '{eb5f1f08-9c5e-4d57-a3c8-a6e17b0c0001}'

function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-WindowsTerminalSettingsPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Ensure-WindowsTerminalProfile {
    if ($env:WT_CONPTY_SKIP_PROFILE_CONFIG -eq '1') { return $false }
    $settingsPath = Get-WindowsTerminalSettingsPath
    if (-not $settingsPath) { return $false }

    $raw = Get-Content -Encoding UTF8 -Raw -LiteralPath $settingsPath
    $settings = $raw | ConvertFrom-Json
    if (-not $settings.profiles) {
        $settings | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $settings.profiles.list) {
        $settings.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force
    }

    $profile = $null
    foreach ($item in @($settings.profiles.list)) {
        if ([string]$item.name -eq $WtProfileName -or [string]$item.guid -eq $WtProfileGuid) {
            $profile = $item
            break
        }
    }

    $changed = $false
    $desired = @{
        guid = $WtProfileGuid
        name = $WtProfileName
        hidden = $true
        commandline = 'powershell.exe'
        closeOnExit = 'always'
        suppressApplicationTitle = $true
    }
    if (-not $profile) {
        $profile = [pscustomobject]$desired
        $settings.profiles.list = @($settings.profiles.list) + $profile
        $changed = $true
    } else {
        foreach ($key in $desired.Keys) {
            $current = Get-Prop $profile $key
            if ([string]$current -ne [string]$desired[$key]) {
                $profile | Add-Member -NotePropertyName $key -NotePropertyValue $desired[$key] -Force
                $changed = $true
            }
        }
    }

    if ($changed) {
        $backup = $settingsPath + '.codex-bak-' + (Get-Date -Format 'yyyyMMddHHmmssfff')
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
        $settings | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 -LiteralPath $settingsPath
    }
    return $true
}

function Send-PipeText {
    param([string]$PipeName, [string]$Text, [int]$TimeoutMilliseconds = 5000)
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::Out)
    $pipe.Connect($TimeoutMilliseconds)
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.IO.StreamWriter]::new($pipe, $utf8)
    $writer.Write($Text)
    $writer.Flush()
    $writer.Dispose()
    $pipe.Dispose()
}

function Close-WindowsTerminalTabByTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $tabCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem
        )
        $buttonCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button
        )
        foreach ($proc in @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })) {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
            if (-not $root) { continue }
            $tabs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
            for ($i = 0; $i -lt $tabs.Count; $i++) {
                $tab = $tabs.Item($i)
                if ([string]$tab.Current.Name -ne $Title) { continue }
                $buttons = $tab.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCond)
                for ($j = 0; $j -lt $buttons.Count; $j++) {
                    $button = $buttons.Item($j)
                    $name = [string]$button.Current.Name
                    if ($name -and $name -notmatch '(?i)close|关闭') { continue }
                    try {
                        $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                        $invoke.Invoke()
                        return $true
                    } catch {}
                }
            }
        }
    } catch {}
    return $false
}

function Invoke-Spawn {
    if ($Rest.Count -lt 7) {
        throw 'spawn requires <handle> <title> <workspace> <child-file> <child-args> <log-path> <meta-path> [input-mode]'
    }
    $handle = $Rest[0]
    $title = $Rest[1]
    $workspace = $Rest[2]
    $childFile = $Rest[3]
    $childArgs = $Rest[4]
    $logPath = $Rest[5]
    $metaPath = $Rest[6]
    $inputMode = if ($Rest.Count -ge 8) { $Rest[7] } else { 'console' }

    Remove-Item -LiteralPath $logPath, $metaPath -Force -ErrorAction SilentlyContinue
    $wt = Get-Command wt.exe -ErrorAction Stop
    $profileReady = Ensure-WindowsTerminalProfile
    $wtArgs = @('-w', '0', 'new-tab')
    if ($profileReady) { $wtArgs += @('--profile', $WtProfileName) }
    $wtArgs += @(
        '--title', $title,
        '--suppressApplicationTitle',
        '-d', $workspace,
        'powershell.exe',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ShimScript,
        '-PipeName', $handle,
        '-LogPath', $logPath,
        '-MetaPath', $metaPath,
        '-TabTitle', $title,
        '-ChildFile', $childFile,
        '-ChildArgs', $childArgs,
        '-InputMode', $inputMode
    )
    & $wt.Source @wtArgs | Out-Null

    $readyWait = 15
    if ($env:WT_CONPTY_SPAWN_READY_WAIT_SEC) {
        $readyWait = [int]$env:WT_CONPTY_SPAWN_READY_WAIT_SEC
    }
    $deadline = (Get-Date).AddSeconds($readyWait)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $logPath) {
            $text = Get-Content -Encoding UTF8 -Raw -LiteralPath $logPath
            if ($text -match '\[conpty\] READY') { $ready = $true; break }
            if ($text -match '\[conpty\] ERROR') { break }
        }
        Start-Sleep -Milliseconds 250
    }

    $childPid = 0
    if (Test-Path -LiteralPath $metaPath) {
        try {
            $meta = Get-Content -Encoding UTF8 -Raw -LiteralPath $metaPath | ConvertFrom-Json
            $childPid = [int]$meta.child_pid
        } catch {}
    }

    "HANDLE=$handle"
    "KIND=wt-conpty"
    "PID=$childPid"
    "LOG_PATH=$logPath"
    "META_PATH=$metaPath"
    "READY=$([int]$ready)"
}

function Invoke-Send {
    if ($Rest.Count -lt 2) { throw 'send requires <handle> <text>' }
    Send-PipeText -PipeName $Rest[0] -Text $Rest[1]
    "SENT=$($Rest[0])"
}

function Invoke-Interrupt {
    if ($Rest.Count -lt 1) { throw 'interrupt requires <handle>' }
    Send-PipeText -PipeName $Rest[0] -Text ([string][char]0x1b)
    "INTERRUPTED=$($Rest[0])"
}

function Invoke-Kill {
    if ($Rest.Count -lt 2) { throw 'kill requires <handle> <title>' }
    $handle = $Rest[0]
    $title = $Rest[1]
    $closed = $false
    $closeDeadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $closeDeadline) {
        if (Close-WindowsTerminalTabByTitle $title) {
            $closed = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $closed) {
        "KILL_FAILED=$handle reason=close_button_not_found"
        exit 1
    }
    "KILLED=$handle"
}

switch ($Command) {
    'spawn' { Invoke-Spawn }
    'send' { Invoke-Send }
    'interrupt' { Invoke-Interrupt }
    'kill' { Invoke-Kill }
    '_health-check' {
        "TERMINAL=wt-conpty"
        "WT=$(if (Get-Command wt.exe -ErrorAction SilentlyContinue) { 'ok' } else { 'missing' })"
        "CONPTY=available"
    }
}



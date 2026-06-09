param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('new-session', 'send', 'interrupt', 'wait-reply', 'list-sessions', 'list-agents', 'kill-session', 'get-screen', '_health-check')]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$StateRoot = if ($env:WT_CONPTY_CC_STATE_DIR) {
    $env:WT_CONPTY_CC_STATE_DIR
} else {
    Join-Path $PSScriptRoot '..\state\wt-conpty'
}
$LogDir = Join-Path $StateRoot 'logs'
$MetaDir = Join-Path $StateRoot 'meta'
$TerminalTool = if ($env:AGENT_TALK_TERMINAL_TOOL) {
    $env:AGENT_TALK_TERMINAL_TOOL
} else {
    Join-Path $PSScriptRoot 'terminals\wt-conpty.ps1'
}
$SessionPath = if ($env:AGENT_TALK_STATE_PATH) {
    $env:AGENT_TALK_STATE_PATH
} else {
    Join-Path $StateRoot 'sessions.json'
}
$ReplyPollIntervalSeconds = 1.0

function Ensure-StateDirs {
    foreach ($dir in @($StateRoot, $LogDir, $MetaDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }
    $sessionDir = Split-Path -Parent $SessionPath
    if ($sessionDir -and -not (Test-Path -LiteralPath $sessionDir)) {
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $SessionPath)) {
        '[]' | Set-Content -Encoding UTF8 -LiteralPath $SessionPath
    }
}

function Read-Sessions {
    Ensure-StateDirs
    $raw = Get-Content -Encoding UTF8 -Raw -LiteralPath $SessionPath
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $items = $raw | ConvertFrom-Json
    if ($null -eq $items) { return @() }
    return @($items)
}

function Write-Sessions {
    param([object[]]$Items)
    Ensure-StateDirs
    if (-not $Items -or @($Items).Count -eq 0) {
        '[]' | Set-Content -Encoding UTF8 -LiteralPath $SessionPath
    } else {
        @($Items) | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $SessionPath
    }
}

function ConvertTo-SafeId {
    param([string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { '{0:x2}' -f $_ }) -join ''
    return 'wtcc-' + $hash.Substring(0, 16)
}

function New-SessionId {
    param([string]$Value)
    $prefix = ConvertTo-SafeId $Value
    $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    return "$prefix-$suffix"
}

function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [hashtable] -and $Obj.ContainsKey($Name)) { return $Obj[$Name] }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Invoke-Terminal {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & $TerminalTool @Arguments
}

function Get-SessionId {
    param($Session)
    $sessionId = Get-Prop $Session 'session_id'
    if ($sessionId) { return [string]$sessionId }
    $pipe = Get-Prop $Session 'pipe'
    if ($pipe) { return [string]$pipe }
    $transport = Get-Prop $Session 'transport'
    if ($transport) {
        $handle = Get-Prop $transport 'handle'
        if ($handle) { return [string]$handle }
    }
    return ''
}

function Get-TransportValue {
    param($Session, [string]$Name)
    $transport = Get-Prop $Session 'transport'
    if ($transport) {
        $value = Get-Prop $transport $Name
        if ($null -ne $value -and [string]$value -ne '') { return $value }
    }
    switch ($Name) {
        'handle' { return (Get-Prop $Session 'pipe') }
        'pid' { return (Get-Prop $Session 'child_pid') }
        default { return (Get-Prop $Session $Name) }
    }
}

function New-TransportSessionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Kind = 'wt-conpty',
        [string]$Status = 'unknown',
        [int]$ProcessId = 0,
        [string]$LogPath,
        [string]$MetaPath,
        [string]$Workspace,
        [string]$AgentVersion,
        [string]$AdapterVersion,
        [string]$AdapterPath,
        [string]$CreatedAt
    )
    $now = (Get-Date).ToString('o')
    if (-not $CreatedAt) { $CreatedAt = $now }
    return [pscustomobject][ordered]@{
        session_id = $SessionId
        app = $App
        agent_version = $AgentVersion
        adapter_version = $AdapterVersion
        adapter_path = $AdapterPath
        title = $Title
        status = $Status
        transport = [pscustomobject][ordered]@{
            kind = $Kind
            handle = $SessionId
            pid = $ProcessId
            log_path = $LogPath
            meta_path = $MetaPath
            workspace = $Workspace
        }
        created_at = $CreatedAt
        updated_at = $now
    }
}

function Test-ProcessAlive {
    param($PidValue)
    if (-not $PidValue) { return $false }
    try {
        $p = Get-Process -Id ([int]$PidValue) -ErrorAction Stop
        return ($null -ne $p)
    } catch {
        return $false
    }
}

function Get-SessionByPipe {
    param([string]$PipeName)
    @(Read-Sessions | Where-Object {
        (Get-SessionId $_) -eq $PipeName -or [string](Get-TransportValue $_ 'handle') -eq $PipeName
    } | Select-Object -First 1)
}

function Set-SessionLastSentText {
    param([string]$PipeName, [string]$Text)
    $sessions = @(Read-Sessions)
    $changed = $false
    $now = (Get-Date).ToString('o')
    foreach ($s in $sessions) {
        if ((Get-SessionId $s) -eq $PipeName -or [string](Get-TransportValue $s 'handle') -eq $PipeName) {
            $s | Add-Member -NotePropertyName last_sent_text -NotePropertyValue ($Text.Trim()) -Force
            $s | Add-Member -NotePropertyName last_sent_at -NotePropertyValue $now -Force
            $s | Add-Member -NotePropertyName updated_at -NotePropertyValue $now -Force
            $changed = $true
            break
        }
    }
    if ($changed) { Write-Sessions $sessions }
}

function Remove-SessionArtifacts {
    param($Session)
    foreach ($name in @('log_path', 'meta_path')) {
        $path = [string](Get-TransportValue $Session $name)
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-OrphanSessionArtifacts {
    $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in Read-Sessions) {
        foreach ($name in @('log_path', 'meta_path')) {
            $path = [string](Get-TransportValue $s $name)
            if ($path) { [void]$referenced.Add([System.IO.Path]::GetFullPath($path)) }
        }
    }
    foreach ($dir in @($LogDir, $MetaDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue) {
            if (-not $referenced.Contains($file.FullName)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-LiveSessions {
    $live = @()
    $changed = $false
    foreach ($s in Read-Sessions) {
        $metaPath = [string](Get-TransportValue $s 'meta_path')
        $childPid = Get-TransportValue $s 'pid'
        if ($metaPath -and (Test-Path -LiteralPath $metaPath)) {
            try {
                $meta = Get-Content -Encoding UTF8 -Raw -LiteralPath $metaPath | ConvertFrom-Json
                if ($meta.child_pid -and [string]$meta.child_pid -ne [string]$childPid) {
                    if (-not (Get-Prop $s 'transport')) {
                        $s | Add-Member -NotePropertyName transport -NotePropertyValue ([pscustomobject]@{}) -Force
                    }
                    $s.transport | Add-Member -NotePropertyName pid -NotePropertyValue ([int]$meta.child_pid) -Force
                    $changed = $true
                }
            } catch {}
        }
        if (Test-ProcessAlive (Get-TransportValue $s 'pid')) {
            $computedStatus = 'error'
            try { $computedStatus = Get-SessionStatus $s } catch {}
            if ([string](Get-Prop $s 'status') -ne $computedStatus) {
                $s | Add-Member -NotePropertyName status -NotePropertyValue $computedStatus -Force
                $s | Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
                $changed = $true
            }
            $live += $s
        } else {
            $changed = $true
        }
    }
    if ($changed) { Write-Sessions $live }
    return @($live)
}

function Decode-Message {
    param([string]$Text)
    if ($Text.StartsWith('@base64:')) {
        $b64 = $Text.Substring('@base64:'.Length)
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    }
    return $Text
}

function Ensure-VtScreenRenderer {
    if ([type]::GetType('AgentTalk.VtScreenRenderer', $false)) { return }
    $source = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace AgentTalk
{
    public static class VtScreenRenderer
    {
        public static string Render(string input, int cols, int rows)
        {
            return Render(input, cols, rows, 0);
        }

        public static string Render(string input, int cols, int rows, int scrollbackRows)
        {
            if (cols <= 0) cols = 120;
            if (rows <= 0) rows = 40;
            if (scrollbackRows < 0) scrollbackRows = 0;
            var screen = new char[rows, cols];
            Clear(screen, rows, cols);
            var scrollback = new List<string>();
            int r = 0, c = 0, savedR = 0, savedC = 0;
            bool wrapPending = false;

            for (int i = 0; i < input.Length; i++)
            {
                char ch = input[i];
                if (ch == '\u001b')
                {
                    if (i + 1 >= input.Length) break;
                    char next = input[++i];
                    if (next == '[')
                    {
                        var seq = new StringBuilder();
                        while (i + 1 < input.Length)
                        {
                            char q = input[++i];
                            seq.Append(q);
                            if (q >= '@' && q <= '~') break;
                        }
                        ApplyCsi(seq.ToString(), screen, rows, cols, ref r, ref c, ref savedR, ref savedC, ref wrapPending);
                    }
                    else if (next == ']')
                    {
                        while (i + 1 < input.Length)
                        {
                            char q = input[++i];
                            if (q == '\u0007') break;
                            if (q == '\u001b' && i + 1 < input.Length && input[i + 1] == '\\') { i++; break; }
                        }
                    }
                    else if (next == '(' || next == ')')
                    {
                        if (i + 1 < input.Length) i++;
                    }
                    continue;
                }

                if (ch == '\r') { c = 0; wrapPending = false; continue; }
                if (ch == '\n') { NewLine(screen, rows, cols, ref r, ref c, scrollback, scrollbackRows); wrapPending = false; continue; }
                if (ch == '\b') { if (c > 0) c--; wrapPending = false; continue; }
                if (Char.IsControl(ch)) { wrapPending = false; continue; }

                if (wrapPending)
                {
                    NewLine(screen, rows, cols, ref r, ref c, scrollback, scrollbackRows);
                    wrapPending = false;
                }
                int width = CharCellWidth(ch);
                if (width <= 0) continue;
                if (c + width > cols)
                {
                    NewLine(screen, rows, cols, ref r, ref c, scrollback, scrollbackRows);
                }
                screen[r, c] = ch;
                if (width == 2 && c + 1 < cols) screen[r, c + 1] = '\0';
                c += width;
                if (c >= cols)
                {
                    c = cols - 1;
                    wrapPending = true;
                }
            }

            var lines = new List<string>();
            lines.AddRange(scrollback);
            for (int y = 0; y < rows; y++)
            {
                lines.Add(BuildLine(screen, y, cols));
            }
            return string.Join("\n", lines).Trim();
        }

        private static void ApplyCsi(string seq, char[,] screen, int rows, int cols, ref int r, ref int c, ref int savedR, ref int savedC, ref bool wrapPending)
        {
            if (String.IsNullOrEmpty(seq)) return;
            char final = seq[seq.Length - 1];
            string body = seq.Substring(0, seq.Length - 1);
            body = body.TrimStart('?', '>', '!');
            int[] p = ParseParams(body);
            int n = p.Length > 0 && p[0] > 0 ? p[0] : 1;

            switch (final)
            {
                case 'A': wrapPending = false; r = Clamp(r - n, 0, rows - 1); break;
                case 'B': wrapPending = false; r = Clamp(r + n, 0, rows - 1); break;
                case 'C': wrapPending = false; c = Clamp(c + n, 0, cols - 1); break;
                case 'D': wrapPending = false; c = Clamp(c - n, 0, cols - 1); break;
                case 'G': wrapPending = false; c = Clamp(n - 1, 0, cols - 1); break;
                case 'd': wrapPending = false; r = Clamp(n - 1, 0, rows - 1); break;
                case 'H':
                case 'f':
                    wrapPending = false;
                    r = Clamp((p.Length > 0 && p[0] > 0 ? p[0] : 1) - 1, 0, rows - 1);
                    c = Clamp((p.Length > 1 && p[1] > 0 ? p[1] : 1) - 1, 0, cols - 1);
                    break;
                case 'J':
                    wrapPending = false;
                    if (p.Length == 0 || p[0] == 0) ClearFromCursor(screen, rows, cols, r, c);
                    else if (p[0] == 1) ClearToCursor(screen, rows, cols, r, c);
                    else if (p[0] == 2 || p[0] == 3) Clear(screen, rows, cols);
                    break;
                case 'K':
                    wrapPending = false;
                    if (p.Length == 0 || p[0] == 0) for (int x = c; x < cols; x++) screen[r, x] = ' ';
                    else if (p[0] == 1) for (int x = 0; x <= c; x++) screen[r, x] = ' ';
                    else if (p[0] == 2) for (int x = 0; x < cols; x++) screen[r, x] = ' ';
                    break;
                case 's': savedR = r; savedC = c; break;
                case 'u': wrapPending = false; r = savedR; c = savedC; break;
            }
        }

        private static int[] ParseParams(string body)
        {
            if (String.IsNullOrWhiteSpace(body)) return new int[0];
            var parts = body.Split(';');
            var values = new List<int>();
            foreach (var raw in parts)
            {
                int v;
                values.Add(Int32.TryParse(raw, out v) ? v : 0);
            }
            return values.ToArray();
        }

        private static int CharCellWidth(char ch)
        {
            var category = CharUnicodeInfo.GetUnicodeCategory(ch);
            if (category == UnicodeCategory.NonSpacingMark || category == UnicodeCategory.EnclosingMark) return 0;
            int code = ch;
            if ((code >= 0x1100 && code <= 0x115F) ||
                (code >= 0x2329 && code <= 0x232A) ||
                (code >= 0x2E80 && code <= 0xA4CF) ||
                (code >= 0xAC00 && code <= 0xD7A3) ||
                (code >= 0xF900 && code <= 0xFAFF) ||
                (code >= 0xFE10 && code <= 0xFE19) ||
                (code >= 0xFE30 && code <= 0xFE6F) ||
                (code >= 0xFF00 && code <= 0xFF60) ||
                (code >= 0xFFE0 && code <= 0xFFE6)) return 2;
            return 1;
        }

        private static void NewLine(char[,] screen, int rows, int cols, ref int r, ref int c, List<string> scrollback, int scrollbackRows)
        {
            c = 0;
            if (r < rows - 1) { r++; return; }
            if (scrollbackRows > 0)
            {
                var line = BuildLine(screen, 0, cols);
                if (line.Length > 0) scrollback.Add(line);
                while (scrollback.Count > scrollbackRows) scrollback.RemoveAt(0);
            }
            for (int y = 1; y < rows; y++)
                for (int x = 0; x < cols; x++)
                    screen[y - 1, x] = screen[y, x];
            for (int x = 0; x < cols; x++) screen[rows - 1, x] = ' ';
        }

        private static void Clear(char[,] screen, int rows, int cols)
        {
            for (int y = 0; y < rows; y++)
                for (int x = 0; x < cols; x++)
                    screen[y, x] = ' ';
        }

        private static string BuildLine(char[,] screen, int row, int cols)
        {
            var sb = new StringBuilder();
            for (int x = 0; x < cols; x++)
            {
                char ch = screen[row, x];
                if (ch != '\0') sb.Append(ch);
            }
            return sb.ToString().TrimEnd();
        }

        private static void ClearFromCursor(char[,] screen, int rows, int cols, int r, int c)
        {
            for (int x = c; x < cols; x++) screen[r, x] = ' ';
            for (int y = r + 1; y < rows; y++)
                for (int x = 0; x < cols; x++)
                    screen[y, x] = ' ';
        }

        private static void ClearToCursor(char[,] screen, int rows, int cols, int r, int c)
        {
            for (int y = 0; y < r; y++)
                for (int x = 0; x < cols; x++)
                    screen[y, x] = ' ';
            for (int x = 0; x <= c; x++) screen[r, x] = ' ';
        }

        private static int Clamp(int v, int min, int max)
        {
            if (v < min) return min;
            if (v > max) return max;
            return v;
        }
    }
}
'@
    Add-Type -TypeDefinition $source
}

function ConvertTo-PlainText {
    param([string]$Raw, [int]$ScrollbackRows = 0)
    if (-not $Raw) { return '' }
    $text = $Raw
    $cols = 120
    $rows = 40
    if ($text -match '(?m)^\[conpty\] size=(\d+)x(\d+)') {
        $cols = [int]$matches[1]
        $rows = [int]$matches[2]
    }
    $text = [regex]::Replace($text, '(?m)^\[conpty\].*(\r?\n)?', '')
    $text = [regex]::Replace($text, '\[pipe-in\].*(\r?\n)?', '')
    $scrollbackRows = [Math]::Max(0, $ScrollbackRows)
    Ensure-VtScreenRenderer
    $screen = [AgentTalk.VtScreenRenderer]::Render($text, $cols, $rows, $scrollbackRows)
    return (($screen -replace "`n{3,}", "`n`n").Trim())
}

function Get-ReplyScrollbackRows {
    $scrollbackRows = 400
    if ($env:AGENT_TALK_SCROLLBACK_ROWS) {
        $scrollbackRows = [Math]::Max(0, [int]$env:AGENT_TALK_SCROLLBACK_ROWS)
    }
    return $scrollbackRows
}

function Get-StableIdleMilliseconds {
    $milliseconds = 3000
    if ($env:AGENT_TALK_STABLE_IDLE_MS) {
        $milliseconds = [Math]::Max(100, [int]$env:AGENT_TALK_STABLE_IDLE_MS)
    }
    return $milliseconds
}

function Read-SessionText {
    param([string]$PipeName, [int]$ScrollbackRows = 0)
    $s = Get-SessionByPipe $PipeName
    if (-not $s) { return $null }
    $logPath = [string](Get-TransportValue $s 'log_path')
    if (-not (Test-Path -LiteralPath $logPath)) { return '' }
    $raw = Get-Content -Encoding UTF8 -Raw -LiteralPath $logPath
    ConvertTo-PlainText $raw $ScrollbackRows
}

function Load-AdapterForApp {
    param([string]$AppName, [string]$AgentVersion)
    if (-not $AppName) { $AppName = 'pi' }
    return (Resolve-AgentTalkAdapter -AdapterDir $AdaptersDir -Name $AppName -ExtraArgs '' -AgentVersion $AgentVersion).Adapter
}

function Get-TextStatus {
    # Returns 'ready' / 'busy' / 'unknown'.
    # Delegates to the adapter's GetStatus scriptblock.  Falls back to a
    # generic heuristic only when the adapter omits GetStatus.
    param([string]$Text, [hashtable]$Adapter)
    if (-not $Text) { return 'unknown' }

    if ($Adapter -and $Adapter.GetStatus) {
        return (& $Adapter.GetStatus $Text)
    }

    # Fallback for adapters without GetStatus
    if (Test-TailBusy $Text @('Working\.\.\.', 'Thinking\.\.\.')) { return 'busy' }
    if ($Text -match '(?m)^(PS [A-Z]:\\.*>|[A-Z]:\\.*>)\s*$') { return 'ready' }
    return 'unknown'
}

function Get-SessionStatus {
    param($Session)
    if (-not (Test-ProcessAlive (Get-TransportValue $Session 'pid'))) {
        throw "process dead (pid=$(Get-TransportValue $Session 'pid'))"
    }
    $logPath = [string](Get-TransportValue $Session 'log_path')
    if (-not $logPath -or -not (Test-Path -LiteralPath $logPath)) {
        throw "log file not found: $logPath"
    }
    $text = Read-SessionText (Get-SessionId $Session)
    if (-not $text) {
        throw "session output empty"
    }
    $adapter = Load-AdapterForApp ([string]$Session.app) ([string](Get-Prop $Session 'agent_version'))
    return Get-TextStatus $text $adapter
}

function Get-ReplyText {
    # Delegates to the adapter's GetReply scriptblock.
    # Falls back to a generic last-content-line extraction.
    param([string]$Text, [hashtable]$Adapter, [string]$LastInputText = '')
    if (-not $Text) { return '' }

    if ($Adapter -and $Adapter.GetReply) {
        return (& $Adapter.GetReply $Text $LastInputText)
    }

    # Fallback: skip past last Thinking..., strip busy/separator/chrome, take last line
    $Text = Skip-BeforeLastThinking $Text
    $lines = Select-ContentLines $Text @('Working\.\.\.', 'Thinking\.\.\.') @() $null
    if ($lines.Count -eq 0) { return '' }
    return $lines[$lines.Count - 1]
}

$AdaptersDir = Join-Path $PSScriptRoot 'agents'
. (Join-Path $AdaptersDir 'shared.ps1')

function Resolve-AgentScript {
    param([string]$Name)
    return (Resolve-AgentTalkAdapter -AdapterDir $AdaptersDir -Name $Name -ExtraArgs '').Path
}

function Resolve-AppSpec {
    param([string]$Spec, [string]$ExtraArgs)
    $selection = Resolve-AgentTalkAdapter -AdapterDir $AdaptersDir -Name $Spec -ExtraArgs $ExtraArgs
    $adapterResult = [hashtable]$selection.Adapter
    $adapterResult['DetectedAgentVersion'] = [string]$selection.AgentVersion
    $adapterResult['SelectedAdapterVersion'] = [string]$selection.AdapterVersion
    $adapterResult['SelectedAdapterPath'] = [string]$selection.Path
    return [pscustomobject]$adapterResult
}

function Get-AgentAdapterFallbackValue {
    param([string]$Text, [string]$Name)
    $match = [regex]::Match($Text, "(?m)^\s*$Name\s*=\s*'([^']+)'")
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-AgentAdapterFallbackAliases {
    param([string]$Text)
    $match = [regex]::Match($Text, "(?m)^\s*Aliases\s*=\s*@\(([^)]*)\)")
    if (-not $match.Success) { return @() }
    $aliases = @()
    foreach ($aliasMatch in [regex]::Matches($match.Groups[1].Value, "'([^']+)'")) {
        $aliases += $aliasMatch.Groups[1].Value
    }
    return $aliases
}

function Get-AgentAdapterRecords {
    $records = @()
    foreach ($script in Get-ChildItem -LiteralPath $AdaptersDir -Filter '*.ps1' | Sort-Object Name) {
        if ($script.BaseName -eq 'shared') { continue }
        $text = Get-Content -Encoding UTF8 -Raw -LiteralPath $script.FullName
        $app = Get-AgentAdapterFallbackValue $text 'App'
        if (-not $app) { $app = $script.BaseName }
        $aliases = @(Get-AgentAdapterFallbackAliases $text)
        $commandName = Get-AgentAdapterFallbackValue $text 'AgentCommand'
        $adapterVersion = Get-AgentAdapterFallbackValue $text 'AdapterVersion'
        $minVersion = Get-AgentAdapterFallbackValue $text 'AgentVersionMin'
        $version = ''
        $available = $false
        $compatible = $false
        $errorMessage = ''

        try {
            $adapter = [hashtable](& $script.FullName -ExtraArgs '__default__')
            if ($adapter.App) { $app = [string]$adapter.App }
            if ($adapter.Aliases) { $aliases = @($adapter.Aliases) }
            if ($adapter.AdapterVersion) { $adapterVersion = [string]$adapter.AdapterVersion }
            if ($adapter.AgentVersionMin) { $minVersion = [string]$adapter.AgentVersionMin }
            $commandName = Get-AgentTalkAdapterCommandName $adapter
            $version = Get-AgentTalkAgentVersion $adapter
            $available = $true
            $compatible = Test-AgentTalkVersionMin -Version $version -Min $minVersion
            if (-not $compatible) {
                $errorMessage = "agent version '$version' is lower than required '$minVersion'"
            }
        } catch {
            $errorMessage = $_.Exception.Message
        }

        $records += [pscustomobject][ordered]@{
            app = $app
            aliases = $aliases
            command = $commandName
            available = $available
            compatible = $compatible
            agent_version = $version
            agent_version_min = $minVersion
            adapter_version = $adapterVersion
            adapter_path = $script.FullName
            error = $errorMessage
        }
    }
    return @($records)
}

function Test-AdapterFullScreenTui {
    param($Adapter)
    $value = Get-Prop $Adapter 'UsesFullScreenTui'
    if ($value -is [scriptblock]) {
        return [bool](& $value)
    }
    return [bool]$value
}

function Get-AdapterInputMode {
    param($Adapter)
    $mode = [string](Get-Prop $Adapter 'InputMode')
    if ($mode) {
        $mode = $mode.ToLowerInvariant()
        if ($mode -in @('console', 'vt')) { return $mode }
        throw "Invalid adapter InputMode '$mode'. Expected 'console' or 'vt'."
    }
    if (Test-AdapterFullScreenTui $Adapter) { return 'vt' }
    return 'console'
}

function Invoke-NewSession {
    if ($Rest.Count -lt 2) { throw 'new-session requires <app> <title> [extra-args]' }
    Ensure-StateDirs
    Remove-OrphanSessionArtifacts
    $spec = $Rest[0]
    $title = $Rest[1]
    $extra = if ($Rest.Count -ge 3) { $Rest[2] } else { '__default__' }
    $resolved = Resolve-AppSpec -Spec $spec -ExtraArgs $extra
    $pipe = New-SessionId "$title|$spec|$((Get-Location).Path)"

    $logPath = Join-Path $LogDir "$pipe.log"
    $metaPath = Join-Path $MetaDir "$pipe.json"
    $workspace = (Get-Location).Path
    $inputMode = Get-AdapterInputMode $resolved
    $terminalOut = Invoke-Terminal -Arguments @('spawn', $pipe, $title, $workspace, $resolved.File, $resolved.Args, $logPath, $metaPath, $inputMode)
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "terminal spawn failed (exit $LASTEXITCODE): $($terminalOut -join "`n")"
    }
    $terminalText = $terminalOut -join "`n"
    $terminalKind = if ($terminalText -match '(?m)^KIND=(.+)$') { $matches[1].Trim() } else { 'unknown' }
    $terminalPid = if ($terminalText -match '(?m)^PID=(\d+)$') { [int]$matches[1] } else { 0 }
    $terminalLogPath = if ($terminalText -match '(?m)^LOG_PATH=(.+)$') { $matches[1].Trim() } else { $logPath }
    $terminalMetaPath = if ($terminalText -match '(?m)^META_PATH=(.+)$') { $matches[1].Trim() } else { $metaPath }
    $ready = if ($terminalText -match '(?m)^READY=1$') { $true } else { $false }
    $record = New-TransportSessionRecord `
        -SessionId $pipe `
        -App $resolved.App `
        -Title $title `
        -Kind $terminalKind `
        -Status 'unknown' `
        -ProcessId $terminalPid `
        -LogPath $terminalLogPath `
        -MetaPath $terminalMetaPath `
        -Workspace $workspace `
        -AgentVersion $resolved.DetectedAgentVersion `
        -AdapterVersion $resolved.SelectedAdapterVersion `
        -AdapterPath $resolved.SelectedAdapterPath
    $kept = @(Read-Sessions | Where-Object { (Get-SessionId $_) -ne $pipe -and [string]$_.title -ne $title })
    Write-Sessions @($kept + $record)

    $newSessionReadyTimeout = 45
    if ($env:AGENT_TALK_NEW_SESSION_READY_TIMEOUT_SEC) {
        $newSessionReadyTimeout = [Math]::Max(1, [int]$env:AGENT_TALK_NEW_SESSION_READY_TIMEOUT_SEC)
    }
    $adapter = Load-AdapterForApp $resolved.App $resolved.DetectedAgentVersion
    $state = Wait-NewSessionStatus -PipeName $pipe -Adapter $adapter -MaxSeconds $newSessionReadyTimeout
    $ready = [bool]$state.Ready
    $status = [string]$state.Status
    $sessions = @(Read-Sessions)
    foreach ($s in $sessions) {
        if ((Get-SessionId $s) -eq $pipe) {
            $s | Add-Member -NotePropertyName status -NotePropertyValue $status -Force
            $s | Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
            break
        }
    }
    Write-Sessions $sessions

    "PANE=$pipe"
    "READY=$([int]$ready)"
    "STATUS=$status"
    "APP=$($resolved.App)"
}

function Invoke-Send {
    if ($Rest.Count -lt 2) { throw 'send requires <pane> <message>' }
    $pipe = $Rest[0]
    $message = Decode-Message $Rest[1]
    $lastSentText = $message
    $submitSequence = $null
    $submitSequenceParts = @()
    $submitSequenceSeparate = $false
    $submitDelayMilliseconds = 150
    $submitSequencePartDelayMilliseconds = 150
    $appendMessageNewline = $true
    $pasteMode = 'bracketed'
    $session = Get-SessionByPipe $pipe
    if ($session) {
        $adapter = Load-AdapterForApp ([string]$session.app) ([string](Get-Prop $session 'agent_version'))
        $appendValue = Get-Prop $adapter 'AppendMessageNewline'
        if ($null -ne $appendValue) { $appendMessageNewline = [bool]$appendValue }
        $submitSequence = Get-Prop $adapter 'SubmitSequence'
        if ($submitSequence -is [scriptblock]) { $submitSequence = & $submitSequence }
        $submitSequencePartsValue = Get-Prop $adapter 'SubmitSequenceParts'
        if ($submitSequencePartsValue -is [scriptblock]) { $submitSequencePartsValue = & $submitSequencePartsValue }
        if ($submitSequencePartsValue) { $submitSequenceParts = @($submitSequencePartsValue) }
        $submitSequenceSeparate = [bool](Get-Prop $adapter 'SubmitSequenceSeparate')
        $delayValue = Get-Prop $adapter 'SubmitDelayMilliseconds'
        if ($delayValue) { $submitDelayMilliseconds = [int]$delayValue }
        $partDelayValue = Get-Prop $adapter 'SubmitSequencePartDelayMilliseconds'
        if ($partDelayValue) { $submitSequencePartDelayMilliseconds = [int]$partDelayValue }
        $pasteModeValue = Get-Prop $adapter 'PasteMode'
        if ($pasteModeValue) { $pasteMode = [string]$pasteModeValue }
    }
    if ($appendMessageNewline -and $message -notmatch "(`r|`n)$") { $message += "`r`n" }
    if ($pasteMode -eq 'bracketed' -and $message.Length -gt 0) {
        $message = "$([char]27)[200~$message$([char]27)[201~"
    }
    if ($submitSequence -and -not $submitSequenceSeparate) { $message += [string]$submitSequence }
    if ($message.Length -gt 0) {
        $sendOut = Invoke-Terminal -Arguments @('send', $pipe, $message)
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "terminal send failed (exit $LASTEXITCODE): $($sendOut -join "`n")"
        }
    }
    if ($submitSequence -and $submitSequenceSeparate) {
        if ($submitDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $submitDelayMilliseconds }
        $submitItems = if ($submitSequenceParts.Count -gt 0) { @($submitSequenceParts) } else { @($submitSequence) }
        for ($i = 0; $i -lt $submitItems.Count; $i++) {
            if ($i -gt 0 -and $submitSequencePartDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $submitSequencePartDelayMilliseconds
            }
            $submitOut = Invoke-Terminal -Arguments @('send', $pipe, [string]$submitItems[$i])
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "terminal submit failed (exit $LASTEXITCODE): $($submitOut -join "`n")"
            }
        }
    }
    Set-SessionLastSentText -PipeName $pipe -Text $lastSentText
    "SENT=$pipe"
}

function Invoke-Interrupt {
    if ($Rest.Count -lt 1) { throw 'interrupt requires <pane>' }
    $pipe = $Rest[0]
    $session = Get-SessionByPipe $pipe
    $appName = if ($session) { [string]$session.app } else { 'pi' }
    $adapter = Load-AdapterForApp $appName ([string](Get-Prop $session 'agent_version'))
    $interruptSequence = Get-Prop $adapter 'InterruptSequence'
    if ($interruptSequence -is [scriptblock]) {
        $interruptSequence = & $interruptSequence
    }
    if ($interruptSequence) {
        $interruptOut = Invoke-Terminal -Arguments @('send', $pipe, ([string]$interruptSequence))
    } else {
        $interruptOut = Invoke-Terminal -Arguments @('interrupt', $pipe)
    }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "terminal interrupt failed (exit $LASTEXITCODE): $($interruptOut -join "`n")"
    }
    "INTERRUPTED=$pipe"
}

function Wait-StableIdleText {
    param(
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [int]$MaxSeconds = 60
    )
    $stableSince = $null
    $lastText = ''
    $stableIdleMilliseconds = Get-StableIdleMilliseconds
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    while ((Get-Date) -lt $deadline) {
        $text = Read-SessionText $PipeName
        if ($null -eq $text) { exit 2 }
        if ($text -eq $lastText) {
            if (-not $stableSince) { $stableSince = Get-Date }
        } else {
            $stableSince = $null
            $lastText = $text
        }
        if ($stableSince -and ((Get-Date) - $stableSince).TotalMilliseconds -ge $stableIdleMilliseconds -and (Get-TextStatus $text $adapter) -eq 'ready') {
            return $text
        }
        Start-Sleep -Seconds $ReplyPollIntervalSeconds
    }
    exit 1
}

function Wait-NewSessionStatus {
    param(
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [int]$MaxSeconds = 60
    )
    $stableSince = $null
    $lastText = ''
    $lastStatus = 'unknown'
    $stableIdleMilliseconds = Get-StableIdleMilliseconds
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    while ((Get-Date) -lt $deadline) {
        $text = Read-SessionText $PipeName
        if ($null -eq $text) {
            return [pscustomobject]@{ Ready = $false; Status = 'error' }
        }
        if ($text -eq $lastText) {
            if (-not $stableSince) { $stableSince = Get-Date }
        } else {
            $stableSince = $null
            $lastText = $text
        }
        $lastStatus = Get-TextStatus $text $Adapter
        if ($lastStatus -eq 'error') {
            return [pscustomobject]@{ Ready = $false; Status = 'error' }
        }
        if ($stableSince -and ((Get-Date) - $stableSince).TotalMilliseconds -ge $stableIdleMilliseconds) {
            if ($lastStatus -eq 'ready') {
                return [pscustomobject]@{ Ready = $true; Status = 'ready' }
            }
            if ($lastStatus -eq 'unknown') {
                return [pscustomobject]@{ Ready = $false; Status = $lastStatus }
            }
        }
        Start-Sleep -Seconds $ReplyPollIntervalSeconds
    }
    return [pscustomobject]@{ Ready = $false; Status = $lastStatus }
}

function Invoke-Get {
    if ($Rest.Count -lt 1) { throw 'get-screen requires <pane>' }
    $text = Read-SessionText $Rest[0]
    if ($null -eq $text) { exit 2 }
    $text
}

function Invoke-WaitReply {
    if ($Rest.Count -lt 1) { throw 'wait-reply requires <pane> [max_seconds=60]' }
    $pipe = $Rest[0]
    $max = if ($Rest.Count -ge 2) { [int]$Rest[1] } else { 60 }
    $session = Get-SessionByPipe $pipe
    $appName = if ($session) { [string]$session.app } else { 'pi' }
    $adapter = Load-AdapterForApp $appName ([string](Get-Prop $session 'agent_version'))
    $lastInputText = if ($session) { [string](Get-Prop $session 'last_sent_text') } else { '' }
    Wait-StableIdleText -PipeName $pipe -Adapter $adapter -MaxSeconds $max | Out-Null
    $text = Read-SessionText $pipe (Get-ReplyScrollbackRows)
    if ($null -eq $text) { exit 2 }
    Get-ReplyText $text $adapter $lastInputText
    exit 0
}

function Invoke-ListSessions {
    Remove-OrphanSessionArtifacts
    $format = if ($Rest.Count -ge 1) { $Rest[0] } else { 'table' }
    $sessions = @(Get-LiveSessions)
    if ($format -eq 'json') {
        $sessions | ConvertTo-Json -Depth 8
        return
    }
    if ($format -eq 'tsv') {
        "PANEID`tTITLE`tAPP`tSTATUS`tCWD"
        foreach ($s in $sessions) {
            "$((Get-SessionId $s))`t$($s.title)`t$($s.app)`t$($s.status)`t$(Get-TransportValue $s 'workspace')"
        }
        return
    }
    foreach ($s in $sessions) {
        "{0} {1} [{2}] {3}" -f (Get-SessionId $s), $s.app, $s.status, $s.title
    }
}

function Invoke-ListAgents {
    $format = if ($Rest.Count -ge 1) { $Rest[0] } else { 'json' }
    $records = @(Get-AgentAdapterRecords)
    if ($format -eq 'json') {
        $records | ConvertTo-Json -Depth 8
        return
    }
    throw 'list-agents only supports json output'
}

function Invoke-KillPane {
    if ($Rest.Count -lt 1) { throw 'kill-session requires <pane>' }
    $pipe = $Rest[0]
    $session = Get-SessionByPipe $pipe
    if (-not $session) {
        "KILL_FAILED=$pipe reason=session_not_found"
        exit 1
    }
    $killOut = Invoke-Terminal -Arguments @('kill', $pipe, ([string]$session.title))
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        $killOut
        exit 1
    }
    $kept = @(Read-Sessions | Where-Object { (Get-SessionId $_) -ne $pipe -and [string](Get-TransportValue $_ 'handle') -ne $pipe })
    Write-Sessions $kept
    Remove-SessionArtifacts $session
    Remove-OrphanSessionArtifacts
    "KILLED=$pipe"
}

switch ($Command) {
    'new-session' { Invoke-NewSession }
    'send' { Invoke-Send }
    'interrupt' { Invoke-Interrupt }
    'get-screen' { Invoke-Get }
    'wait-reply' { Invoke-WaitReply }
    'list-sessions' { Invoke-ListSessions }
    'list-agents' { Invoke-ListAgents }
    'kill-session' { Invoke-KillPane }
    '_health-check' {
        Invoke-Terminal -Arguments @('_health-check')
        "STATE=$StateRoot"
        "TERMINAL_TOOL=$TerminalTool"
    }
}

param(
    [Parameter(Mandatory = $true)][string]$PipeName,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter(Mandatory = $true)][string]$MetaPath,
    [Parameter(Mandatory = $true)][string]$TabTitle,
    [Parameter(Mandatory = $true)][string]$ChildFile,
    [string]$ChildArgs = '',
    [ValidateSet('console', 'vt')]
    [string]$InputMode = 'console',
    [int]$Cols = 0,
    [int]$Rows = 0
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

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

function Remove-ConptySessionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][string]$MetaPath
    )

    try {
        $metaDir = Split-Path -Parent $MetaPath
        $stateRoot = Split-Path -Parent $metaDir
        $sessionPath = Join-Path $stateRoot 'sessions.json'
        if (-not (Test-Path -LiteralPath $sessionPath)) { return }

        $raw = Get-Content -Encoding UTF8 -Raw -LiteralPath $sessionPath
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $items = @($raw | ConvertFrom-Json)
        $kept = @($items | Where-Object {
            [string]$_.pipe -ne $PipeName -and
            [string]$_.session_id -ne $PipeName -and
            [string]$_.transport.handle -ne $PipeName
        })
        if ($kept.Count -eq 0) {
            '[]' | Set-Content -Encoding UTF8 -LiteralPath $sessionPath
        } else {
            $kept | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $sessionPath
        }
    } catch {}
}

$source = @'
using Microsoft.Win32.SafeHandles;
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WtConptyShim
{
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD { public short X; public short Y; public COORD(short x, short y) { X = x; Y = y; } }

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, int nSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int ResizePseudoConsole(IntPtr hPC, COORD size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    private const int STD_INPUT_HANDLE = -10;
    private const uint ENABLE_LINE_INPUT = 0x0002;
    private const uint ENABLE_ECHO_INPUT = 0x0004;
    private const uint ENABLE_MOUSE_INPUT = 0x0010;
    private const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    private const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    private const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;

    public static int Run(string pipeName, string logPath, string metaPath, string tabTitle, string childFile, string childArgs, string inputMode, int cols, int rows)
    {
        var utf8 = new UTF8Encoding(false);
        Console.OutputEncoding = utf8;
        if (!String.IsNullOrWhiteSpace(tabTitle)) Console.Title = tabTitle;
        if (cols <= 0) cols = Math.Max(20, Console.WindowWidth);
        if (rows <= 0) rows = Math.Max(5, Console.WindowHeight);

        var logDir = Path.GetDirectoryName(logPath);
        if (!String.IsNullOrEmpty(logDir)) Directory.CreateDirectory(logDir);
        var metaDir = Path.GetDirectoryName(metaPath);
        if (!String.IsNullOrEmpty(metaDir)) Directory.CreateDirectory(metaDir);

        using (var log = new StreamWriter(new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), utf8))
        {
            log.AutoFlush = true;
            IntPtr inputRead = IntPtr.Zero, inputWrite = IntPtr.Zero, outputRead = IntPtr.Zero, outputWrite = IntPtr.Zero, hPC = IntPtr.Zero, attrList = IntPtr.Zero;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            try
            {
                var sa = new SECURITY_ATTRIBUTES();
                sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                sa.bInheritHandle = false;

                if (!CreatePipe(out inputRead, out inputWrite, ref sa, 0)) ThrowLast("CreatePipe input");
                if (!CreatePipe(out outputRead, out outputWrite, ref sa, 0)) ThrowLast("CreatePipe output");

                var hr = CreatePseudoConsole(new COORD((short)cols, (short)rows), inputRead, outputWrite, 0, out hPC);
                if (hr != 0) throw new Win32Exception(hr, "CreatePseudoConsole failed");
                CloseHandle(inputRead); inputRead = IntPtr.Zero;
                CloseHandle(outputWrite); outputWrite = IntPtr.Zero;

                var siEx = new STARTUPINFOEX();
                siEx.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                IntPtr attrSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
                attrList = Marshal.AllocHGlobal(attrSize);
                if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize)) ThrowLast("InitializeProcThreadAttributeList");
                if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) ThrowLast("UpdateProcThreadAttribute");
                siEx.lpAttributeList = attrList;

                var commandLine = new StringBuilder(Quote(childFile) + (String.IsNullOrWhiteSpace(childArgs) ? "" : " " + childArgs));
                LogInternal(log, "[conpty] starting child: " + commandLine.ToString());
                if (!CreateProcessW(null, commandLine, IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref siEx, out pi)) ThrowLast("CreateProcessW");

                File.WriteAllText(metaPath, "{\"child_pid\":" + pi.dwProcessId + ",\"pipe\":\"" + JsonEscape(pipeName) + "\",\"size\":\"" + cols + "x" + rows + "\",\"ready_at\":\"" + DateTime.UtcNow.ToString("o") + "\"}", utf8);
                LogInternal(log, "[conpty] child pid=" + pi.dwProcessId);
                LogInternal(log, "[conpty] size=" + cols + "x" + rows);
                LogInternal(log, "[conpty] input_mode=" + inputMode);
                LogInternal(log, "[conpty] READY pipe=" + pipeName);
                LogInternal(log, "[conpty] Send __SHIM_EXIT__ to stop.");

                var outputStream = new FileStream(new SafeFileHandle(outputRead, false), FileAccess.Read, 4096, false);
                var inputStream = new FileStream(new SafeFileHandle(inputWrite, false), FileAccess.Write, 4096, false);
                var inputLock = new object();

                var output = new Thread(() => PumpOutput(outputStream, log));
                output.IsBackground = true;
                output.Start();
                var keyboard = new Thread(() => PumpKeyboard(inputStream, inputLock, inputMode));
                keyboard.IsBackground = true;
                keyboard.Start();
                var resize = new Thread(() => WatchResize(hPC, log, cols, rows));
                resize.IsBackground = true;
                resize.Start();

                bool childExited = false;
                while (!childExited && WaitForSingleObject(pi.hProcess, 0) == 0x00000102)
                {
                    using (var pipe = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous))
                    {
                        var connect = pipe.BeginWaitForConnection(null, null);
                        while (!connect.AsyncWaitHandle.WaitOne(100))
                        {
                            if (WaitForSingleObject(pi.hProcess, 0) != 0x00000102)
                            {
                                childExited = true;
                                break;
                            }
                        }
                        if (childExited) break;
                        pipe.EndWaitForConnection(connect);
                        using (var ms = new MemoryStream())
                        {
                            pipe.CopyTo(ms);
                            var bytes = ms.ToArray();
                            var msg = utf8.GetString(bytes);
                            if (msg == "__SHIM_EXIT__")
                            {
                                if (!String.IsNullOrWhiteSpace(tabTitle)) Console.Title = tabTitle;
                                LogInternal(log, "[conpty] exit requested");
                                WriteInput(inputStream, inputLock, utf8.GetBytes("exit\r\n"));
                                break;
                            }
                            log.WriteLine("[pipe-in] " + msg.Replace("\r", "\\r").Replace("\n", "\\n"));
                            WriteInput(inputStream, inputLock, bytes);
                        }
                    }
                }

                WaitForSingleObject(pi.hProcess, 5000);
                uint exitCode;
                GetExitCodeProcess(pi.hProcess, out exitCode);
                LogInternal(log, "[conpty] child exit=" + exitCode);
                return unchecked((int)exitCode);
            }
            catch (Exception ex)
            {
                LogBoth(log, "[conpty] ERROR " + ex);
                return 1;
            }
            finally
            {
                try { if (!String.IsNullOrWhiteSpace(tabTitle)) Console.Title = tabTitle; } catch {}
                if (attrList != IntPtr.Zero) { DeleteProcThreadAttributeList(attrList); Marshal.FreeHGlobal(attrList); }
                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
                if (hPC != IntPtr.Zero) ClosePseudoConsole(hPC);
                if (inputRead != IntPtr.Zero) CloseHandle(inputRead);
                if (inputWrite != IntPtr.Zero) CloseHandle(inputWrite);
                if (outputRead != IntPtr.Zero) CloseHandle(outputRead);
                if (outputWrite != IntPtr.Zero) CloseHandle(outputWrite);
            }
        }
    }

    private static void PumpOutput(Stream stream, StreamWriter log)
    {
        var stdout = Console.OpenStandardOutput();
        var utf8 = new UTF8Encoding(false);
        var decoder = utf8.GetDecoder();
        var buffer = new byte[4096];
        var chars = new char[utf8.GetMaxCharCount(buffer.Length)];
        while (true)
        {
            int n;
            try { n = stream.Read(buffer, 0, buffer.Length); } catch { break; }
            if (n <= 0) break;
            stdout.Write(buffer, 0, n);
            stdout.Flush();
            int charCount = decoder.GetChars(buffer, 0, n, chars, 0, false);
            if (charCount > 0) log.Write(chars, 0, charCount);
        }
    }

    private static void PumpKeyboard(Stream inputStream, object inputLock, string inputMode)
    {
        var utf8 = new UTF8Encoding(false);
        var overrideMode = Environment.GetEnvironmentVariable("WT_CONPTY_FORWARD_MOUSE");
        if (overrideMode == "0") inputMode = "console";
        else if (overrideMode == "1") inputMode = "vt";

        if (!String.Equals(inputMode, "vt", StringComparison.OrdinalIgnoreCase))
        {
            while (true)
            {
                ConsoleKeyInfo key;
                try { key = Console.ReadKey(true); } catch { break; }
                var bytes = KeyToBytes(key, utf8);
                if (bytes.Length > 0) WriteInput(inputStream, inputLock, bytes);
            }
            return;
        }

        PumpVirtualTerminalInput(inputStream, inputLock);
    }

    private static byte[] KeyToBytes(ConsoleKeyInfo key, Encoding utf8)
    {
        if ((key.Modifiers & ConsoleModifiers.Control) != 0)
        {
            if (key.Key == ConsoleKey.C) return new byte[] { 0x03 };
            if (key.Key == ConsoleKey.D) return new byte[] { 0x04 };
            if (key.Key == ConsoleKey.O) return new byte[] { 0x0F };
            if (key.Key == ConsoleKey.L) return new byte[] { 0x0C };
        }
        switch (key.Key)
        {
            case ConsoleKey.Enter: return new byte[] { 0x0D };
            case ConsoleKey.Backspace: return new byte[] { 0x7F };
            case ConsoleKey.Tab: return new byte[] { 0x09 };
            case ConsoleKey.Escape: return new byte[] { 0x1B };
            case ConsoleKey.UpArrow: return utf8.GetBytes("\x1b[A");
            case ConsoleKey.DownArrow: return utf8.GetBytes("\x1b[B");
            case ConsoleKey.RightArrow: return utf8.GetBytes("\x1b[C");
            case ConsoleKey.LeftArrow: return utf8.GetBytes("\x1b[D");
            case ConsoleKey.Home: return utf8.GetBytes("\x1b[H");
            case ConsoleKey.End: return utf8.GetBytes("\x1b[F");
            case ConsoleKey.Delete: return utf8.GetBytes("\x1b[3~");
            case ConsoleKey.PageUp: return utf8.GetBytes("\x1b[5~");
            case ConsoleKey.PageDown: return utf8.GetBytes("\x1b[6~");
        }
        if (key.KeyChar != '\0') return utf8.GetBytes(new char[] { key.KeyChar });
        return new byte[0];
    }

    private static void PumpVirtualTerminalInput(Stream inputStream, object inputLock)
    {
        var hInput = GetStdHandle(STD_INPUT_HANDLE);
        uint originalMode;
        bool restoreMode = GetConsoleMode(hInput, out originalMode);
        if (restoreMode)
        {
            var forwardMouse = Environment.GetEnvironmentVariable("WT_CONPTY_FORWARD_MOUSE") == "1";
            var mode = originalMode;
            mode |= ENABLE_EXTENDED_FLAGS | ENABLE_VIRTUAL_TERMINAL_INPUT;
            if (forwardMouse) mode |= ENABLE_MOUSE_INPUT;
            else mode &= ~ENABLE_MOUSE_INPUT;
            mode &= ~(ENABLE_QUICK_EDIT_MODE | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT);
            SetConsoleMode(hInput, mode);
        }

        var stdin = Console.OpenStandardInput();
        var buffer = new byte[1024];
        while (true)
        {
            int n;
            try { n = stdin.Read(buffer, 0, buffer.Length); } catch { break; }
            if (n <= 0) break;
            var bytes = new byte[n];
            Buffer.BlockCopy(buffer, 0, bytes, 0, n);
            WriteInput(inputStream, inputLock, bytes);
        }

        if (restoreMode) try { SetConsoleMode(hInput, originalMode); } catch {}
    }

    private static void WatchResize(IntPtr hPC, StreamWriter log, int cols, int rows)
    {
        var lastCols = cols;
        var lastRows = rows;
        while (true)
        {
            Thread.Sleep(500);
            int curCols, curRows;
            try
            {
                curCols = Math.Max(20, Console.WindowWidth);
                curRows = Math.Max(5, Console.WindowHeight);
            }
            catch { continue; }
            if (curCols == lastCols && curRows == lastRows) continue;
            var hr = ResizePseudoConsole(hPC, new COORD((short)curCols, (short)curRows));
            if (hr == 0)
            {
                lastCols = curCols;
                lastRows = curRows;
                log.WriteLine("[conpty] resized=" + curCols + "x" + curRows);
            }
            else
            {
                log.WriteLine("[conpty] resize failed hr=" + hr);
            }
        }
    }

    private static void WriteInput(Stream inputStream, object inputLock, byte[] bytes)
    {
        lock (inputLock)
        {
            inputStream.Write(bytes, 0, bytes.Length);
            inputStream.Flush();
        }
    }

    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }
    private static string JsonEscape(string value) { return value.Replace("\\", "\\\\").Replace("\"", "\\\""); }
    private static void LogInternal(StreamWriter log, string line)
    {
        if (Environment.GetEnvironmentVariable("WT_CONPTY_SHOW_INTERNAL") == "1") Console.WriteLine(line);
        log.WriteLine(line);
    }
    private static void LogBoth(StreamWriter log, string line) { Console.WriteLine(line); log.WriteLine(line); }
    private static void ThrowLast(string operation) { throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed"); }
}
'@

Add-Type -TypeDefinition $source
$exitCode = [WtConptyShim]::Run($PipeName, $LogPath, $MetaPath, $TabTitle, $ChildFile, $ChildArgs, $InputMode, $Cols, $Rows)
Remove-ConptySessionRecord -PipeName $PipeName -MetaPath $MetaPath
if ($env:WT_CONPTY_AUTO_CLOSE_TAB -ne '0') {
    try {
        $closeDelayMs = 1500
        if ($env:WT_CONPTY_AUTO_CLOSE_DELAY_MS) {
            $closeDelayMs = [Math]::Max(0, [int]$env:WT_CONPTY_AUTO_CLOSE_DELAY_MS)
        }
        Write-Host 'Terminal will be closed automatically...'
        Start-Sleep -Milliseconds $closeDelayMs
        Close-WindowsTerminalTabByTitle -Title $TabTitle | Out-Null
    } catch {}
}
exit $exitCode

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class MemohTrayNative {
    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);

    public static IntPtr CreateKillOnCloseJob() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
        int size = Marshal.SizeOf(limits);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size)) {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new Win32Exception(error);
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return job;
    }

    public static void AssignToJob(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private static readonly object LogLock = new object();

    private static void AppendLog(string path, string line) {
        if (line == null) return;
        lock (LogLock) {
            File.AppendAllText(path, line + Environment.NewLine, new UTF8Encoding(false));
        }
    }

    public static Process StartRuntime(string node, string cli, string cwd, string server, string key, string logPath, IntPtr job) {
        AppendLog(logPath, DateTimeOffset.Now.ToString("o") + " starting memoh-runtime");
        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = node;
        startInfo.ArgumentList.Add(cli);
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WorkingDirectory = cwd;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;
        startInfo.StandardOutputEncoding = new UTF8Encoding(false);
        startInfo.StandardErrorEncoding = new UTF8Encoding(false);
        startInfo.Environment["MEMOH_RUNTIME_SERVER"] = server;
        startInfo.Environment["MEMOH_RUNTIME_KEY"] = key;

        Process process = new Process();
        process.StartInfo = startInfo;
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args) { AppendLog(logPath, args.Data); };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args) { AppendLog(logPath, args.Data); };
        if (!process.Start()) throw new InvalidOperationException("Could not start memoh-runtime.");
        try {
            AssignToJob(job, process.Handle);
        }
        catch {
            try { process.Kill(true); } catch { }
            process.Dispose();
            throw;
        }
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }
}
'@

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:memohDir = Join-Path $HOME '.memoh'
$script:keyFile = Join-Path $script:memohDir 'runtime-key.dpapi'
$script:runtimeMeta = Join-Path $script:memohDir 'runtime.json'
$script:runtimeCli = Join-Path $env:APPDATA 'npm\node_modules\@memohai\runtime\dist\cli.mjs'
$script:runtimeLog = Join-Path $script:memohDir 'runtime.log'
$script:trayLog = Join-Path $script:memohDir 'tray.log'
$script:runtimeProcess = $null
$script:userStopped = $false
$script:nextAutoStart = [DateTime]::MinValue
$script:lastState = ''
$script:currentIcon = $null
$script:exiting = $false
$script:launcherProcessId = 0

foreach ($requiredPath in @($script:keyFile, $script:runtimeMeta, $script:runtimeCli)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required Memoh Runtime file is missing: $requiredPath"
    }
}

$trayMutexName = 'Local\MemohTray-' + $env:COMPUTERNAME + '-' + $env:USERNAME
$script:trayMutex = [Threading.Mutex]::new($false, $trayMutexName)
if (-not $script:trayMutex.WaitOne(0)) {
    exit 0
}
$script:runtimeJob = [MemohTrayNative]::CreateKillOnCloseJob()

function Write-TrayLog([string]$Message) {
    "$(Get-Date -Format o) $Message" | Out-File -LiteralPath $script:trayLog -Append -Encoding utf8
}

function Initialize-LauncherWatch {
    try {
        $selfProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $($selfProcess.ParentProcessId)" -ErrorAction Stop
        if ($parentProcess.Name -eq 'wscript.exe' -and $parentProcess.CommandLine -match 'Launch-MemohTray\.vbs') {
            $script:launcherProcessId = [int]$parentProcess.ProcessId
            Write-TrayLog "Watching hidden launcher process (PID $($script:launcherProcessId))."
        }
    }
    catch {
        Write-TrayLog "Could not initialize launcher watch: $($_.Exception.Message)"
    }
}

function Test-LauncherRunning {
    if ($script:launcherProcessId -le 0) { return $true }
    return $null -ne (Get-Process -Id $script:launcherProcessId -ErrorAction SilentlyContinue)
}

function Test-RuntimeRunning {
    if ($null -eq $script:runtimeProcess) {
        return $false
    }
    try {
        return -not $script:runtimeProcess.HasExited
    }
    catch {
        return $false
    }
}

function Stop-StaleRuntimeProcesses {
    $candidates = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -and (
                ($_.Name -eq 'pwsh.exe' -and $_.CommandLine -match '[\\/]start-runtime\.ps1') -or
                ($_.Name -eq 'cmd.exe' -and $_.CommandLine -match 'memoh-runtime\.cmd') -or
                ($_.Name -eq 'node.exe' -and $_.CommandLine -match '@memohai[\\/]runtime.*cli\.mjs')
            )
        }
    foreach ($candidate in $candidates) {
        try {
            Write-TrayLog "Stopping stale Runtime process tree (PID $($candidate.ProcessId))."
            & "$env:SystemRoot\System32\taskkill.exe" /PID $candidate.ProcessId /T /F *> $null
        }
        catch {}
    }
}

function Start-RuntimeProcess {
    if (Test-RuntimeRunning) {
        return
    }
    if ($null -ne $script:runtimeProcess) {
        try { $script:runtimeProcess.Dispose() } catch {}
        $script:runtimeProcess = $null
    }

    $node = (Get-Command node.exe -ErrorAction Stop).Source
    $metadata = Get-Content -LiteralPath $script:runtimeMeta -Raw | ConvertFrom-Json
    $server = [string]$metadata.server
    if ([string]::IsNullOrWhiteSpace($server)) {
        throw "Memoh Runtime server is missing from $script:runtimeMeta"
    }
    $secureKey = Get-Content -LiteralPath $script:keyFile -Raw | ConvertTo-SecureString
    $keyPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPtr)
        $script:userStopped = $false
        $script:runtimeProcess = [MemohTrayNative]::StartRuntime(
            $node,
            $script:runtimeCli,
            $HOME,
            $server,
            $plainKey,
            $script:runtimeLog,
            $script:runtimeJob
        )
    }
    finally {
        $plainKey = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPtr)
    }
    $script:nextAutoStart = [DateTime]::MinValue
    Write-TrayLog "Runtime process started (PID $($script:runtimeProcess.Id))."
}

function Stop-RuntimeProcess([bool]$MarkUserStopped = $true) {
    $script:userStopped = $MarkUserStopped
    if (-not (Test-RuntimeRunning)) {
        if ($null -ne $script:runtimeProcess) {
            try { $script:runtimeProcess.Dispose() } catch {}
            $script:runtimeProcess = $null
        }
        return
    }

    $pidToStop = $script:runtimeProcess.Id
    Write-TrayLog "Stopping Runtime process tree (PID $pidToStop)."
    & "$env:SystemRoot\System32\taskkill.exe" /PID $pidToStop /T /F *> $null
    try { $script:runtimeProcess.WaitForExit(5000) | Out-Null } catch {}
    try { $script:runtimeProcess.Dispose() } catch {}
    $script:runtimeProcess = $null
}

function Restart-RuntimeProcess {
    Stop-RuntimeProcess -MarkUserStopped $false
    Start-Sleep -Milliseconds 500
    Start-RuntimeProcess
}

function New-MemohStatusIcon([System.Drawing.Color]$Color) {
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $brush = [System.Drawing.SolidBrush]::new($Color)
    $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $font = [System.Drawing.Font]::new('Segoe UI', 15, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $format = [System.Drawing.StringFormat]::new()
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    try {
        $graphics.FillEllipse($brush, 1, 1, 30, 30)
        $graphics.DrawString('M', $font, $textBrush, [System.Drawing.RectangleF]::new(0, 0, 32, 31), $format)
        $handle = $bitmap.GetHicon()
        try {
            return ([System.Drawing.Icon]::FromHandle($handle)).Clone()
        }
        finally {
            [MemohTrayNative]::DestroyIcon($handle) | Out-Null
        }
    }
    finally {
        $format.Dispose()
        $font.Dispose()
        $textBrush.Dispose()
        $brush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$script:menu = [System.Windows.Forms.ContextMenuStrip]::new()
$script:statusItem = [System.Windows.Forms.ToolStripMenuItem]::new('Runtime：正在启动…')
$script:statusItem.Enabled = $false

$script:versionItem = [System.Windows.Forms.ToolStripMenuItem]::new('Runtime 版本：读取中…')
$script:versionItem.Enabled = $false
$script:menu.add_Opening({
    try {
        $runtimePackage = Join-Path $env:APPDATA 'npm/node_modules/@memohai/runtime/package.json'
        $runtimeVersion = (Get-Content -LiteralPath $runtimePackage -Raw | ConvertFrom-Json).version
        $script:versionItem.Text = 'Runtime 版本：' + $runtimeVersion
    } catch { $script:versionItem.Text = 'Runtime 版本：未知' }
})
$script:openWebItem = [System.Windows.Forms.ToolStripMenuItem]::new('打开 Memoh')
$script:startItem = [System.Windows.Forms.ToolStripMenuItem]::new('启动 Runtime')
$script:stopItem = [System.Windows.Forms.ToolStripMenuItem]::new('停止 Runtime')
$script:restartItem = [System.Windows.Forms.ToolStripMenuItem]::new('重启 Runtime')
$script:openLogItem = [System.Windows.Forms.ToolStripMenuItem]::new('打开 Runtime 日志')
$script:openFolderItem = [System.Windows.Forms.ToolStripMenuItem]::new('打开配置目录')
$script:exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('退出 Memoh Runtime')

[void]$script:menu.Items.Add($script:statusItem)
[void]$script:menu.Items.Add($script:versionItem)
[void]$script:menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
[void]$script:menu.Items.Add($script:openWebItem)
[void]$script:menu.Items.Add($script:startItem)
[void]$script:menu.Items.Add($script:stopItem)
[void]$script:menu.Items.Add($script:restartItem)
[void]$script:menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
[void]$script:menu.Items.Add($script:openLogItem)
[void]$script:menu.Items.Add($script:openFolderItem)
[void]$script:menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
[void]$script:menu.Items.Add($script:exitItem)

$script:notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$script:notifyIcon.ContextMenuStrip = $script:menu
$script:notifyIcon.Text = 'Memoh Runtime'
$script:notifyIcon.Visible = $true
$script:context = [System.Windows.Forms.ApplicationContext]::new()

function Get-RuntimeConnectionState {
    if (-not (Test-RuntimeRunning)) {
        if ($script:userStopped) { return 'stopped' }
        return 'restarting'
    }
    if (-not (Test-Path -LiteralPath $script:runtimeLog)) {
        return 'connecting'
    }
    try {
        $lines = @(Get-Content -LiteralPath $script:runtimeLog -Tail 100 -ErrorAction Stop)
        $startIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match 'starting memoh-runtime') { $startIndex = $index }
        }
        $statusLines = if ($startIndex -ge 0 -and $startIndex + 1 -lt $lines.Count) {
            @($lines[($startIndex + 1)..($lines.Count - 1)])
        }
        else {
            @()
        }
        $lastStatus = $statusLines |
            Where-Object { $_ -match '^(connected|connecting|disconnected|stopped)(:|$)' } |
            Select-Object -Last 1
        if ($lastStatus -match '^connected($|:)') { return 'online' }
        if ($lastStatus -match '^stopped($|:)') { return 'restarting' }
        return 'connecting'
    }
    catch {
        return 'connecting'
    }
}

function Update-TrayState {
    $running = Test-RuntimeRunning
    $state = Get-RuntimeConnectionState
    $script:statusItem.Text = switch ($state) {
        'online' { 'Runtime：已连接' }
        'connecting' { 'Runtime：正在连接…' }
        'stopped' { 'Runtime：已停止' }
        default { 'Runtime：进程异常，正在重启…' }
    }
    $script:startItem.Enabled = -not $running
    $script:stopItem.Enabled = $running
    $script:restartItem.Enabled = $true

    if ($state -ne $script:lastState) {
        $newIcon = switch ($state) {
            'online' { New-MemohStatusIcon ([System.Drawing.Color]::FromArgb(30, 170, 90)) }
            'connecting' { New-MemohStatusIcon ([System.Drawing.Color]::FromArgb(225, 145, 20)) }
            'stopped' { New-MemohStatusIcon ([System.Drawing.Color]::FromArgb(125, 125, 125)) }
            default { New-MemohStatusIcon ([System.Drawing.Color]::FromArgb(200, 55, 55)) }
        }
        $oldIcon = $script:currentIcon
        $script:currentIcon = $newIcon
        $script:notifyIcon.Icon = $newIcon
        if ($null -ne $oldIcon) { $oldIcon.Dispose() }
        $script:notifyIcon.Text = switch ($state) {
            'online' { 'Memoh Runtime - Connected' }
            'connecting' { 'Memoh Runtime - Connecting' }
            'stopped' { 'Memoh Runtime - Stopped' }
            default { 'Memoh Runtime - Restarting' }
        }
        $script:lastState = $state
    }
}

$script:openWebItem.add_Click({ Start-Process (([string](Get-Content -LiteralPath $script:runtimeMeta -Raw | ConvertFrom-Json).server) -replace '/api/?$', '') })
$script:startItem.add_Click({
    try { Start-RuntimeProcess; Update-TrayState }
    catch { Write-TrayLog "Start failed: $($_.Exception.Message)"; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Memoh Runtime') | Out-Null }
})
$script:stopItem.add_Click({
    try { Stop-RuntimeProcess -MarkUserStopped $true; Update-TrayState }
    catch { Write-TrayLog "Stop failed: $($_.Exception.Message)" }
})
$script:restartItem.add_Click({
    try { Restart-RuntimeProcess; Update-TrayState }
    catch { Write-TrayLog "Restart failed: $($_.Exception.Message)"; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Memoh Runtime') | Out-Null }
})
$script:openLogItem.add_Click({
    if (-not (Test-Path -LiteralPath $script:runtimeLog)) { New-Item -ItemType File -Path $script:runtimeLog -Force | Out-Null }
    Start-Process notepad.exe -ArgumentList $script:runtimeLog
})
$script:openFolderItem.add_Click({ Start-Process explorer.exe -ArgumentList $script:memohDir })
$script:notifyIcon.add_DoubleClick({ Start-Process (([string](Get-Content -LiteralPath $script:runtimeMeta -Raw | ConvertFrom-Json).server) -replace '/api/?$', '') })
$script:exitItem.add_Click({
    $script:exiting = $true
    try { Stop-RuntimeProcess -MarkUserStopped $true } catch {}
    $script:context.ExitThread()
})

$script:timer = [System.Windows.Forms.Timer]::new()
$script:timer.Interval = 2000
$script:timer.add_Tick({
    try {
        if (-not (Test-LauncherRunning)) {
            Write-TrayLog 'Hidden launcher stopped; shutting down Tray and Runtime.'
            $script:exiting = $true
            try { Stop-RuntimeProcess -MarkUserStopped $true } catch {}
            $script:context.ExitThread()
            return
        }
        if ($null -ne $script:runtimeProcess -and $script:runtimeProcess.HasExited) {
            $exitCode = $script:runtimeProcess.ExitCode
            Write-TrayLog "Runtime process exited with code $exitCode."
            $script:runtimeProcess.Dispose()
            $script:runtimeProcess = $null
            $script:nextAutoStart = [DateTime]::Now.AddSeconds(5)
        }
        if ($null -eq $script:runtimeProcess -and -not $script:userStopped -and [DateTime]::Now -ge $script:nextAutoStart) {
            Start-RuntimeProcess
        }
        Update-TrayState
    }
    catch {
        Write-TrayLog "Monitor error: $($_.Exception.Message)"
    }
})

try {
    Write-TrayLog 'Tray controller starting.'
    Initialize-LauncherWatch
    Stop-StaleRuntimeProcesses
    Start-Sleep -Milliseconds 500
    Start-RuntimeProcess
    Update-TrayState
    $script:notifyIcon.BalloonTipTitle = 'Memoh Runtime'
    $script:notifyIcon.BalloonTipText = '后台连接已启动。右键托盘图标可停止、重启或退出。'
    $script:notifyIcon.ShowBalloonTip(3000)
    $script:timer.Start()
    [System.Windows.Forms.Application]::Run($script:context)
}
finally {
    $script:timer.Stop()
    if (-not $script:exiting) {
        try { Stop-RuntimeProcess -MarkUserStopped $true } catch {}
    }
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    $script:menu.Dispose()
    $script:context.Dispose()
    if ($null -ne $script:currentIcon) { $script:currentIcon.Dispose() }
    if ($script:runtimeJob -ne [IntPtr]::Zero) { [MemohTrayNative]::CloseHandle($script:runtimeJob) | Out-Null }
    Write-TrayLog 'Tray controller stopped.'
    $script:trayMutex.ReleaseMutex()
    $script:trayMutex.Dispose()
}

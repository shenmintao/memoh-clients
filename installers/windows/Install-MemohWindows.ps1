[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [string]$MachineName = $env:COMPUTERNAME,
    [string]$RuntimeVersion = '0.19.0-local-capabilities.1',
    [string]$PiAcpVersion = '0.0.33-local-mcp.1',
    [string]$PiVersion = '0.85.0',
    [string]$RuntimePackage = (Join-Path $PSScriptRoot '../../artifacts/runtime.tgz'),
    [string]$PiAcpPackage = (Join-Path $PSScriptRoot '../../artifacts/pi-acp.tgz')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require-Command([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' was not found."
    }
    return $command
}

$node = Require-Command 'node.exe'
$npm = Require-Command 'npm.cmd'
$pwsh = Require-Command 'pwsh.exe'

$nodeVersionText = (& $node.Source --version).Trim().TrimStart('v')
$nodeMajor = [int]($nodeVersionText.Split('.')[0])
if ($nodeMajor -lt 22) {
    throw "Node.js 22 or newer is required; found $nodeVersionText."
}

Write-Host "Installing tested Memoh/Pi packages..."
& $npm.Source install -g `
    "$RuntimePackage" `
    "$PiAcpPackage" `
    "@earendil-works/pi-coding-agent@$PiVersion"
if ($LASTEXITCODE -ne 0) {
    throw "npm global installation failed with exit code $LASTEXITCODE."
}

$runtimeCommand = Join-Path $env:APPDATA 'npm\memoh-runtime.cmd'
$piAcpCommand = Join-Path $env:APPDATA 'npm\pi-acp.cmd'
$piCommand = Join-Path $env:APPDATA 'npm\pi.cmd'
foreach ($path in @($runtimeCommand, $piAcpCommand, $piCommand)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Expected command was not installed: $path"
    }
}

$memohDir = Join-Path $HOME '.memoh'
New-Item -ItemType Directory -Path $memohDir -Force | Out-Null

Write-Host ''
Write-Host 'Create a NEW Computer credential in Memoh before continuing:' -ForegroundColor Yellow
Write-Host "  $Server -> 电脑 -> 连接其他电脑"
Write-Host 'Each machine must use its own key. Do not reuse another machine''s key.'
$runtimeKey = Read-Host 'Paste only the mrk_... Runtime Key' -AsSecureString
$runtimeKey | ConvertFrom-SecureString | Set-Content `
    -LiteralPath (Join-Path $memohDir 'runtime-key.dpapi') `
    -NoNewline

$Server = $Server.ToString().TrimEnd('/')
$serverLiteral = $Server.Replace("'", "''")
$startScript = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$memohDir = Join-Path $HOME '.memoh'
$keyFile = Join-Path $memohDir 'runtime-key.dpapi'
$logFile = Join-Path $memohDir 'runtime.log'
$runtimeCmd = Join-Path $env:APPDATA 'npm\memoh-runtime.cmd'

if (-not (Test-Path -LiteralPath $runtimeCmd)) {
    throw "memoh-runtime is not installed at $runtimeCmd"
}
if (-not (Test-Path -LiteralPath $keyFile)) {
    throw "Memoh runtime key is missing at $keyFile"
}

$mutexName = 'Local\MemohRuntime-' + $env:COMPUTERNAME + '-' + $env:USERNAME
$mutex = [Threading.Mutex]::new($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    exit 0
}

$secureKey = Get-Content -LiteralPath $keyFile -Raw | ConvertTo-SecureString
$keyPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try {
    $env:MEMOH_RUNTIME_SERVER = '__SERVER__'
    $env:MEMOH_RUNTIME_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPtr)
    "$(Get-Date -Format o) starting memoh-runtime" | Out-File -FilePath $logFile -Append -Encoding utf8
    & $runtimeCmd *>> $logFile
    exit $LASTEXITCODE
}
finally {
    $env:MEMOH_RUNTIME_KEY = $null
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPtr)
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
'@
$startScript = $startScript.Replace('__SERVER__', $serverLiteral)
$startPath = Join-Path $memohDir 'start-runtime.ps1'
$startScript | Set-Content -LiteralPath $startPath -Encoding utf8

$trayTemplate = Join-Path $PSScriptRoot 'MemohTray.ps1'
if (-not (Test-Path -LiteralPath $trayTemplate)) {
    throw "Tray controller template is missing: $trayTemplate"
}
$trayPath = Join-Path $memohDir 'MemohTray.ps1'
$trayLauncher = Join-Path $memohDir 'Launch-MemohTray.vbs'
$taskLauncher = Join-Path $memohDir 'Start-MemohRuntime.vbs'
Copy-Item -LiteralPath $trayTemplate -Destination $trayPath -Force

$trayCommand = '"' + $pwsh.Source + '" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $trayPath + '"'
$trayCommandLiteral = '"' + $trayCommand.Replace('"', '""') + '"'
@"
Option Explicit
Dim shell, command, exitCode
Set shell = CreateObject("WScript.Shell")
command = $trayCommandLiteral
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
"@ | Set-Content -LiteralPath $trayLauncher -Encoding unicode

[pscustomobject]@{
    name = $MachineName
    server = $Server
    installed_at = (Get-Date).ToString('o')
    runtime_version = $RuntimeVersion
    pi_acp_version = $PiAcpVersion
    pi_version = $PiVersion
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $memohDir 'runtime.json') -Encoding utf8

# Limit the directory to the current Windows identity. DPAPI also binds the
# encrypted key to this user profile, so copying the blob to another machine
# or account does not reveal the key.
$acl = Get-Acl $memohDir
$acl.SetAccessRuleProtection($true, $false)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $sid,
    'FullControl',
    'ContainerInherit,ObjectInherit',
    'None',
    'Allow'
)
$acl.SetAccessRule($rule)
Set-Acl $memohDir $acl

$taskName = 'Memoh Remote Runtime'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$taskCommand = '"' + "$env:SystemRoot\System32\schtasks.exe" + '" /Run /TN "' + $taskName + '"'
$taskCommandLiteral = '"' + $taskCommand.Replace('"', '""') + '"'
@"
Option Explicit
Dim shell, command
Set shell = CreateObject("WScript.Shell")
command = $taskCommandLiteral
shell.Run command, 0, True
"@ | Set-Content -LiteralPath $taskLauncher -Encoding unicode

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and $_.Name -eq 'pwsh.exe' -and
        $_.CommandLine -match '[\\/]MemohTray\.ps1'
    } |
    ForEach-Object {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $_.ProcessId /T /F *> $null
    }

$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\wscript.exe" `
    -Argument "//B //NoLogo `"$trayLauncher`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RestartCount 20 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal `
    -UserId $identity `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Memoh Remote Runtime background controller and tray icon' `
    -Force | Out-Null

$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath = Join-Path $programs 'Memoh Runtime.lnk'
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$shortcut.Arguments = "//B //NoLogo `"$taskLauncher`""
$shortcut.WorkingDirectory = $HOME
$shortcut.WindowStyle = 7
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
$shortcut.Description = 'Start Memoh Remote Runtime and tray controller'
$shortcut.Save()

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 5
$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
$task | Select-Object TaskName, State
$info | Select-Object LastRunTime, LastTaskResult
Write-Host "Runtime log: $memohDir\runtime.log"
Write-Host 'The Memoh M icon is available in the Windows notification area.'
Write-Host 'If you choose Exit, launch Memoh Runtime again from the Start menu.'
Write-Host 'Return to the Memoh Computer dialog and wait for Online.'
Write-Host 'Then run pi or pi-acp --terminal-login once if this machine has not been authenticated to a model provider.' -ForegroundColor Yellow

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$RemovePackages,
    [switch]$RemoveLocalConfig
)

$ErrorActionPreference = 'Stop'
$taskName = 'Memoh Remote Runtime'

Write-Host 'First revoke this Computer in Memoh: https://memoh.minq.icu -> 电脑 -> 断开连接' -ForegroundColor Yellow
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Remove local Memoh Remote Runtime')) {
    return
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Memoh Runtime.lnk') -Force -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and (
            ($_.Name -eq 'pwsh.exe' -and $_.CommandLine -match '[\\/](MemohTray|start-runtime)\.ps1') -or
            ($_.Name -eq 'cmd.exe' -and $_.CommandLine -match 'memoh-runtime\.cmd') -or
            ($_.Name -eq 'node.exe' -and $_.CommandLine -match '@memohai[\\/]runtime.*cli\.mjs')
        )
    } |
    ForEach-Object {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $_.ProcessId /T /F *> $null
    }

if ($RemovePackages) {
    & npm.cmd uninstall -g @memohai/runtime pi-acp
    if ($LASTEXITCODE -ne 0) {
        throw "npm uninstall failed with exit code $LASTEXITCODE"
    }
}

if ($RemoveLocalConfig) {
    Remove-Item -LiteralPath (Join-Path $HOME '.memoh') -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Local Memoh Runtime removed.'

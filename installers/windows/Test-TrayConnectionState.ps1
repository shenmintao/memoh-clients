$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeStatus.ps1')

# Extract only the status reader; do not launch WinForms or a real Runtime.
$trayPath = Join-Path $PSScriptRoot 'MemohTray.ps1'
$parseTokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($trayPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-RuntimeConnectionState'
}, $true)
if ($null -eq $functionAst) { throw 'Tray connection status function is missing' }
. ([scriptblock]::Create($functionAst.Extent.Text))
function Test-RuntimeRunning { return $script:testRunning }

$script:statusMonitor = New-MemohStatusMonitor 'https://example.invalid/api' 'unused-key' 'device-1'
$script:testRunning = $true
$script:userStopped = $false
$passed = 0
function Assert-State([string]$Expected, [string]$Case) {
    $actual = Get-RuntimeConnectionState
    if ($actual -ne $Expected) { throw "${Case}: expected $Expected, got $actual" }
    $script:passed++
}
try {
    Assert-State 'unknown' 'No server response yet'
    $online = '{"id":"device-1","online":true,"checked_at":"2026-09-11T01:00:00Z"}'
    Set-MemohStatusResponse $script:statusMonitor 200 $online
    Assert-State 'online' 'Server confirms connection'
    Set-MemohStatusResponse $script:statusMonitor 200 ($online.Replace('true', 'false'))
    Assert-State 'offline' 'Server confirms no connection'
    Set-MemohStatusResponse $script:statusMonitor 502 '<html>Bad Gateway</html>'
    Assert-State 'unknown' 'Unavailable server is not a confirmed offline state'
    Set-MemohStatusResponse $script:statusMonitor 401 '{}'
    Assert-State 'unauthorized' 'Revoked credential'
    Set-MemohStatusResponse $script:statusMonitor 404 '{}'
    Assert-State 'unsupported' 'Server does not implement status endpoint'
    foreach ($body in @('invalid JSON', '{"online":true}', $online.Replace('device-1', 'device-2'), $online.Replace('true', '"true"'))) {
        Set-MemohStatusResponse $script:statusMonitor 200 $body
        Assert-State 'unknown' 'Malformed or different-device response'
    }
    Set-MemohStatusResponse $script:statusMonitor 200 $online
    $script:statusMonitor.ReceivedAt = [DateTimeOffset]::UtcNow.AddSeconds(-31)
    Assert-State 'unknown' 'Expired confirmation is not treated as online'
    Reset-MemohStatusMonitor $script:statusMonitor
    Assert-State 'unknown' 'Restart clears the previous process status'

    $pending = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
    $script:statusMonitor.Pending = $pending.Task
    $script:statusMonitor.Request = [Net.Http.HttpRequestMessage]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Update-MemohStatusMonitor $script:statusMonitor
    if ($clock.Elapsed.TotalSeconds -gt 1) { throw 'Pending network request blocked the UI' }
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
    $response.Content = [Net.Http.StringContent]::new($online)
    $pending.SetResult($response)
    Update-MemohStatusMonitor $script:statusMonitor
    Assert-State 'online' 'Completed async HTTP response updates connection status'
    $script:statusMonitor.Pending = [Threading.Tasks.Task]::FromException[Net.Http.HttpResponseMessage]([TimeoutException]::new())
    $script:statusMonitor.Request = [Net.Http.HttpRequestMessage]::new()
    Update-MemohStatusMonitor $script:statusMonitor
    Assert-State 'unknown' 'Network timeout clears previous online confirmation'

    $script:testRunning = $false
    $script:userStopped = $true
    Assert-State 'stopped' 'Runtime stopped by user'

    $script:userStopped = $false
    Assert-State 'restarting' 'Runtime process exited unexpectedly'
    Write-Output "Tray connection status: $passed cases passed"
}
finally {
    Close-MemohStatusMonitor $script:statusMonitor
}

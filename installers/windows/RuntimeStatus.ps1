function New-MemohStatusMonitor([string]$Server, [string]$KeyFile, [string]$RuntimeId = '') {
    $uri = [uri]($Server.TrimEnd('/') + '/runtimes/status')
    if ($uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Invalid Runtime status server URL'
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    $client.MaxResponseContentBufferSize = 16384
    return [pscustomobject]@{
        Client = $client; Uri = $uri; KeyFile = $KeyFile; RuntimeId = $RuntimeId
        Pending = $null; Request = $null; State = 'unknown'
        CheckedAt = [DateTimeOffset]::MinValue; ReceivedAt = [DateTimeOffset]::MinValue
        NextPoll = [DateTimeOffset]::MinValue
    }
}

function Set-MemohStatusResponse($Monitor, [int]$StatusCode, [string]$Body) {
    $Monitor.State = 'unknown'
    if ($StatusCode -eq 401) { $Monitor.State = 'unauthorized'; return }
    if ($StatusCode -eq 404) { $Monitor.State = 'unsupported'; return }
    if ($StatusCode -ne 200) { return }
    try {
        $status = $Body | ConvertFrom-Json
        if ($status.online -isnot [bool] -or [string]::IsNullOrWhiteSpace($status.id)) { return }
        if ($Monitor.RuntimeId -and $status.id -ne $Monitor.RuntimeId) { return }
        $Monitor.CheckedAt = [DateTimeOffset]::Parse($status.checked_at)
        $Monitor.ReceivedAt = [DateTimeOffset]::UtcNow
        $Monitor.State = if ($status.online) { 'online' } else { 'offline' }
    }
    catch { $Monitor.State = 'unknown' }
}

function Reset-MemohStatusMonitor($Monitor) {
    $Monitor.Client.CancelPendingRequests()
    if ($null -ne $Monitor.Request) { $Monitor.Request.Dispose() }
    $Monitor.Pending = $null
    $Monitor.Request = $null
    $Monitor.State = 'unknown'
    $Monitor.CheckedAt = [DateTimeOffset]::MinValue
    $Monitor.ReceivedAt = [DateTimeOffset]::MinValue
    $Monitor.NextPoll = [DateTimeOffset]::MinValue
}

function Update-MemohStatusMonitor($Monitor) {
    if ($null -ne $Monitor.Pending) {
        if (-not $Monitor.Pending.IsCompleted) { return }
        $response = $null
        try {
            $response = $Monitor.Pending.GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Set-MemohStatusResponse $Monitor ([int]$response.StatusCode) $body
        }
        catch { $Monitor.State = 'unknown' }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            $Monitor.Request.Dispose()
            $Monitor.Request = $null
            $Monitor.Pending = $null
            $Monitor.NextPoll = [DateTimeOffset]::UtcNow.AddSeconds(10)
        }
    }
    if ([DateTimeOffset]::UtcNow -lt $Monitor.NextPoll) { return }
    $keyPtr = [IntPtr]::Zero
    try {
        $secureKey = Get-Content -LiteralPath $Monitor.KeyFile -Raw | ConvertTo-SecureString
        $keyPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $Monitor.Request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Monitor.Uri)
        $Monitor.Request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
            'Bearer', [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPtr))
        $Monitor.Request.Headers.Add('Cache-Control', 'no-cache')
        $Monitor.Pending = $Monitor.Client.SendAsync($Monitor.Request)
    }
    catch {
        $Monitor.State = 'unknown'
        if ($null -ne $Monitor.Request) { $Monitor.Request.Dispose() }
        $Monitor.Request = $null
        $Monitor.Pending = $null
        $Monitor.NextPoll = [DateTimeOffset]::UtcNow.AddSeconds(10)
    }
    finally {
        if ($keyPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPtr) }
    }
}

function Get-MemohServerState($Monitor) {
    if ($Monitor.State -in @('online', 'offline') -and
        ([DateTimeOffset]::UtcNow - $Monitor.ReceivedAt).TotalSeconds -gt 30) {
        return 'unknown'
    }
    return $Monitor.State
}

function Close-MemohStatusMonitor($Monitor) {
    Reset-MemohStatusMonitor $Monitor
    $Monitor.Client.Dispose()
}

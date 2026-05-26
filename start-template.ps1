#requires -Version 7.0
# start.ps1 — NoLlama launcher
# Starts the server, waits for models to load, then opens the browser.
# Args are set by install.ps1 in the generated start.ps1

param(
    [string]$ServerArgs = ""
)

function Open-Url($url) {
    # Best-effort cross-platform browser open; tolerate headless / no handler.
    try { Start-Process $url } catch { Write-Host "  Open $url in your browser" -ForegroundColor DarkGray }
}

function Test-PortFree($port) {
    # Bind to Any (0.0.0.0) to match what nollama.py binds — Flask's
    # host="0.0.0.0". Loopback-only here is a false-positive trap on
    # Windows: a process bound to 0.0.0.0 doesn't block a subsequent
    # 127.0.0.1 bind, so the Loopback test would say "free" while the
    # real bind later fails.
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
        $l.Start(); $l.Stop()
        return $true
    } catch { return $false }
}

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Pick an available port in 8000..8009. Hard fail if all are busy — bumping
# the default by ten is plenty for the usual case (orphan NoLlama, another
# local dev server); ten in a row means investigate, don't keep climbing.
$BasePort = 8000
$Port = $null
for ($p = $BasePort; $p -lt ($BasePort + 10); $p++) {
    if (Test-PortFree $p) { $Port = $p; break }
}
if (-not $Port) {
    Write-Host "  ERROR: ports $BasePort..$($BasePort + 9) all in use." -ForegroundColor Red
    Write-Host "  Free one (likely an orphan server) and retry." -ForegroundColor Red
    exit 1
}
if ($Port -ne $BasePort) {
    Write-Host "  Port $BasePort is in use; using $Port instead." -ForegroundColor Yellow
}
$Url = "http://localhost:$Port"

# Activate venv (Scripts on Windows, bin on POSIX)
$VenvBinDir = if ($IsWindows) { "Scripts" } else { "bin" }
& (Join-Path $ScriptDir "venv" $VenvBinDir "Activate.ps1")

# Start server in background — pass the port the launcher picked.
$AllArgs = @((Join-Path $ScriptDir "nollama.py"), "--port", "$Port")
if ($ServerArgs) {
    $AllArgs += $ServerArgs.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
}
$Server = Start-Process -FilePath python -ArgumentList $AllArgs `
    -NoNewWindow -PassThru

Write-Host ""
Write-Host "  NoLlama starting..." -ForegroundColor Cyan
Write-Host ""

# Poll /health until ready (or error/timeout)
$Spinner = @("|", "/", "-", "\")
$MaxWait = 120
$Elapsed = 0
$LastStatus = ""
$SpinIdx = 0

while ($Elapsed -lt $MaxWait) {
    Start-Sleep -Milliseconds 500
    $Elapsed += 0.5

    if ($Server.HasExited) {
        Write-Host ""
        Write-Host "  ERROR: Server process exited unexpectedly." -ForegroundColor Red
        exit 1
    }

    try {
        $resp = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec 2 -ErrorAction Stop
        $Status = $resp.status

        if ($Status -ne $LastStatus) {
            $LastStatus = $Status
            $DeviceInfo = ""
            if ($resp.devices) {
                $parts = @()
                $resp.devices.PSObject.Properties | ForEach-Object {
                    $devName = $_.Name.ToUpper()
                    $st = $_.Value.status
                    $modelName = $_.Value.model
                    if ($st -and $st -ne "not_configured") {
                        $parts += "${devName}: ${modelName} (${st})"
                    }
                }
                $DeviceInfo = $parts -join "  |  "
            }
            Write-Host ""
            Write-Host "  $DeviceInfo" -ForegroundColor DarkGray
        }

        if ($Status -eq "ready") {
            Write-Host ""
            Write-Host "  Ready! Opening browser..." -ForegroundColor Green
            Write-Host ""
            Open-Url $Url
            break
        }

        $spin = $Spinner[$SpinIdx % 4]
        $SpinIdx++
        $bar = "#" * [math]::Min([int]($Elapsed / 2), 40)
        Write-Host "`r  [$spin] Loading models... $bar" -NoNewline
    } catch {
        $spin = $Spinner[$SpinIdx % 4]
        $SpinIdx++
        Write-Host "`r  [$spin] Waiting for server..." -NoNewline
    }
}

if ($Elapsed -ge $MaxWait) {
    Write-Host ""
    Write-Host "  WARNING: Server did not become ready within ${MaxWait}s" -ForegroundColor Yellow
    Write-Host "  Opening browser anyway..."
    Open-Url $Url
}

Write-Host "  Server running at $Url"
Write-Host "  Press Ctrl+C to stop."
Write-Host ""

try {
    $Server.WaitForExit()
} catch {}

if (-not $Server.HasExited) {
    $Server.Kill()
}

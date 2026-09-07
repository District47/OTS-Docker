<#
.SYNOPSIS
    One-command setup for OpenTAKServer on Windows with Docker Compose.

.DESCRIPTION
    Checks that Docker is installed and running, generates a .env file with
    secure random passwords, detects this machine's LAN address, then builds
    and starts the whole stack.

    Safe to re-run: an existing .env is left alone unless you pass -Force.

.PARAMETER ServerAddress
    The address TAK clients will use to reach this server. Defaults to the
    detected LAN IP. Use a public domain name if you intend to use -TlsMode
    letsencrypt.

.PARAMETER TlsMode
    'self-signed' (default) or 'letsencrypt'.

.PARAMETER Email
    Contact address for Let's Encrypt. Required with -TlsMode letsencrypt.

.PARAMETER Force
    Regenerate .env even if one already exists. This creates NEW passwords,
    which will not match an existing database - see README before using it.

.PARAMETER SkipStart
    Write configuration but do not build or start containers.

.EXAMPLE
    .\setup.ps1

.EXAMPLE
    .\setup.ps1 -ServerAddress tak.example.com -TlsMode letsencrypt -Email me@example.com
#>
[CmdletBinding()]
param(
    [string]$ServerAddress,
    [ValidateSet('self-signed', 'letsencrypt')]
    [string]$TlsMode = 'self-signed',
    [string]$Email,
    [switch]$Force,
    [switch]$SkipStart
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    [x]  $m" -ForegroundColor Red }

function Write-TextFileLf {
    <#  Writes UTF-8 without a BOM and with LF endings.
        PowerShell 5.1's Out-File would add a BOM, which Docker Compose
        reads as part of the first variable name. #>
    param([string]$Path, [string]$Content)
    $normalised = $Content -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalised, $utf8NoBom)
}

function New-RandomPassword {
    param([int]$Length = 28)
    # Letters and digits only: this password is embedded in a database URL,
    # where punctuation would need escaping.
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object 'System.Byte[]' $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

Write-Host ""
Write-Host "  OpenTAKServer - Docker setup for Windows" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------------
Write-Step "Checking Docker"

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) {
    Write-Err "Docker was not found."
    Write-Host ""
    Write-Host "    Install Docker Desktop, then run this script again:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "        winget install -e --id Docker.DockerDesktop" -ForegroundColor White
    Write-Host ""
    Write-Host "    Or download it from https://www.docker.com/products/docker-desktop/"
    Write-Host "    After installing, start Docker Desktop once and let it finish setting up."
    exit 1
}
Write-Ok "docker found at $($docker.Source)"

docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker is installed but not running."
    Write-Host ""
    Write-Host "    Start Docker Desktop and wait until it says 'Engine running', then re-run this script."
    exit 1
}
Write-Ok "Docker engine is running"

docker compose version 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "'docker compose' is unavailable. Docker Desktop 4.x or newer is required."
    exit 1
}
Write-Ok "docker compose is available"

# ---------------------------------------------------------------------------
# 2. Environment sanity checks
# ---------------------------------------------------------------------------
Write-Step "Checking this machine"

if ($PSScriptRoot -match 'OneDrive|Dropbox|Google Drive') {
    Write-Warn "This folder is inside a cloud-synced directory."
    Write-Warn "That is fine - all server data lives in Docker volumes, not here -"
    Write-Warn "but syncing will be quieter if you move this folder to e.g. C:\OTS-Docker."
}

# Ports we are about to bind. A conflict here is the most common failure.
$portsToCheck = @{
    80   = 'Web UI (HTTP)'
    443  = 'Web UI (HTTPS)'
    8080 = 'Marti API (HTTP)'
    8443 = 'Marti API (HTTPS)'
    8446 = 'Certificate enrollment'
    8883 = 'MQTT over TLS'
    8088 = 'CoT streaming (TCP)'
    8089 = 'CoT streaming (SSL)'
}

$conflicts = @()
foreach ($port in $portsToCheck.Keys) {
    $inUse = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        $owner = 'unknown'
        try {
            $proc = Get-Process -Id ($inUse | Select-Object -First 1).OwningProcess -ErrorAction Stop
            $owner = $proc.ProcessName
        } catch { }
        $conflicts += "port $port ($($portsToCheck[$port])) is already used by '$owner'"
    }
}

if ($conflicts.Count -gt 0) {
    Write-Warn "Some ports are already in use:"
    foreach ($c in $conflicts) { Write-Warn "  $c" }
    Write-Warn "Change the matching *_PORT value in .env, or stop the other program."
} else {
    Write-Ok "No port conflicts detected"
}

# ---------------------------------------------------------------------------
# 3. Server address
# ---------------------------------------------------------------------------
Write-Step "Determining the server address"

if (-not $ServerAddress) {
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
               Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
               Select-Object -First 1
        if ($cfg -and $cfg.IPv4Address) {
            $ServerAddress = $cfg.IPv4Address.IPAddress
        }
    } catch { }
}

if (-not $ServerAddress) {
    $ServerAddress = '_'
    Write-Warn "Could not detect a LAN address; using '_' (matches any hostname)."
    Write-Warn "TAK clients will still work - just point them at this machine's IP."
} else {
    Write-Ok "Server address: $ServerAddress"
}

if ($TlsMode -eq 'letsencrypt') {
    if (-not $Email) {
        Write-Err "-Email is required with -TlsMode letsencrypt."
        exit 1
    }
    if ($ServerAddress -match '^\d+\.\d+\.\d+\.\d+$' -or $ServerAddress -eq '_') {
        Write-Err "Let's Encrypt needs a real public domain name in -ServerAddress, not an IP."
        exit 1
    }
    Write-Ok "Let's Encrypt will be configured for $ServerAddress"
}

# ---------------------------------------------------------------------------
# 4. .env
# ---------------------------------------------------------------------------
Write-Step "Writing configuration"

$envPath = Join-Path $PSScriptRoot '.env'
$examplePath = Join-Path $PSScriptRoot '.env.example'

if ((Test-Path $envPath) -and -not $Force) {
    Write-Ok ".env already exists - leaving it untouched"
    Write-Host "    (re-run with -Force to regenerate it, but read the README first:" -ForegroundColor DarkGray
    Write-Host "     new passwords will not match an existing database)" -ForegroundColor DarkGray
} else {
    if (-not (Test-Path $examplePath)) {
        Write-Err ".env.example is missing - is this a complete checkout of the repo?"
        exit 1
    }

    if (Test-Path $envPath) {
        $backup = "$envPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $envPath $backup
        Write-Warn "Existing .env backed up to $(Split-Path $backup -Leaf)"
    }

    $content = Get-Content $examplePath -Raw

    $content = $content -replace '(?m)^POSTGRES_PASSWORD=.*$', "POSTGRES_PASSWORD=$(New-RandomPassword)"
    $content = $content -replace '(?m)^RABBITMQ_PASSWORD=.*$', "RABBITMQ_PASSWORD=$(New-RandomPassword)"
    $content = $content -replace '(?m)^OTS_FQDN=.*$',          "OTS_FQDN=$ServerAddress"
    $content = $content -replace '(?m)^OTS_TLS_MODE=.*$',      "OTS_TLS_MODE=$TlsMode"
    if ($Email) {
        $content = $content -replace '(?m)^LETSENCRYPT_EMAIL=.*$', "LETSENCRYPT_EMAIL=$Email"
    }

    Write-TextFileLf -Path $envPath -Content $content
    Write-Ok "Generated .env with new random passwords"
}

if ($SkipStart) {
    Write-Host ""
    Write-Host "Configuration written. Start the server with:  .\ots.ps1 start" -ForegroundColor White
    exit 0
}

# ---------------------------------------------------------------------------
# 5. Build and start
# ---------------------------------------------------------------------------
Write-Step "Downloading images (this takes a few minutes the first time)"
# --ignore-buildable skips the nginx image, which is built locally rather than
# pulled. A failure here is not fatal: 'up' pulls anything still missing.
docker compose pull --quiet --ignore-buildable
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Pre-downloading images did not complete; continuing anyway."
} else {
    Write-Ok "Images downloaded"
}

Write-Step "Building the web server image"
docker compose build
if ($LASTEXITCODE -ne 0) {
    Write-Err "Build failed. See the output above."
    exit 1
}
Write-Ok "Build complete"

Write-Step "Starting OpenTAKServer"
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to start. Run '.\ots.ps1 logs' to see what happened."
    exit 1
}

# The first start runs database migrations and creates the CA, which is slow.
Write-Host "    Waiting for the server to become healthy (up to 5 minutes on first run)..."
$deadline = (Get-Date).AddMinutes(5)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    $state = (docker inspect -f '{{.State.Health.Status}}' opentakserver 2>$null)
    if ($state -eq 'healthy') { $healthy = $true; break }
    if ($state -eq 'unhealthy') { break }
    Start-Sleep -Seconds 5
}

Write-Host ""
if ($healthy) {
    Write-Ok "OpenTAKServer is running"
} else {
    Write-Warn "The server did not report healthy in time."
    Write-Warn "It may still be finishing its first-run setup. Check with:  .\ots.ps1 status"
    Write-Warn "If it stays unhealthy, look at:  .\ots.ps1 logs ots"
}

# ---------------------------------------------------------------------------
# 6. What to do next
# ---------------------------------------------------------------------------
$displayHost = $ServerAddress
if ($displayHost -eq '_') { $displayHost = 'localhost' }

Write-Host ""
Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Web UI      https://$displayHost" -ForegroundColor White
Write-Host "  Username    administrator" -ForegroundColor White
Write-Host "  Password    password" -ForegroundColor White
Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  CHANGE THAT PASSWORD NOW - it is the same on every install." -ForegroundColor Yellow
Write-Host "  In the web UI: click your username, then Change Password." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Your browser will warn about the certificate. That is expected -"
Write-Host "  OpenTAKServer signs it with its own private CA. Click through it."
Write-Host ""
Write-Host "  Connect a TAK client:   see docs\CLIENTS.md"
Write-Host "  Everyday commands:      .\ots.ps1 help"
Write-Host ""

if ($TlsMode -eq 'letsencrypt') {
    Write-Host "  Next: request your certificate with" -ForegroundColor Yellow
    Write-Host "      .\ots.ps1 cert-request" -ForegroundColor White
    Write-Host ""
}

# ============================================================================
#  OpenTAKServer for Windows - one-line installer
#
#  Run this in PowerShell:
#
#      irm https://raw.githubusercontent.com/District47/OTS-Docker/main/install.ps1 | iex
#
#  It downloads the latest release, unblocks it, puts a shortcut on your
#  Desktop and opens the control panel. It does not need administrator rights
#  and does not install anything system-wide - the whole thing lives in one
#  folder you can delete.
#
#  Docker itself is installed later, from a button in the control panel.
# ============================================================================
param(
    [string]$InstallPath = $(if ($env:OTS_INSTALL_PATH) { $env:OTS_INSTALL_PATH } else { 'C:\OTS-Docker' }),
    [string]$Repo        = 'District47/OTS-Docker',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say  { param($m) Write-Host "    $m" }
function Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Fail { param($m) Write-Host "    [x]  $m" -ForegroundColor Red }

Write-Host ""
Write-Host "  OpenTAKServer for Windows" -ForegroundColor White
Write-Host "  -------------------------" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. Sanity
# ---------------------------------------------------------------------------
Step "Checking this machine"

if (-not [Environment]::Is64BitOperatingSystem) {
    Fail "64-bit Windows is required."
    return
}
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 19044) {
    Fail "Windows 10 21H2 (build 19044) or newer is required. This is build $build."
    return
}
Ok "Windows build $build"

# A cloud-synced folder is a poor home for a server that writes constantly.
if ($InstallPath -match 'OneDrive|Dropbox|Google Drive') {
    Warn "$InstallPath is inside a cloud-synced folder."
    Warn "C:\OTS-Docker is a better choice - sync tools and live server files"
    Warn "do not mix well."
}

# ---------------------------------------------------------------------------
# 2. Download
# ---------------------------------------------------------------------------
Step "Finding the latest release"

$zipUrl = $null
try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                             -Headers @{ 'User-Agent' = 'OTS-Docker-Installer' }
    $asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if ($asset) {
        $zipUrl = $asset.browser_download_url
        Ok "Release $($rel.tag_name)"
    }
} catch {
    Warn "No published release found - falling back to the current main branch."
}
if (-not $zipUrl) {
    $zipUrl = "https://github.com/$Repo/archive/refs/heads/main.zip"
}

$tmpZip = Join-Path $env:TEMP "ots-docker-$(Get-Random).zip"
$tmpDir = Join-Path $env:TEMP "ots-docker-$(Get-Random)"

Step "Downloading"
try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing
} catch {
    Fail "Download failed: $($_.Exception.Message)"
    Fail "Check your internet connection, or download the ZIP by hand from:"
    Say  "https://github.com/$Repo"
    return
}
Ok "Downloaded $([math]::Round((Get-Item $tmpZip).Length / 1MB, 1)) MB"

# ---------------------------------------------------------------------------
# 3. Extract
# ---------------------------------------------------------------------------
Step "Installing to $InstallPath"

Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

# A GitHub source zip nests everything one level deep; a release asset may not.
$root = $tmpDir
$inner = Get-ChildItem $tmpDir -Directory
if ($inner.Count -eq 1 -and -not (Test-Path (Join-Path $tmpDir 'docker-compose.yml'))) {
    $root = $inner[0].FullName
}

if (-not (Test-Path (Join-Path $root 'docker-compose.yml'))) {
    Fail "The download does not look like OTS-Docker - docker-compose.yml is missing."
    return
}

# Preserve an existing .env: it holds the database password, and losing it
# makes the existing data unreadable.
$existingEnv = Join-Path $InstallPath '.env'
$savedEnv = $null
if (Test-Path $existingEnv) {
    $savedEnv = Get-Content $existingEnv -Raw
    Warn "Existing installation found - your .env will be kept."
}

New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
Copy-Item -Path (Join-Path $root '*') -Destination $InstallPath -Recurse -Force

if ($savedEnv) {
    [System.IO.File]::WriteAllText($existingEnv, $savedEnv, (New-Object System.Text.UTF8Encoding($false)))
    Ok "Kept your existing .env"
}
Ok "Files installed"

# Windows tags anything downloaded from the internet, which makes PowerShell
# and SmartScreen treat the scripts as untrusted.
Get-ChildItem $InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Ok "Unblocked downloaded files"

Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 4. Desktop shortcut
# ---------------------------------------------------------------------------
Step "Adding a Desktop shortcut"
try {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OpenTAKServer Manager.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath       = Join-Path $InstallPath 'OTS Manager.cmd'
    $s.WorkingDirectory = $InstallPath
    $s.Description      = 'OpenTAKServer control panel'
    $s.IconLocation     = "$env:SystemRoot\System32\shell32.dll,15"
    $s.Save()
    Ok "Shortcut created"
} catch {
    Warn "Could not create the shortcut - open 'OTS Manager.cmd' in $InstallPath instead."
}

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Installed to $InstallPath" -ForegroundColor White
Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Next: the control panel opens in a moment. Work down the"
Write-Host "  numbered buttons on the left:"
Write-Host ""
Write-Host "     0. Check This PC          can this machine run Docker"
Write-Host "     1. Install Docker Desktop"
Write-Host "     2. Start Docker Desktop"
Write-Host "     3. Build and Install Server"
Write-Host ""
Write-Host "  Nothing else has been installed on your system yet." -ForegroundColor DarkGray
Write-Host ""

if (-not $NoLaunch) {
    Start-Process -FilePath (Join-Path $InstallPath 'OTS Manager.cmd') -WorkingDirectory $InstallPath
}

<#
.SYNOPSIS
    Everyday management commands for the OpenTAKServer Docker stack.

.DESCRIPTION
    Run  .\ots.ps1 help  for the list of commands.

.EXAMPLE
    .\ots.ps1 start
.EXAMPLE
    .\ots.ps1 logs ots
.EXAMPLE
    .\ots.ps1 backup
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$ProjectName = 'opentakserver'
$BackupDir   = Join-Path $PSScriptRoot 'backups'

# Set by the GUI wrapper, which asks for confirmation in its own dialog before
# invoking a destructive command. Never set this in a plain shell.
$AssumeYes = ($env:OTS_ASSUME_YES -eq '1')

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    [x]  $m" -ForegroundColor Red }

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err "Docker is not installed. Run .\setup.ps1 for instructions."
        exit 1
    }
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker is not running. Start Docker Desktop and try again."
        exit 1
    }
}

function Assert-Env {
    if (-not (Test-Path (Join-Path $PSScriptRoot '.env'))) {
        Write-Err "No .env file found. Run .\setup.ps1 first."
        exit 1
    }
}

function Get-EnvValue {
    param([string]$Key, [string]$Default = '')
    $envFile = Join-Path $PSScriptRoot '.env'
    if (-not (Test-Path $envFile)) { return $Default }
    foreach ($line in Get-Content $envFile) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") {
            return $Matches[1].Trim()
        }
    }
    return $Default
}

function Invoke-Native {
    <#  Runs a native command with ErrorActionPreference relaxed.

        Docker writes ordinary progress ("Image x Pulling") to stderr. If stderr
        is redirected - by the GUI, or by a plain 'ots.ps1 start > log.txt 2>&1' -
        PowerShell 5.1 turns each of those lines into a NativeCommandError, which
        under 'Stop' aborts the script even though docker exited 0.

        Success is judged by $LASTEXITCODE at the call site, as it should be. #>
    param([scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $prev }
}

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    Invoke-Native { & docker compose @ComposeArgs }
}

function Get-ActiveProfileArgs {
    <#  Once the server has been made internet-facing, the dynamic DNS and
        certbot containers belong to the "public" profile. Without this, a plain
        'start' would silently leave them stopped - the hostname would drift off
        your IP and the certificate would eventually expire. #>
    if ((Get-EnvValue 'OTS_TLS_MODE') -eq 'letsencrypt' -or (Get-EnvValue 'DUCKDNS_SUBDOMAIN')) {
        return @('--profile', 'public')
    }
    return @()
}

function Invoke-Wsl {
    <#  wsl.exe writes UTF-16LE. Without switching the console encoding,
        PowerShell 5.1 reads its output as interleaved null bytes. #>
    param([string[]]$WslArgs)
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        Invoke-Native { & wsl.exe @WslArgs }
    } finally { [Console]::OutputEncoding = $prev }
}

function Test-Virtualization {
    <#  Returns @{ Ok; Detail }.

        Win32_Processor.VirtualizationFirmwareEnabled goes FALSE once a
        hypervisor is already running, so on a perfectly healthy machine with
        WSL 2 up it reports false. HypervisorPresent is therefore checked
        first: if something is already virtualising, the firmware setting is
        self-evidently on. #>
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.HypervisorPresent) {
            return @{ Ok = $true; Detail = 'a hypervisor is running' }
        }
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu.VirtualizationFirmwareEnabled) {
            return @{ Ok = $true; Detail = 'enabled in firmware' }
        }
        return @{ Ok = $false; Detail = 'not enabled in firmware (BIOS/UEFI)' }
    } catch {
        return @{ Ok = $true; Detail = 'could not be determined' }
    }
}

function Get-WslInfo {
    <#  Returns @{ Installed; Version; DefaultVersion; Detail } #>
    $info = @{ Installed = $false; Version = $null; DefaultVersion = $null; Detail = '' }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        $info.Detail = 'wsl.exe not found'
        return $info
    }

    $verOut = Invoke-Wsl @('--version')
    if ($LASTEXITCODE -eq 0 -and $verOut) {
        $info.Installed = $true
        $line = ($verOut | Where-Object { $_ -match 'WSL version:\s*(.+)$' } | Select-Object -First 1)
        if ($line -match 'WSL version:\s*(.+)$') { $info.Version = $Matches[1].Trim() }
    }

    $statusOut = Invoke-Wsl @('--status')
    if ($LASTEXITCODE -eq 0 -and $statusOut) {
        $info.Installed = $true
        $dv = ($statusOut | Where-Object { $_ -match 'Default Version:\s*(\d+)' } | Select-Object -First 1)
        if ($dv -match 'Default Version:\s*(\d+)') { $info.DefaultVersion = $Matches[1] }
    }

    if (-not $info.Installed) { $info.Detail = 'WSL is present but not usable - the feature is probably not enabled' }
    return $info
}

function Set-EnvValue {
    <#  Rewrites one KEY=value line in .env, preserving LF endings and writing
        UTF-8 without a BOM - Docker Compose reads a BOM as part of the first
        variable name. #>
    param([string]$Key, [string]$Value)
    $envFile = Join-Path $PSScriptRoot '.env'
    $content = Get-Content $envFile -Raw
    $pattern = '(?m)^' + [regex]::Escape($Key) + '=.*$'
    if ($content -match $pattern) {
        $content = [regex]::Replace($content, $pattern, "$Key=$Value")
    } else {
        $content = $content.TrimEnd("`r", "`n") + "`n$Key=$Value`n"
    }
    $content = $content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($envFile, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-IpInSubnet {
    <#  True if an IPv4 address falls inside a CIDR range, e.g.
        Test-IpInSubnet '172.28.4.9' '172.28.0.0/16' #>
    param([string]$Address, [string]$Cidr)
    try {
        $parts = $Cidr.Split('/')
        if ($parts.Count -ne 2) { return $false }
        $netBytes = ([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
        $ipBytes  = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
        if ($netBytes.Length -ne 4 -or $ipBytes.Length -ne 4) { return $false }
        $bits = [int]$parts[1]
        if ($bits -lt 0 -or $bits -gt 32) { return $false }

        # Compared one octet at a time. Building a 32-bit mask instead would
        # mean writing 0xFFFFFFFF, which PowerShell 5.1 parses as int -1.
        for ($i = 0; $i -lt 4; $i++) {
            $take = $bits - ($i * 8)
            if ($take -le 0) { break }
            if ($take -gt 8) { $take = 8 }
            $mask = [byte](((0xFF -shl (8 - $take)) -band 0xFF))
            if (($ipBytes[$i] -band $mask) -ne ($netBytes[$i] -band $mask)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-LanAddress {
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
               Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
               Select-Object -First 1
        if ($cfg -and $cfg.IPv4Address) { return $cfg.IPv4Address.IPAddress }
    } catch { }
    return $null
}

function ConvertTo-PlainText {
    param($Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-PublicIp {
    <#  Asks a public "what is my IP" service. This tells that service your IP -
        which it would see from any web request anyway - and nothing else. #>
    foreach ($url in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $ip = (& curl.exe -s --max-time 8 $url) -replace '\s', ''
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch { }
    }
    return $null
}

function Invoke-OtsApiJson {
    <#  POSTs JSON to the local API through nginx. The body goes via a temp file
        because PowerShell mangles embedded quotes when passing to native exes. #>
    param([string]$Path, [hashtable]$Body, [string[]]$ExtraHeaders = @(), [string]$CookieJar)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        ($Body | ConvertTo-Json -Compress) | Out-File -FilePath $tmp -Encoding ascii -NoNewline
        $curlArgs = @('-sk', '-X', 'POST', "https://localhost$Path",
                      '-H', 'Content-Type: application/json',
                      '-H', 'Accept: application/json',
                      '--data-binary', "@$tmp")
        foreach ($h in $ExtraHeaders) { $curlArgs += @('-H', $h) }
        if ($CookieJar) { $curlArgs += @('-c', $CookieJar, '-b', $CookieJar) }
        $raw = & curl.exe @curlArgs
        if (-not $raw) { return $null }
        try { return ($raw | ConvertFrom-Json) } catch { return $null }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Test-AdminPassword {
    <#  Returns $true if the given password logs the administrator in. #>
    param([string]$Password)
    $r = Invoke-OtsApiJson -Path '/api/login?include_auth_token' `
                           -Body @{ username = 'administrator'; password = $Password }
    return ($null -ne $r -and $r.meta.code -eq 200)
}

# ---------------------------------------------------------------------------
switch ($Command.ToLower()) {

    # -----------------------------------------------------------------------
    'help' {
        Write-Host ""
        Write-Host "  OpenTAKServer - management commands" -ForegroundColor White
        Write-Host "  -----------------------------------" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Running the server" -ForegroundColor Cyan
        Write-Host "    start              Start everything"
        Write-Host "    stop               Stop everything (data is kept)"
        Write-Host "    restart            Restart everything"
        Write-Host "    status             Show what is running and healthy"
        Write-Host "    logs [service]     Follow logs. e.g. logs ots"
        Write-Host "    set-address [ip]   Update the server address after changing network"
        Write-Host "                       (no argument = detect it automatically)"
        Write-Host ""
        Write-Host "  Maintenance" -ForegroundColor Cyan
        Write-Host "    update             Pull newer images and restart"
        Write-Host "    backup             Back up the database and server data"
        Write-Host "    restore <file>     Restore from a backup folder"
        Write-Host "    config             Edit config.yml in Notepad, then restart"
        Write-Host "    shell [service]    Open a shell inside a container"
        Write-Host ""
        Write-Host "  Internet access" -ForegroundColor Cyan
        Write-Host "    go-public          Configure dynamic DNS + TLS for internet access"
        Write-Host "    check-internet     Verify DNS and listeners before requesting a cert"
        Write-Host "    cert-request       Issue/renew the Let's Encrypt certificate"
        Write-Host ""
        Write-Host "  Security and certificates" -ForegroundColor Cyan
        Write-Host "    set-admin-password Change the administrator password"
        Write-Host "    tls-only [on|all|off]  Choose which unencrypted ports stay open"
        Write-Host "    ca-export          Save the CA certificate for TAK clients"
        Write-Host "    server-cert        Reissue the server certificate"
        Write-Host ""
        Write-Host "  Troubleshooting" -ForegroundColor Cyan
        Write-Host "    preflight          Check this PC can run Docker (virtualization, WSL)"
        Write-Host "    doctor             Check for common problems"
        Write-Host "    reset              DELETE ALL DATA and start over"
        Write-Host ""
    }

    # -----------------------------------------------------------------------
    'preflight' {
        # Deliberately does NOT require .env or a running Docker - this is what
        # you run on a bare machine, before anything is installed.
        Write-Step "Checking prerequisites"
        $blocking = 0
        $warnings = 0

        # ---- Windows -----------------------------------------------------
        $os = Get-CimInstance Win32_OperatingSystem
        $build = [int]$os.BuildNumber
        if ([Environment]::Is64BitOperatingSystem) {
            Write-Ok "$($os.Caption) (64-bit), build $build"
        } else {
            Write-Err "32-bit Windows is not supported by Docker Desktop."
            $blocking++
        }
        if ($build -lt 19044) {
            Write-Err "Windows build $build is too old. Docker Desktop needs Windows 10 21H2 (build 19044) or newer."
            $blocking++
        }

        # ---- memory ------------------------------------------------------
        $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        if ($ramGb -lt 6) {
            Write-Warn "$ramGb GB of RAM. 8 GB or more is recommended; the stack needs about 4 GB free."
            $warnings++
        } else {
            Write-Ok "$ramGb GB of RAM"
        }

        # ---- disk --------------------------------------------------------
        try {
            $freeGb = [math]::Round((Get-PSDrive -Name ($PSScriptRoot.Substring(0,1)) -ErrorAction Stop).Free / 1GB, 1)
            if ($freeGb -lt 10) {
                Write-Warn "$freeGb GB free on this drive. The images need roughly 6 GB."
                $warnings++
            } else {
                Write-Ok "$freeGb GB free disk space"
            }
        } catch { }

        # ---- virtualization ----------------------------------------------
        $virt = Test-Virtualization
        if ($virt.Ok) {
            Write-Ok "Hardware virtualization: $($virt.Detail)"
        } else {
            Write-Err "Hardware virtualization is $($virt.Detail)."
            Write-Host "      Docker cannot run without it, and no software can turn it on."
            Write-Host "      Reboot into your BIOS/UEFI setup and enable the option called"
            Write-Host "      'Intel VT-x' / 'AMD-V' / 'SVM Mode' / 'Virtualization Technology'."
            $blocking++
        }

        # ---- WSL ---------------------------------------------------------
        $wsl = Get-WslInfo
        if ($wsl.Installed) {
            $v = if ($wsl.Version) { "version $($wsl.Version)" } else { 'installed' }
            Write-Ok "WSL: $v"
            if ($wsl.DefaultVersion -and $wsl.DefaultVersion -ne '2') {
                Write-Warn "WSL default version is $($wsl.DefaultVersion). Docker needs WSL 2; fix with: wsl --set-default-version 2"
                $warnings++
            } elseif ($wsl.DefaultVersion) {
                Write-Ok "WSL default version: 2"
            }
        } else {
            Write-Err "WSL is not installed or not enabled ($($wsl.Detail))."
            Write-Host "      Docker Desktop's installer usually enables it for you. If it does not,"
            Write-Host "      open PowerShell as Administrator and run:"
            Write-Host ""
            Write-Host "          wsl --install"
            Write-Host ""
            Write-Host "      then restart Windows."
            $blocking++
        }

        # ---- Docker ------------------------------------------------------
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            Write-Ok "Docker is installed"
            Invoke-Native { & docker info 2>&1 | Out-Null }
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Docker engine is running"
            } else {
                Write-Warn "Docker is installed but the engine is not running - start Docker Desktop."
                $warnings++
            }
        } else {
            Write-Warn "Docker is not installed yet."
            $warnings++
        }

        Write-Host ""
        if ($blocking -gt 0) {
            Write-Err "$blocking blocking problem(s) - these must be fixed before Docker will work."
            exit 1
        } elseif ($warnings -gt 0) {
            Write-Ok "No blocking problems. $warnings item(s) above are worth a look."
            exit 0
        } else {
            Write-Ok "This machine is ready."
            exit 0
        }
    }

    'start' {
        Assert-Docker; Assert-Env
        Write-Step "Starting OpenTAKServer"
        Invoke-Compose ((Get-ActiveProfileArgs) + @('up', '-d'))
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to start. Try: .\ots.ps1 logs"; exit 1 }
        Write-Ok "Started. It may take a minute to become healthy."
        $fqdn = Get-EnvValue 'OTS_FQDN' 'localhost'
        if ($fqdn -eq '_') { $fqdn = 'localhost' }
        Write-Host "    Web UI: https://$fqdn"
    }

    'stop' {
        Assert-Docker
        Write-Step "Stopping OpenTAKServer"
        Invoke-Compose ((Get-ActiveProfileArgs) + @('down'))
        Write-Ok "Stopped. All data is preserved."
    }

    'restart' {
        Assert-Docker; Assert-Env
        Write-Step "Applying configuration and restarting"
        # 'compose restart' alone does NOT re-read .env - it restarts the
        # existing containers with their original environment. 'up -d' first
        # recreates anything whose configuration changed, so edits to .env
        # actually take effect; the restart then covers everything else.
        $profileArgs = Get-ActiveProfileArgs
        Invoke-Compose ($profileArgs + @('up', '-d'))
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to apply configuration. Try: .\ots.ps1 logs"; exit 1 }
        Invoke-Compose ($profileArgs + @('restart'))
        Write-Ok "Restarted."
    }

    'status' {
        Assert-Docker
        Write-Step "Container status"
        Invoke-Compose ((Get-ActiveProfileArgs) + @('ps'))
    }

    'set-address' {
        Assert-Docker; Assert-Env
        $new = if ($Arguments -and $Arguments.Count -gt 0) { $Arguments[0] } else { 'auto' }

        if ($new -eq 'auto') {
            $new = Get-LanAddress
            if (-not $new) {
                Write-Err "Could not detect a LAN address. Pass one explicitly:"
                Write-Host "    .\ots.ps1 set-address 192.168.1.50"
                exit 1
            }
        }

        $old = Get-EnvValue 'OTS_FQDN'
        if ($old -eq $new) {
            Write-Ok "Address is already $new - nothing to do."
            exit 0
        }

        Write-Step "Changing the server address from '$old' to '$new'"
        Set-EnvValue 'OTS_FQDN' $new

        # Only nginx consumes OTS_FQDN, and only for server_name / choosing the
        # Let's Encrypt certificate. It must be recreated, not merely restarted,
        # for the new value to be picked up.
        Invoke-Compose @('up', '-d', 'nginx')
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to recreate nginx."; exit 1 }

        Write-Ok "Updated. Web UI: https://$new"
        Write-Host ""
        Write-Host "    Note: no certificates needed reissuing. OpenTAKServer's server"
        Write-Host "    certificate is issued for the name 'opentakserver', not for your"
        Write-Host "    IP, so moving networks does not invalidate it."
        Write-Host ""
        Write-Warn "TAK clients still point at the old address - update each one."
    }

    'logs' {
        Assert-Docker
        $svc = if ($Arguments -and $Arguments.Count -gt 0) { $Arguments[0] } else { $null }
        if ($svc) {
            Write-Step "Following logs for '$svc' (Ctrl-C to stop)"
            Invoke-Compose @('logs', '-f', '--tail', '200', $svc)
        } else {
            Write-Step "Following all logs (Ctrl-C to stop)"
            Invoke-Compose @('logs', '-f', '--tail', '100')
        }
    }

    # -----------------------------------------------------------------------
    'update' {
        Assert-Docker; Assert-Env
        Write-Warn "Take a backup first if you have data you care about: .\ots.ps1 backup"
        Write-Step "Pulling newer images"
        # The nginx image is built locally, so it must be skipped here.
        $profileArgs = Get-ActiveProfileArgs
        Invoke-Compose ($profileArgs + @('pull', '--ignore-buildable'))
        Write-Step "Rebuilding the web server image"
        Invoke-Compose @('build', '--pull')
        Write-Step "Restarting with the new images"
        Invoke-Compose ($profileArgs + @('up', '-d'))
        Write-Ok "Update complete. Check with: .\ots.ps1 status"
        Write-Host "    To move to a different OpenTAKServer release, edit OTS_VERSION in .env first."
    }

    'backup' {
        Assert-Docker; Assert-Env
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $target = Join-Path $BackupDir $stamp
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        Write-Step "Backing up the database"
        $dbUser = Get-EnvValue 'POSTGRES_USER' 'ots'
        $dbName = Get-EnvValue 'POSTGRES_DB'   'ots'
        $sqlPath = Join-Path $target 'database.sql'

        # The dump is written inside the container and then copied out. Piping
        # it through PowerShell would corrupt it: 5.1 writes a UTF-8 BOM, which
        # psql then rejects on the first line.
        Invoke-Native { & docker compose exec -T ots-db sh -c "pg_dump -U '$dbUser' -d '$dbName' > /tmp/ots-backup.sql" }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Database backup failed. Is the stack running? (.\ots.ps1 start)"
            exit 1
        }
        Invoke-Native { & docker compose cp ots-db:/tmp/ots-backup.sql $sqlPath }
        if ($LASTEXITCODE -ne 0) { Write-Err "Could not copy the dump out of the container."; exit 1 }
        & docker compose exec -T ots-db rm -f /tmp/ots-backup.sql
        Write-Ok "Database written to $sqlPath"

        Write-Step "Backing up server data (certificates, config, uploads)"
        $mount = ($target -replace '\\', '/')
        Invoke-Native {
            & docker run --rm `
                -v "${ProjectName}_ots_data:/data:ro" `
                -v "${mount}:/backup" `
                alpine tar czf /backup/ots_data.tar.gz -C /data .
        }
        if ($LASTEXITCODE -ne 0) { Write-Err "Data backup failed."; exit 1 }
        Write-Ok "Server data written to $target\ots_data.tar.gz"

        Write-Host ""
        Write-Ok "Backup complete: $target"
        Write-Warn "Keep .env with this backup - without its passwords the backup is unusable."
    }

    'restore' {
        Assert-Docker; Assert-Env
        if (-not $Arguments -or $Arguments.Count -lt 1) {
            Write-Err "Usage: .\ots.ps1 restore <backup folder>"
            Write-Host "    Available backups:"
            if (Test-Path $BackupDir) {
                Get-ChildItem $BackupDir -Directory | ForEach-Object { Write-Host "      $($_.FullName)" }
            } else {
                Write-Host "      (none)"
            }
            exit 1
        }

        $source = $Arguments[0]
        if (-not (Test-Path $source)) { $source = Join-Path $BackupDir $Arguments[0] }
        if (-not (Test-Path $source)) { Write-Err "Backup not found: $($Arguments[0])"; exit 1 }

        $sqlFile  = Join-Path $source 'database.sql'
        $dataFile = Join-Path $source 'ots_data.tar.gz'
        if (-not (Test-Path $sqlFile))  { Write-Err "Missing database.sql in $source"; exit 1 }
        if (-not (Test-Path $dataFile)) { Write-Err "Missing ots_data.tar.gz in $source"; exit 1 }

        Write-Warn "This will REPLACE the current database and server data."
        if (-not $AssumeYes) {
            $answer = Read-Host "Type 'yes' to continue"
            if ($answer -ne 'yes') { Write-Host "Cancelled."; exit 0 }
        }

        Write-Step "Stopping application containers"
        Invoke-Compose @('stop', 'ots', 'ots_cot_parser', 'ots_eud_handler', 'ots_eud_handler_ssl', 'nginx', 'mediamtx')

        Write-Step "Restoring server data"
        $mount = ((Resolve-Path $source).Path -replace '\\', '/')
        Invoke-Native {
            & docker run --rm `
                -v "${ProjectName}_ots_data:/data" `
                -v "${mount}:/backup:ro" `
                alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf /backup/ots_data.tar.gz -C /data"
        }
        if ($LASTEXITCODE -ne 0) { Write-Err "Data restore failed."; exit 1 }
        Write-Ok "Server data restored"

        Write-Step "Restoring the database"
        Invoke-Compose @('up', '-d', 'ots-db')
        Start-Sleep -Seconds 10
        $dbUser = Get-EnvValue 'POSTGRES_USER' 'ots'
        $dbName = Get-EnvValue 'POSTGRES_DB'   'ots'

        # Copy the dump in and run psql against the file, rather than piping it
        # through PowerShell, which would mangle the encoding.
        Invoke-Native { & docker compose cp $sqlFile ots-db:/tmp/ots-restore.sql }
        if ($LASTEXITCODE -ne 0) { Write-Err "Could not copy the dump into the container."; exit 1 }
        Invoke-Native { & docker compose exec -T ots-db psql -U $dbUser -d $dbName -f /tmp/ots-restore.sql }
        if ($LASTEXITCODE -ne 0) { Write-Warn "psql reported errors - review the output above." }
        & docker compose exec -T ots-db rm -f /tmp/ots-restore.sql
        Write-Ok "Database restored"

        Write-Step "Starting everything"
        Invoke-Compose @('up', '-d')
        Write-Ok "Restore complete."
    }

    'config' {
        Assert-Docker; Assert-Env
        $tmp = Join-Path $env:TEMP "ots-config-$(Get-Date -Format 'yyyyMMddHHmmss').yml"

        Write-Step "Fetching config.yml from the server"
        Invoke-Native { & docker compose cp ots:/app/ots/config.yml $tmp }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not read config.yml. Has the server started at least once?"
            exit 1
        }

        Write-Host "    Opening in Notepad. Save and close the window when you are done."
        Start-Process notepad.exe -ArgumentList $tmp -Wait

        if (-not $AssumeYes) {
            $answer = Read-Host "Apply these changes and restart the server? (y/N)"
            if ($answer -notmatch '^[Yy]') { Write-Host "Cancelled - nothing was changed."; exit 0 }
        }

        Invoke-Native { & docker compose cp $tmp ots:/app/ots/config.yml }
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to write config.yml back."; exit 1 }
        Remove-Item $tmp -ErrorAction SilentlyContinue

        Write-Step "Restarting to pick up the new configuration"
        Invoke-Compose @('restart', 'ots', 'ots_cot_parser', 'ots_eud_handler', 'ots_eud_handler_ssl')
        Write-Ok "Configuration applied."
    }

    'shell' {
        Assert-Docker
        $svc = if ($Arguments -and $Arguments.Count -gt 0) { $Arguments[0] } else { 'ots' }
        Write-Step "Opening a shell in '$svc' (type 'exit' to leave)"
        # Probe for bash rather than reacting to the shell's exit code - a
        # command that failed inside bash would otherwise re-open sh.
        & docker compose exec -T $svc sh -c 'command -v bash > /dev/null 2>&1'
        if ($LASTEXITCODE -eq 0) {
            & docker compose exec $svc bash
        } else {
            & docker compose exec $svc sh
        }
    }

    'set-admin-password' {
        Assert-Docker; Assert-Env

        # Preferred input path: environment variables. The GUI uses these so
        # passwords never appear on a command line, where they would be visible
        # in the process list.
        if ($env:OTS_CURRENT_PASSWORD -and $env:OTS_NEW_PASSWORD) {
            $currentPw = $env:OTS_CURRENT_PASSWORD
            $newPw     = $env:OTS_NEW_PASSWORD
        }
        # Arguments are accepted for automation, but prompting is the default:
        # a password typed as an argument ends up in your shell history.
        elseif ($Arguments -and $Arguments.Count -ge 2) {
            $currentPw = $Arguments[0]
            $newPw     = $Arguments[1]
        } else {
            $currentPw = ConvertTo-PlainText (Read-Host "Current administrator password" -AsSecureString)
            $newPw     = ConvertTo-PlainText (Read-Host "New password" -AsSecureString)
            $confirmPw = ConvertTo-PlainText (Read-Host "Confirm new password" -AsSecureString)
            if ($newPw -ne $confirmPw) { Write-Err "The two new passwords do not match."; exit 1 }
        }

        if ($newPw.Length -lt 8) { Write-Err "Password must be at least 8 characters."; exit 1 }
        if ($newPw -eq 'password') { Write-Err "That is the default password. Pick something else."; exit 1 }

        Write-Step "Changing the administrator password"

        $jar = Join-Path $env:TEMP "ots-cookies-$PID.txt"
        try {
            $login = Invoke-OtsApiJson -Path '/api/login?include_auth_token' `
                                       -Body @{ username = 'administrator'; password = $currentPw } `
                                       -CookieJar $jar
            if ($null -eq $login -or $login.meta.code -ne 200) {
                Write-Err "Could not sign in as administrator with that current password."
                exit 1
            }

            $token = $login.response.user.authentication_token
            $csrf  = $login.response.csrf_token

            $change = Invoke-OtsApiJson -Path '/api/password/change' `
                        -Body @{ password = $currentPw; new_password = $newPw; new_password_confirm = $newPw } `
                        -ExtraHeaders @("Authentication-Token: $token", "X-CSRF-Token: $csrf") `
                        -CookieJar $jar

            if ($null -eq $change -or $change.meta.code -ne 200) {
                Write-Err "The server rejected the change."
                if ($change.response.errors) { $change.response.errors | ConvertTo-Json -Depth 5 }
                exit 1
            }
        } finally {
            Remove-Item $jar -Force -ErrorAction SilentlyContinue
        }

        if (Test-AdminPassword -Password 'password') {
            Write-Err "The default password still works - the change did not take effect."
            exit 1
        }
        Write-Ok "Password changed, and the default no longer works."
    }

    # -----------------------------------------------------------------------
    'ca-export' {
        Assert-Docker; Assert-Env
        $out = Join-Path $PSScriptRoot 'ca.pem'
        Write-Step "Exporting the OpenTAKServer CA certificate"
        Invoke-Native { & docker compose cp ots:/app/ots/ca/ca.pem $out }
        if ($LASTEXITCODE -ne 0) { Write-Err "Could not export the CA. Is the server running?"; exit 1 }
        Write-Ok "Written to $out"
        Write-Host ""
        Write-Host "    This is the public CA certificate - safe to share with your users."
        Write-Host "    Most TAK clients are better off enrolling automatically instead;"
        Write-Host "    see docs\CLIENTS.md."
    }

    'go-public' {
        Assert-Docker; Assert-Env

        Write-Step "Setting up internet access"

        # ------------------------------------------------------------------
        # Refuse to expose a server that still has the default password.
        # ------------------------------------------------------------------
        if (Test-AdminPassword -Password 'password') {
            Write-Err "The administrator account still uses the default password."
            Write-Host ""
            Write-Host "    Every OpenTAKServer install ships with administrator/password."
            Write-Host "    Exposing this to the internet unchanged means it will be taken over,"
            Write-Host "    probably within hours. Change it first:"
            Write-Host ""
            Write-Host "        .\ots.ps1 set-admin-password" -ForegroundColor White
            Write-Host ""
            exit 1
        }
        Write-Ok "Administrator password is not the default"

        # ------------------------------------------------------------------
        # DuckDNS details
        # ------------------------------------------------------------------
        $sub   = Get-EnvValue 'DUCKDNS_SUBDOMAIN'
        $token = Get-EnvValue 'DUCKDNS_TOKEN'
        $email = Get-EnvValue 'LETSENCRYPT_EMAIL'

        if ($Arguments -and $Arguments.Count -ge 1) { $sub   = $Arguments[0] }
        if ($Arguments -and $Arguments.Count -ge 2) { $token = $Arguments[1] }
        if ($Arguments -and $Arguments.Count -ge 3) { $email = $Arguments[2] }

        if (-not $sub) {
            Write-Host ""
            Write-Host "    Sign in at https://www.duckdns.org (free, Google/GitHub login),"
            Write-Host "    create a subdomain, and copy the token shown at the top."
            Write-Host ""
            $sub = Read-Host "    DuckDNS subdomain (just the name, not .duckdns.org)"
        }
        $sub = $sub -replace '\.duckdns\.org$', ''
        if (-not $sub) { Write-Err "A subdomain is required."; exit 1 }

        if (-not $token) { $token = Read-Host "    DuckDNS token" }
        if (-not $token) { Write-Err "A token is required."; exit 1 }

        if (-not $email) { $email = Read-Host "    Email for Let's Encrypt expiry notices" }
        if (-not $email) { Write-Err "An email address is required by Let's Encrypt."; exit 1 }

        $fqdn = "$sub.duckdns.org"

        # ------------------------------------------------------------------
        # Verify the token before writing anything
        # ------------------------------------------------------------------
        Write-Step "Checking the DuckDNS token and updating the record"
        $resp = (& curl.exe -s --max-time 15 "https://www.duckdns.org/update?domains=$sub&token=$token&ip=") -replace '\s', ''
        if ($resp -ne 'OK') {
            Write-Err "DuckDNS rejected that subdomain/token combination (replied '$resp')."
            Write-Host "    Check both at https://www.duckdns.org and try again."
            exit 1
        }
        Write-Ok "$fqdn now points at this connection"

        # ------------------------------------------------------------------
        # Write configuration
        # ------------------------------------------------------------------
        Write-Step "Writing configuration"
        Set-EnvValue 'DUCKDNS_SUBDOMAIN' $sub
        Set-EnvValue 'DUCKDNS_TOKEN'     $token
        Set-EnvValue 'LETSENCRYPT_EMAIL' $email
        Set-EnvValue 'OTS_FQDN'          $fqdn
        Set-EnvValue 'OTS_TLS_MODE'      'letsencrypt'
        Write-Ok "OTS_FQDN=$fqdn, TLS mode=letsencrypt"

        Write-Step "Starting the dynamic DNS updater"
        Invoke-Compose @('--profile', 'public', 'up', '-d')
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to start the public services."; exit 1 }
        Write-Ok "Running"

        # ------------------------------------------------------------------
        # What the user has to do
        # ------------------------------------------------------------------
        $lan = Get-LanAddress
        Write-Host ""
        Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  Two things left, both outside this machine:" -ForegroundColor White
        Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  1. Forward these ports on your router to $lan" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "       80    TCP   required for certificate issue AND renewal"
        Write-Host "       443   TCP   web UI"
        Write-Host "       8443  TCP   Marti API"
        Write-Host "       8446  TCP   certificate enrollment"
        Write-Host "       8089  TCP   CoT streaming (TLS)  <- clients need this"
        Write-Host "       8080  TCP   Marti over plain HTTP (unencrypted)"
        Write-Host "       8883  TCP   MQTT over TLS"
        Write-Host "       1935,1936,8322,8554,8888,8889  TCP   video"
        Write-Host "       8000,8001                      UDP   video (plain RTSP media)"
        Write-Host "       8004,8005                      UDP   video (encrypted RTSPS media)"
        Write-Host "       8189,8890                      UDP   video (WebRTC, SRT)"
        Write-Host ""
        Write-Host "     Give this machine a DHCP reservation too, or the LAN IP will"
        Write-Host "     change and every forward will point at nothing."
        Write-Host ""
        Write-Host "  2. Allow them through Windows Firewall - run once, as Administrator:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "       .\windows-firewall.ps1" -ForegroundColor White
        Write-Host ""
        Write-Host "  Then get your certificate:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "       .\ots.ps1 check-internet     verify it is reachable" -ForegroundColor White
        Write-Host "       .\ots.ps1 cert-request       issue the certificate" -ForegroundColor White
        Write-Host ""
    }

    'check-internet' {
        Assert-Docker; Assert-Env
        $problems = 0

        Write-Step "Checking internet reachability"

        $fqdn = Get-EnvValue 'OTS_FQDN'
        if (-not $fqdn -or $fqdn -eq '_' -or $fqdn -match '^\d+\.\d+\.\d+\.\d+$') {
            Write-Err "OTS_FQDN is '$fqdn' - not a public hostname. Run: .\ots.ps1 go-public"
            exit 1
        }
        Write-Ok "Hostname: $fqdn"

        Write-Host "    Looking up this connection's public IP..."
        $publicIp = Get-PublicIp
        if (-not $publicIp) {
            Write-Warn "Could not determine your public IP (no internet?)."
            $problems++
        } else {
            Write-Ok "Public IP: $publicIp"
        }

        try {
            $resolved = ([System.Net.Dns]::GetHostAddresses($fqdn) |
                         Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                         Select-Object -First 1).IPAddressToString
        } catch { $resolved = $null }

        if (-not $resolved) {
            Write-Err "$fqdn does not resolve. Is the DDNS updater running? (.\ots.ps1 status)"
            $problems++
        } elseif ($publicIp -and $resolved -ne $publicIp) {
            Write-Err "$fqdn points at $resolved but you are on $publicIp."
            Write-Host "      DNS may just be catching up - wait a few minutes and retry."
            $problems++
        } elseif ($publicIp) {
            Write-Ok "$fqdn correctly resolves to $publicIp"
        }

        # Local listeners. This proves the stack is up, NOT that your router
        # forwards anything - only a probe from outside can show that.
        Write-Host ""
        Write-Host "    Local listeners:"
        foreach ($p in 80, 443, 8080, 8443, 8446, 8883, 8088, 8089) {
            $listening = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
            if ($listening) { Write-Ok "port $p is listening" }
            else { Write-Err "port $p is NOT listening"; $problems++ }
        }

        Write-Host ""
        if ($problems -eq 0) {
            Write-Ok "Everything checks out on this side."
        } else {
            Write-Err "$problems problem(s) - see above."
        }
        Write-Host ""
        Write-Host "    This cannot tell you whether your ROUTER forwards the ports." -ForegroundColor DarkGray
        Write-Host "    The real test is 'cert-request': Let's Encrypt only succeeds if" -ForegroundColor DarkGray
        Write-Host "    it can reach port 80 from the internet." -ForegroundColor DarkGray
    }

    'cert-request' {
        Assert-Docker; Assert-Env
        $fqdn  = Get-EnvValue 'OTS_FQDN'
        $email = Get-EnvValue 'LETSENCRYPT_EMAIL'

        if (-not $fqdn -or $fqdn -eq '_' -or $fqdn -match '^\d+\.\d+\.\d+\.\d+$') {
            Write-Err "OTS_FQDN in .env must be a real public domain name, not '$fqdn'."
            exit 1
        }
        if (-not $email) { Write-Err "Set LETSENCRYPT_EMAIL in .env first."; exit 1 }

        Write-Step "Requesting a certificate for $fqdn"
        Write-Host "    Port 80 on this machine must be reachable from the internet."
        Write-Host ""

        Invoke-Compose @('up', '-d', 'nginx')
        Invoke-Native {
            & docker compose run --rm --entrypoint certbot certbot `
                certonly --webroot -w /var/www/certbot `
                -d $fqdn --email $email --agree-tos --no-eff-email --non-interactive
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Certificate request failed. Common causes:"
            Write-Host "      - $fqdn does not point at this machine's public IP"
            Write-Host "      - port 80 is not forwarded through your router/firewall"
            exit 1
        }

        Write-Ok "Certificate issued"
        Write-Step "Enabling automatic renewal and reloading nginx"
        Invoke-Compose @('--profile', 'public', 'up', '-d')
        Invoke-Compose @('restart', 'nginx')
        Write-Ok "Done. Make sure OTS_TLS_MODE=letsencrypt is set in .env."
    }

    'tls-only' {
        Assert-Docker; Assert-Env

        $mode = if ($Arguments -and $Arguments.Count -ge 1) { $Arguments[0].ToLower() } else { 'on' }
        if ($mode -notin @('on', 'all', 'off', 'status')) {
            Write-Err "Usage: .\ots.ps1 tls-only [on|all|off|status]"
            Write-Host ""
            Write-Host "      on      close the unencrypted TAK ports; video keeps both plain and"
            Write-Host "              encrypted (cameras and encoders often only speak plain RTSP)"
            Write-Host "      all     also close plain video - encrypted video only"
            Write-Host "      off     re-open everything"
            Write-Host "      status  show the current state"
            exit 1
        }

        $lan = Get-LanAddress

        $takPlain = @(
            @{ Port = (Get-EnvValue 'OTS_MARTI_HTTP_PORT' '8080'); Name = 'Marti API over plain HTTP'; Instead = "$(Get-EnvValue 'OTS_MARTI_HTTPS_PORT' '8443') (HTTPS)" }
            @{ Port = (Get-EnvValue 'OTS_TCP_COT_PORT' '8088');    Name = 'CoT streaming, unencrypted'; Instead = "$(Get-EnvValue 'OTS_SSL_COT_PORT' '8089') (TLS)" }
        )
        $videoPlain = @(
            @{ Port = (Get-EnvValue 'VIDEO_RTMP_PORT' '1935');   Name = 'RTMP video'; Instead = "$(Get-EnvValue 'VIDEO_RTMPS_PORT' '1936') (RTMPS)" }
            @{ Port = (Get-EnvValue 'VIDEO_RTSP_PORT' '8554');   Name = 'RTSP video'; Instead = "$(Get-EnvValue 'VIDEO_RTSPS_PORT' '8322') (RTSPS)" }
            @{ Port = (Get-EnvValue 'VIDEO_HLS_PORT' '8888');    Name = 'HLS video'; Instead = 'https://<server>/hls' }
            @{ Port = (Get-EnvValue 'VIDEO_WEBRTC_PORT' '8889'); Name = 'WebRTC video'; Instead = 'https://<server>/webrtc' }
        )

        # -------------------------------------------------------------------
        if ($mode -eq 'status') {
            Write-Step "Encryption status"
            $takClosed   = (Get-EnvValue 'OTS_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'
            $videoClosed = (Get-EnvValue 'OTS_VIDEO_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'

            if ($takClosed) {
                Write-Ok "TAK ports: encrypted only - 8080 and 8088 are closed to the network"
            } else {
                Write-Warn "TAK ports: unencrypted 8080 and 8088 are open to the network"
            }
            if ($videoClosed) {
                Write-Ok "Video: encrypted only - RTSPS and RTMPS"
            } else {
                Write-Ok "Video: plain and encrypted both available - RTSP+RTSPS, RTMP+RTMPS"
            }
            Write-Host ""
            Write-Host "    Always encrypted: 443, $(Get-EnvValue 'OTS_MARTI_HTTPS_PORT' '8443'), $(Get-EnvValue 'OTS_CERT_ENROLLMENT_PORT' '8446'), $(Get-EnvValue 'OTS_MQTT_PORT' '8883'), $(Get-EnvValue 'OTS_SSL_COT_PORT' '8089'), $(Get-EnvValue 'VIDEO_RTMPS_PORT' '1936'), $(Get-EnvValue 'VIDEO_RTSPS_PORT' '8322')"
            exit 0
        }

        # -------------------------------------------------------------------
        # Target state for each mode
        # -------------------------------------------------------------------
        switch ($mode) {
            'off' { $takBind = '0.0.0.0';   $videoBind = '0.0.0.0';   $mtx = 'optional' }
            'on'  { $takBind = '127.0.0.1'; $videoBind = '0.0.0.0';   $mtx = 'optional' }
            'all' { $takBind = '127.0.0.1'; $videoBind = '127.0.0.1'; $mtx = 'strict' }
        }

        Write-Step "Applying encryption policy: $mode"
        if ($mode -eq 'off') {
            Write-Host "    Re-opening every unencrypted port to the network."
        } else {
            Write-Host "    Closing to the network:"
            foreach ($p in $takPlain) { Write-Host ("      {0,-5}  {1,-28} use {2}" -f $p.Port, $p.Name, $p.Instead) }
            if ($mode -eq 'all') {
                foreach ($p in $videoPlain) { Write-Host ("      {0,-5}  {1,-28} use {2}" -f $p.Port, $p.Name, $p.Instead) }
            } else {
                Write-Host ""
                Write-Host "    Video is left alone - plain RTSP and RTMP stay available alongside"
                Write-Host "    RTSPS and RTMPS, because many cameras and encoders only speak plain."
            }
            Write-Host ""
            Write-Host "    Closed ports remain reachable from this machine on 127.0.0.1."
        }
        Write-Host ""

        Set-EnvValue 'OTS_PLAINTEXT_BIND'       $takBind
        Set-EnvValue 'OTS_VIDEO_PLAINTEXT_BIND' $videoBind
        Write-Ok "Configuration written"

        Write-Step "Setting MediaMTX encryption to '$mtx'"
        # 'optional' runs the plain and TLS listeners side by side.
        # 'strict' drops the plain ones entirely.
        $sedScript = "sed -i 's/^encryption: .*/encryption: " + '"' + $mtx + '"' + "/; s/^rtmpEncryption: .*/rtmpEncryption: " + '"' + $mtx + '"' + "/' /app/ots/mediamtx/mediamtx.yml"
        Invoke-Native { & docker compose exec -T ots sh -c $sedScript }
        if ($LASTEXITCODE -ne 0) { Write-Warn "Could not update mediamtx.yml." } else { Write-Ok "MediaMTX set to '$mtx'" }

        Write-Step "Applying"
        Invoke-Compose ((Get-ActiveProfileArgs) + @('up', '-d'))
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to recreate containers."; exit 1 }
        Invoke-Compose @('restart', 'mediamtx')

        # -------------------------------------------------------------------
        Write-Step "Verifying from this machine's network address ($lan)"
        Start-Sleep -Seconds 6
        $bad = 0

        $shouldBeClosed = @()
        $shouldBeOpen   = @(
            @{ Port = (Get-EnvValue 'OTS_HTTPS_PORT' '443');             Name = 'Web UI' }
            @{ Port = (Get-EnvValue 'OTS_MARTI_HTTPS_PORT' '8443');      Name = 'Marti API' }
            @{ Port = (Get-EnvValue 'OTS_CERT_ENROLLMENT_PORT' '8446');  Name = 'Enrollment' }
            @{ Port = (Get-EnvValue 'OTS_SSL_COT_PORT' '8089');          Name = 'CoT over TLS' }
            @{ Port = (Get-EnvValue 'OTS_MQTT_PORT' '8883');             Name = 'MQTT over TLS' }
            @{ Port = (Get-EnvValue 'VIDEO_RTSPS_PORT' '8322');          Name = 'RTSPS video' }
        )

        if ($mode -ne 'off') { $shouldBeClosed += $takPlain } else { $shouldBeOpen += $takPlain }
        if ($mode -eq 'all') { $shouldBeClosed += $videoPlain } else { $shouldBeOpen += $videoPlain }

        foreach ($p in $shouldBeClosed) {
            $open = Test-NetConnection -ComputerName $lan -Port ([int]$p.Port) -WarningAction SilentlyContinue -InformationLevel Quiet
            if ($open) { Write-Err "port $($p.Port) ($($p.Name)) is STILL reachable"; $bad++ }
            else       { Write-Ok  "port $($p.Port) ($($p.Name)) closed to the network" }
        }
        Write-Host ""
        foreach ($p in $shouldBeOpen) {
            $open = Test-NetConnection -ComputerName $lan -Port ([int]$p.Port) -WarningAction SilentlyContinue -InformationLevel Quiet
            if ($open) { Write-Ok  "port $($p.Port) ($($p.Name)) reachable" }
            else       { Write-Err "port $($p.Port) ($($p.Name)) is NOT reachable - it should be!"; $bad++ }
        }

        Write-Host ""
        if ($bad -eq 0) {
            switch ($mode) {
                'on'  { Write-Ok "TAK traffic is encrypted-only. Video accepts plain and encrypted." }
                'all' { Write-Ok "Everything reachable from the network is encrypted." }
                'off' { Write-Ok "All unencrypted ports are open again." }
            }
            Write-Host "    Change with:  .\ots.ps1 tls-only [on|all|off]"
        } else {
            Write-Err "$bad port(s) are not in the expected state - see above."
            exit 1
        }
    }


    'server-cert' {
        Assert-Docker; Assert-Env
        Write-Step "Reissuing the OpenTAKServer server certificate"
        Invoke-Native { & docker compose exec ots flask --app /app/venv/lib/python3.13/site-packages/opentakserver/app.py ots issue-server-certificate }
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to reissue the certificate."; exit 1 }
        Invoke-Compose @('restart', 'nginx', 'mediamtx', 'ots_eud_handler_ssl')
        Write-Ok "Reissued and services restarted."
    }

    # -----------------------------------------------------------------------
    'doctor' {
        Write-Step "Checking your setup"
        $problems = 0
        $warnings = 0

        $virt = Test-Virtualization
        if ($virt.Ok) {
            Write-Ok "Hardware virtualization: $($virt.Detail)"
        } else {
            Write-Err "Hardware virtualization is $($virt.Detail) - enable it in BIOS/UEFI"; $problems++
        }

        $wsl = Get-WslInfo
        if ($wsl.Installed) {
            Write-Ok ("WSL: " + $(if ($wsl.Version) { "version $($wsl.Version)" } else { 'installed' }))
            if ($wsl.DefaultVersion -and $wsl.DefaultVersion -ne '2') {
                Write-Warn "WSL default version is $($wsl.DefaultVersion); Docker needs 2 (wsl --set-default-version 2)"
                $warnings++
            }
        } else {
            Write-Err "WSL is not usable - run 'wsl --install' as Administrator, then reboot"; $problems++
        }

        if (Get-Command docker -ErrorAction SilentlyContinue) {
            Write-Ok "Docker is installed"
            Invoke-Native { & docker info 2>&1 | Out-Null }
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Docker engine is running"
            } else {
                Write-Err "Docker is not running - start Docker Desktop"; $problems++
            }
        } else {
            Write-Err "Docker is not installed"; $problems++
        }

        if (Test-Path (Join-Path $PSScriptRoot '.env')) {
            Write-Ok ".env exists"
            foreach ($key in @('POSTGRES_PASSWORD', 'RABBITMQ_PASSWORD')) {
                $val = Get-EnvValue $key
                if (-not $val -or $val -eq 'CHANGEME') {
                    Write-Err "$key is not set properly in .env - run .\setup.ps1 -Force"; $problems++
                } else {
                    Write-Ok "$key is set"
                }
            }
        } else {
            Write-Err ".env is missing - run .\setup.ps1"; $problems++
        }

        # Any host adapter inside the Docker subnet breaks routing in confusing
        # ways. WSL and Hyper-V both claim ranges in 172.16-31.x, so check
        # every interface, not just the Wi-Fi one.
        $subnet = Get-EnvValue 'OTS_NETWORK_SUBNET' '172.28.0.0/16'
        $clashes = @()
        try {
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                ForEach-Object {
                    if (Test-IpInSubnet $_.IPAddress $subnet) {
                        $clashes += "$($_.InterfaceAlias) ($($_.IPAddress))"
                    }
                }
        } catch { }

        if ($clashes.Count -gt 0) {
            Write-Err "These adapters sit inside the Docker subnet ($subnet):"
            foreach ($c in $clashes) { Write-Host "        $c" }
            Write-Host "      Pick a free range for OTS_NETWORK_SUBNET and OTS_RABBITMQ_IP in .env"
            Write-Host "      (check 'ipconfig' first), then: .\ots.ps1 stop; .\ots.ps1 start"
            $problems++
        } else {
            Write-Ok "Docker subnet ($subnet) does not clash with any adapter"
        }

        # Windows blocks most inbound traffic on networks marked Public, which
        # stops other devices reaching the server even though it is running.
        try {
            $pub = Get-NetConnectionProfile -ErrorAction Stop |
                   Where-Object { $_.NetworkCategory -eq 'Public' }
            if ($pub) {
                Write-Warn "Network '$($pub[0].Name)' is set to Public, so Windows Firewall will"
                Write-Warn "block other devices from reaching this server. Works locally, not from"
                Write-Warn "phones or tablets. Set it to Private in Windows network settings if you"
                Write-Warn "trust this network, or add inbound rules for the TAK ports."
                $warnings++
            } else {
                Write-Ok "Network profile allows inbound connections from other devices"
            }
        } catch { }

        # The address the tooling advertises should match reality.
        $fqdn = Get-EnvValue 'OTS_FQDN'
        if ($lan -and $fqdn -match '^\d+\.\d+\.\d+\.\d+$' -and $fqdn -ne $lan) {
            Write-Warn "OTS_FQDN is $fqdn but this machine is now $lan - run: .\ots.ps1 set-address"
            $warnings++
        }

        if (Get-Command docker -ErrorAction SilentlyContinue) {
            $running = (& docker compose ps --services --filter status=running) 2>$null
            if ($running) {
                Write-Ok "Running services: $($running -join ', ')"
            } else {
                Write-Warn "No containers are running - try .\ots.ps1 start"
            }

            $health = (& docker inspect -f '{{.State.Health.Status}}' opentakserver) 2>$null
            if ($health -eq 'healthy') {
                Write-Ok "OpenTAKServer is healthy"
            } elseif ($health) {
                Write-Warn "OpenTAKServer health: $health  (see .\ots.ps1 logs ots)"
            }
        }

        Write-Host ""
        if ($problems -eq 0 -and $warnings -eq 0) {
            Write-Ok "No problems found."
        } elseif ($problems -eq 0) {
            Write-Ok "No errors, but $warnings warning(s) above are worth reading."
        } else {
            Write-Err "$problems problem(s) and $warnings warning(s) found - see above."
        }
    }

    'reset' {
        Assert-Docker
        Write-Host ""
        Write-Warn "This DELETES EVERYTHING: the database, all certificates, all"
        Write-Warn "uploaded data packages and recordings. Clients will have to"
        Write-Warn "re-enrol afterwards. There is no undo."
        Write-Host ""
        if (-not $AssumeYes) {
            $answer = Read-Host "Type 'DELETE' to confirm"
            if ($answer -ne 'DELETE') { Write-Host "Cancelled."; exit 0 }
        }

        Write-Step "Removing containers and volumes"
        Invoke-Compose @('down', '-v')
        Write-Ok "Done. Run .\setup.ps1 to start fresh."
    }

    default {
        Write-Err "Unknown command: $Command"
        Write-Host "    Run  .\ots.ps1 help  to see what is available."
        exit 1
    }
}

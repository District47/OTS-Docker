<#
.SYNOPSIS
    Graphical control panel for the OpenTAKServer Docker stack.

.DESCRIPTION
    A button for every ots.ps1 command, with live output and - importantly - a
    check after each action that confirms the change actually took effect.

    Launch it by double-clicking "OTS Manager.cmd".
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $Root

# ===========================================================================
#  Theme
# ===========================================================================
$ColBg      = [System.Drawing.Color]::FromArgb(24, 26, 30)
$ColPanel   = [System.Drawing.Color]::FromArgb(32, 35, 41)
$ColText    = [System.Drawing.Color]::FromArgb(226, 229, 235)
$ColMuted   = [System.Drawing.Color]::FromArgb(150, 156, 168)
$ColOk      = [System.Drawing.Color]::FromArgb(87, 190, 120)
$ColWarn    = [System.Drawing.Color]::FromArgb(226, 178, 70)
$ColErr     = [System.Drawing.Color]::FromArgb(224, 108, 108)
$ColAccent  = [System.Drawing.Color]::FromArgb(88, 156, 226)

$FontUi   = New-Object System.Drawing.Font('Segoe UI', 9)
$FontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$FontHead = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$FontMono = New-Object System.Drawing.Font('Consolas', 9)

# ===========================================================================
#  Small helpers
# ===========================================================================
function Get-EnvValue {
    param([string]$Key, [string]$Default = '')
    $f = Join-Path $Root '.env'
    if (-not (Test-Path $f)) { return $Default }
    foreach ($line in Get-Content $f) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $Default
}

function Get-HttpStatus {
    param([string]$Url, [int]$TimeoutSec = 6)
    try {
        $code = & curl.exe -sk -o NUL -w '%{http_code}' --max-time $TimeoutSec $Url 2>$null
        return [int]$code
    } catch { return 0 }
}

function Test-DockerUp {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-RunningServices {
    try {
        $out = & docker compose ps --services --filter status=running 2>$null
        if (-not $out) { return @() }
        return @($out | Where-Object { $_ -and $_.Trim() })
    } catch { return @() }
}

function Test-OtsHealthy {
    try {
        $s = & docker inspect -f '{{.State.Health.Status}}' opentakserver 2>$null
        return ($s -eq 'healthy')
    } catch { return $false }
}

function Find-DockerDesktop {
    <#  Docker Desktop installs per-machine or per-user depending on how it was
        installed, so check both. #>
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Test-VirtualizationOk {
    <#  HypervisorPresent first: Win32_Processor.VirtualizationFirmwareEnabled
        reports false whenever a hypervisor is already running, so checking it
        alone would wrongly accuse a healthy machine of having VT-x disabled. #>
    try {
        if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { return $true }
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return [bool]$cpu.VirtualizationFirmwareEnabled
    } catch { return $true }   # undetectable - do not block on a guess
}

function Test-DockerInstalled {
    return ($null -ne (Get-Command docker -ErrorAction SilentlyContinue)) -or ($null -ne (Find-DockerDesktop))
}

function Wait-ForDockerEngine {
    <#  Docker Desktop takes a while to bring the engine up after launch. #>
    param([int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerUp) { return $true }
        Start-Sleep -Seconds 3
        [System.Windows.Forms.Application]::DoEvents()
    }
    return $false
}

function Test-SetupComplete {
    return (Test-Path (Join-Path $Root '.env'))
}

function Test-DefaultAdminPassword {
    <#  True when administrator/password still works - i.e. NOT yet changed. #>
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        '{"username":"administrator","password":"password"}' |
            Out-File -FilePath $tmp -Encoding ascii -NoNewline
        $raw = & curl.exe -sk -X POST 'https://localhost/api/login' `
                    -H 'Content-Type: application/json' --max-time 8 --data-binary "@$tmp" 2>$null
        return ($raw -match '"code"\s*:\s*200')
    } catch { return $false }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
#  Form
# ===========================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'OpenTAKServer Manager'
$form.Size = New-Object System.Drawing.Size(1080, 740)
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $ColBg
$form.ForeColor = $ColText
$form.Font = $FontUi

# --- header -----------------------------------------------------------------
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 104
$header.BackColor = $ColPanel
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'OpenTAKServer'
$title.Font = $FontHead
$title.ForeColor = $ColText
$title.Location = New-Object System.Drawing.Point(16, 12)
$title.AutoSize = $true
$header.Controls.Add($title)

$lblDocker = New-Object System.Windows.Forms.Label
$lblDocker.Location = New-Object System.Drawing.Point(18, 44)
$lblDocker.AutoSize = $true
$lblDocker.Font = $FontBold
$header.Controls.Add($lblDocker)

$lblServices = New-Object System.Windows.Forms.Label
$lblServices.Location = New-Object System.Drawing.Point(18, 66)
$lblServices.AutoSize = $true
$header.Controls.Add($lblServices)

$lblWeb = New-Object System.Windows.Forms.Label
$lblWeb.Location = New-Object System.Drawing.Point(300, 44)
$lblWeb.AutoSize = $true
$lblWeb.Font = $FontBold
$header.Controls.Add($lblWeb)

$lblAddress = New-Object System.Windows.Forms.Label
$lblAddress.Location = New-Object System.Drawing.Point(300, 66)
$lblAddress.AutoSize = $true
$header.Controls.Add($lblAddress)

$lblSecurity = New-Object System.Windows.Forms.Label
$lblSecurity.Location = New-Object System.Drawing.Point(660, 44)
$lblSecurity.AutoSize = $true
$lblSecurity.Font = $FontBold
$header.Controls.Add($lblSecurity)

$lblTls = New-Object System.Windows.Forms.Label
$lblTls.Location = New-Object System.Drawing.Point(660, 66)
$lblTls.AutoSize = $true
$header.Controls.Add($lblTls)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
$btnRefresh.Location = New-Object System.Drawing.Point(950, 12)
$btnRefresh.Anchor = 'Top,Right'
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.BackColor = $ColBg
$btnRefresh.ForeColor = $ColText
$header.Controls.Add($btnRefresh)

# --- verification banner ----------------------------------------------------
$banner = New-Object System.Windows.Forms.Panel
$banner.Dock = 'Bottom'
$banner.Height = 58
$banner.BackColor = $ColPanel
$form.Controls.Add($banner)

$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Dock = 'Fill'
$lblBanner.TextAlign = 'MiddleLeft'
$lblBanner.Font = $FontBold
$lblBanner.ForeColor = $ColMuted
$lblBanner.Text = '   Ready.'
$banner.Controls.Add($lblBanner)

# --- left button column -----------------------------------------------------
$side = New-Object System.Windows.Forms.FlowLayoutPanel
$side.Dock = 'Left'
$side.Width = 250
$side.BackColor = $ColBg
$side.FlowDirection = 'TopDown'
$side.WrapContents = $false
$side.AutoScroll = $true
$side.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$form.Controls.Add($side)

# --- output console ---------------------------------------------------------
$outer = New-Object System.Windows.Forms.Panel
$outer.Dock = 'Fill'
$outer.BackColor = $ColBg
$outer.Padding = New-Object System.Windows.Forms.Padding(0, 8, 10, 8)
$form.Controls.Add($outer)
$outer.BringToFront()

$console = New-Object System.Windows.Forms.RichTextBox
$console.Dock = 'Fill'
$console.BackColor = [System.Drawing.Color]::FromArgb(16, 18, 21)
$console.ForeColor = $ColText
$console.Font = $FontMono
$console.ReadOnly = $true
$console.BorderStyle = 'None'
$console.WordWrap = $false
$console.ScrollBars = 'Both'
$outer.Controls.Add($console)

# ===========================================================================
#  Console output
# ===========================================================================
function Add-Line {
    param([string]$Text, $Color = $null)
    if ($null -eq $Color) {
        $Color = switch -Regex ($Text) {
            '^\s*\[ok\]'  { $ColOk;     break }
            '^\s*\[x\]'   { $ColErr;    break }
            '^\s*\[!\]'   { $ColWarn;   break }
            '^\s*==>'     { $ColAccent; break }
            default       { $ColText }
        }
    }
    $console.SelectionStart = $console.TextLength
    $console.SelectionLength = 0
    $console.SelectionColor = $Color
    $console.AppendText("$Text`r`n")
    $console.SelectionColor = $console.ForeColor
    $console.ScrollToCaret()
}

function Clear-Console { $console.Clear() }

function Set-Banner {
    param([string]$Text, [ValidateSet('ok', 'fail', 'warn', 'busy', 'idle')] [string]$State)
    $lblBanner.Text = "   $Text"
    switch ($State) {
        'ok'   { $lblBanner.ForeColor = $ColOk;    $banner.BackColor = [System.Drawing.Color]::FromArgb(26, 46, 32) }
        'fail' { $lblBanner.ForeColor = $ColErr;   $banner.BackColor = [System.Drawing.Color]::FromArgb(50, 28, 28) }
        'warn' { $lblBanner.ForeColor = $ColWarn;  $banner.BackColor = [System.Drawing.Color]::FromArgb(48, 41, 24) }
        'busy' { $lblBanner.ForeColor = $ColAccent;$banner.BackColor = $ColPanel }
        'idle' { $lblBanner.ForeColor = $ColMuted; $banner.BackColor = $ColPanel }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# ===========================================================================
#  Status panel
# ===========================================================================
$script:DockerOk = $false

function Update-Status {
    param([switch]$IncludeSecurity)

    # Read from .env first so the address and TLS mode still show even when
    # Docker is down.
    $fqdn = Get-EnvValue 'OTS_FQDN' '(not set up)'
    if ($fqdn -eq '_') { $fqdn = 'any (localhost)' }
    $lblAddress.Text = "Address: $fqdn"
    $lblAddress.ForeColor = $ColMuted
    $takClosed   = (Get-EnvValue 'OTS_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'
    $videoClosed = (Get-EnvValue 'OTS_VIDEO_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'
    $tlsOnly = if ($takClosed -and $videoClosed) { ', all encrypted' }
               elseif ($takClosed)               { ', TAK encrypted' }
               else                              { '' }
    $lblTls.Text = "TLS: $(Get-EnvValue 'OTS_TLS_MODE' '-')$tlsOnly"
    $lblTls.ForeColor = $ColMuted

    $script:DockerOk = Test-DockerUp
    if ($script:DockerOk) {
        $lblDocker.Text = 'Docker: running'
        $lblDocker.ForeColor = $ColOk
    } else {
        $lblDocker.Text = 'Docker: NOT running'
        $lblDocker.ForeColor = $ColErr
        $lblServices.Text = 'Services: -'
        $lblWeb.Text = 'Web UI: -'
        $lblWeb.ForeColor = $ColMuted
        [System.Windows.Forms.Application]::DoEvents()
        return
    }

    $svc = Get-RunningServices
    $healthy = Test-OtsHealthy
    $lblServices.Text = "Services: $($svc.Count) running" + $(if ($healthy) { ', server healthy' } else { '' })
    $lblServices.ForeColor = if ($healthy) { $ColMuted } elseif ($svc.Count -gt 0) { $ColWarn } else { $ColMuted }

    $code = Get-HttpStatus 'https://localhost/'
    if ($code -eq 200) {
        $lblWeb.Text = 'Web UI: reachable'
        $lblWeb.ForeColor = $ColOk
    } else {
        $lblWeb.Text = "Web UI: not responding"
        $lblWeb.ForeColor = if ($svc.Count -gt 0) { $ColWarn } else { $ColMuted }
    }

    # Address and TLS labels are already set at the top of this function, so
    # that they still show when Docker is down. Setting them again here would
    # overwrite the TLS-only suffix.

    if ($IncludeSecurity) {
        if ($code -eq 200 -and (Test-DefaultAdminPassword)) {
            $lblSecurity.Text = 'DEFAULT PASSWORD IN USE'
            $lblSecurity.ForeColor = $ColErr
        } elseif ($code -eq 200) {
            $lblSecurity.Text = 'Admin password: changed'
            $lblSecurity.ForeColor = $ColOk
        } else {
            $lblSecurity.Text = 'Admin password: unknown'
            $lblSecurity.ForeColor = $ColMuted
        }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# ===========================================================================
#  Command runner
# ===========================================================================
$script:Buttons = @()

function Set-ButtonsEnabled {
    param([bool]$Enabled)
    foreach ($b in $script:Buttons) { $b.Enabled = $Enabled }
    $btnRefresh.Enabled = $Enabled
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-OtsCommand {
    <#
        Runs ots.ps1 with the given arguments, streaming output into the
        console, then runs $Verify to confirm the change actually landed.

        $Verify returns a hashtable: @{ Ok = $true/$false; Message = '...' }
    #>
    param(
        [string]$Title,
        [string[]]$CommandArgs,
        [scriptblock]$Verify,
        [hashtable]$EnvVars,
        [switch]$AssumeYes,
        [string]$Script = 'ots.ps1'
    )

    Set-ButtonsEnabled $false
    Clear-Console
    Add-Line "==> $Title" $ColAccent
    Add-Line ('-' * 70) $ColMuted
    Set-Banner "Running: $Title ..." 'busy'

    # Quote every argument for the child PowerShell. Single quotes are literal;
    # embedded single quotes are escaped by doubling.
    $quoted = $CommandArgs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }

    # NOTE: deliberately no '2>&1' here. Docker writes ordinary progress
    # ("Image x Pulling") to stderr, and PowerShell 5.1 wraps redirected native
    # stderr in NativeCommandError records - which, with the script's
    # ErrorActionPreference of 'Stop', aborts it even though the command
    # succeeded. The two streams are captured separately by the events below,
    # so merging them here buys nothing and breaks anything that pulls images.
    $inner  = "& '" + (Join-Path $Root $Script) + "' " + ($quoted -join ' ')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$($inner -replace '"','\"')`""
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # Docker emits UTF-8 (it truncates long commands with a "…"). Without this
    # the default ANSI code page turns those characters into mojibake.
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    if ($AssumeYes) { $psi.EnvironmentVariables['OTS_ASSUME_YES'] = '1' }
    if ($EnvVars) { foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] } }

    $exit = -1
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $subs = @()
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)

        # Output is collected through events into a thread-safe queue, and the
        # UI thread drains it. Reading the stream directly would block between
        # lines and freeze the window during slow steps like image pulls.
        foreach ($evt in @('OutputDataReceived', 'ErrorDataReceived')) {
            $subs += Register-ObjectEvent -InputObject $proc -EventName $evt -MessageData $queue -Action {
                if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue([string]$EventArgs.Data) }
            }
        }
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $line = $null
        while (-not $proc.HasExited) {
            while ($queue.TryDequeue([ref]$line)) { Add-Line $line }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 40
        }

        # Let any events still in flight land, then drain what is left.
        Start-Sleep -Milliseconds 250
        while ($queue.TryDequeue([ref]$line)) { Add-Line $line }
        [System.Windows.Forms.Application]::DoEvents()

        $exit = $proc.ExitCode
    } catch {
        Add-Line "Failed to run the command: $($_.Exception.Message)" $ColErr
    } finally {
        foreach ($s in $subs) {
            Unregister-Event -SubscriptionId $s.Id -ErrorAction SilentlyContinue
            Remove-Job -Id $s.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Add-Line ('-' * 70) $ColMuted

    # ---- verification ------------------------------------------------------
    Add-Line ''
    Add-Line 'Verifying...' $ColAccent
    Start-Sleep -Milliseconds 400

    $result = $null
    if ($Verify) {
        try { $result = & $Verify $exit } catch { $result = @{ Ok = $false; Message = "Check failed: $($_.Exception.Message)" } }
    } else {
        $result = @{ Ok = ($exit -eq 0); Message = if ($exit -eq 0) { 'Command completed.' } else { "Command exited with code $exit." } }
    }

    if ($result.Ok) {
        Add-Line "[ok] $($result.Message)" $ColOk
        Set-Banner "VERIFIED - $($result.Message)" 'ok'
    } else {
        Add-Line "[x] $($result.Message)" $ColErr
        Set-Banner "NOT APPLIED - $($result.Message)" 'fail'
    }

    Update-Status
    Set-ButtonsEnabled $true
    return $result.Ok
}

# ===========================================================================
#  Verification checks
# ===========================================================================
function Wait-ForHealthy {
    param([int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-OtsHealthy) -and (Get-HttpStatus 'https://localhost/') -eq 200) { return $true }
        Start-Sleep -Seconds 3
        [System.Windows.Forms.Application]::DoEvents()
    }
    return $false
}

$VerifyRunning = {
    param($exit)
    Add-Line '  waiting for the server to report healthy...' $ColMuted
    if (Wait-ForHealthy -TimeoutSec 240) {
        @{ Ok = $true; Message = 'Server is running and the web UI responds.' }
    } else {
        @{ Ok = $false; Message = 'Server did not become healthy. Check the log above, or use View Logs.' }
    }
}

$VerifyStopped = {
    param($exit)
    $svc = Get-RunningServices
    if ($svc.Count -eq 0) { @{ Ok = $true; Message = 'All containers stopped. Data is preserved.' } }
    else { @{ Ok = $false; Message = "Still running: $($svc -join ', ')" } }
}

$VerifyPasswordChanged = {
    param($exit)
    if ($exit -ne 0) { return @{ Ok = $false; Message = 'The command reported an error - password unchanged.' } }
    if (Test-DefaultAdminPassword) { @{ Ok = $false; Message = 'The default password still works - change did NOT apply.' } }
    else { @{ Ok = $true; Message = 'Password changed. The default no longer works.' } }
}

$VerifyBackup = {
    param($exit)
    $dir = Join-Path $Root 'backups'
    if (-not (Test-Path $dir)) { return @{ Ok = $false; Message = 'No backups folder was created.' } }
    $newest = Get-ChildItem $dir -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { return @{ Ok = $false; Message = 'No backup folder was created.' } }
    $sql = Join-Path $newest.FullName 'database.sql'
    $tar = Join-Path $newest.FullName 'ots_data.tar.gz'
    if ((Test-Path $sql) -and (Test-Path $tar) -and
        (Get-Item $sql).Length -gt 0 -and (Get-Item $tar).Length -gt 0) {
        $mb = [math]::Round(((Get-Item $sql).Length + (Get-Item $tar).Length) / 1MB, 1)
        @{ Ok = $true; Message = "Backup written to backups\$($newest.Name) ($mb MB)." }
    } else {
        @{ Ok = $false; Message = 'Backup folder is missing the database dump or the data archive.' }
    }
}

$VerifyCaExport = {
    param($exit)
    $p = Join-Path $Root 'ca.pem'
    if (-not (Test-Path $p)) { return @{ Ok = $false; Message = 'ca.pem was not created.' } }
    $txt = Get-Content $p -Raw
    if ($txt -match 'BEGIN CERTIFICATE') { @{ Ok = $true; Message = 'ca.pem exported and looks like a valid certificate.' } }
    else { @{ Ok = $false; Message = 'ca.pem exists but does not contain a certificate.' } }
}

$VerifyDoctor = {
    param($exit)
    if ($exit -eq 0) { @{ Ok = $true; Message = 'Checks finished - read the output above for any warnings.' } }
    else { @{ Ok = $false; Message = 'Problems were reported - see the output above.' } }
}

$VerifyReset = {
    param($exit)
    $vols = & docker volume ls --format '{{.Name}}' 2>$null | Where-Object { $_ -like 'opentakserver_*' }
    if (-not $vols) { @{ Ok = $true; Message = 'All data volumes removed. Run Setup to start fresh.' } }
    else { @{ Ok = $false; Message = "Volumes still present: $($vols -join ', ')" } }
}

$VerifyGoPublic = {
    param($exit)
    if ($exit -ne 0) { return @{ Ok = $false; Message = 'Setup did not complete - see the output above.' } }
    $sub = Get-EnvValue 'DUCKDNS_SUBDOMAIN'
    $tls = Get-EnvValue 'OTS_TLS_MODE'
    $running = & docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -eq 'ots-duckdns' }
    if ($sub -and $tls -eq 'letsencrypt' -and $running) {
        @{ Ok = $true; Message = "Configured for $sub.duckdns.org. Next: forward ports, then Request Certificate." }
    } elseif (-not $running) {
        @{ Ok = $false; Message = 'The dynamic DNS container is not running.' }
    } else {
        @{ Ok = $false; Message = 'Configuration was not fully written to .env.' }
    }
}

$VerifyCert = {
    param($exit)
    if ($exit -ne 0) { return @{ Ok = $false; Message = 'Certificate request failed - most often port 80 is not reachable from the internet.' } }
    $fqdn = Get-EnvValue 'OTS_FQDN'
    $out = & docker compose run --rm --entrypoint sh certbot -c "cat /etc/letsencrypt/live/$fqdn/fullchain.pem 2>/dev/null | head -1" 2>$null
    if ($out -match 'BEGIN CERTIFICATE') { @{ Ok = $true; Message = "Certificate installed for $fqdn and nginx reloaded." } }
    else { @{ Ok = $false; Message = "No certificate found for $fqdn." } }
}

# ===========================================================================
#  Port-forwarding prompt builder
# ===========================================================================
function Get-GatewayAddress {
    try {
        $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        return $cfg.IPv4DefaultGateway.NextHop
    } catch { return $null }
}

function Get-LanAddressGui {
    try {
        $cfg = Get-NetIPConfiguration |
               Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
               Select-Object -First 1
        if ($cfg -and $cfg.IPv4Address) { return $cfg.IPv4Address.IPAddress }
    } catch { }
    return '192.168.1.x'
}

function Get-ForwardPortTable {
    <#  Built from .env, so the list matches what this install actually
        publishes even if the ports were changed. #>
    param([switch]$IncludeOptional)

    $rows = @(
        @{ Port = (Get-EnvValue 'OTS_HTTP_PORT' '80');             Proto = 'TCP'; Why = 'Certificate issue AND renewal (Let''s Encrypt). Required.' }
        @{ Port = (Get-EnvValue 'OTS_HTTPS_PORT' '443');           Proto = 'TCP'; Why = 'Web interface' }
        @{ Port = (Get-EnvValue 'OTS_MARTI_HTTPS_PORT' '8443');    Proto = 'TCP'; Why = 'TAK API (client certificate required)' }
        @{ Port = (Get-EnvValue 'OTS_CERT_ENROLLMENT_PORT' '8446');Proto = 'TCP'; Why = 'TAK client certificate enrollment' }
        @{ Port = (Get-EnvValue 'OTS_SSL_COT_PORT' '8089');        Proto = 'TCP'; Why = 'Encrypted position/message streaming - what TAK clients use' }
    )

    if ($IncludeOptional) {
        $rows += @(
            @{ Port = (Get-EnvValue 'OTS_MQTT_PORT' '8883');       Proto = 'TCP'; Why = 'MQTT over TLS (Meshtastic)' }
            @{ Port = (Get-EnvValue 'OTS_MARTI_HTTP_PORT' '8080'); Proto = 'TCP'; Why = 'TAK API over plain HTTP - UNENCRYPTED' }
            @{ Port = (Get-EnvValue 'OTS_TCP_COT_PORT' '8088');    Proto = 'TCP'; Why = 'Streaming without encryption - UNENCRYPTED' }
            @{ Port = (Get-EnvValue 'VIDEO_RTMP_PORT' '1935');     Proto = 'TCP'; Why = 'Video (RTMP)' }
            @{ Port = (Get-EnvValue 'VIDEO_RTMPS_PORT' '1936');    Proto = 'TCP'; Why = 'Video (RTMPS)' }
            @{ Port = (Get-EnvValue 'VIDEO_RTSPS_PORT' '8322');    Proto = 'TCP'; Why = 'Video (RTSPS)' }
            @{ Port = (Get-EnvValue 'VIDEO_RTSP_PORT' '8554');     Proto = 'TCP'; Why = 'Video (RTSP)' }
            @{ Port = (Get-EnvValue 'VIDEO_HLS_PORT' '8888');      Proto = 'TCP'; Why = 'Video (HLS)' }
            @{ Port = (Get-EnvValue 'VIDEO_WEBRTC_PORT' '8889');   Proto = 'TCP'; Why = 'Video (WebRTC)' }
            @{ Port = (Get-EnvValue 'VIDEO_RTP_PORT' '8000');      Proto = 'UDP'; Why = 'Video (RTP) - media for plain RTSP' }
            @{ Port = (Get-EnvValue 'VIDEO_RTCP_PORT' '8001');     Proto = 'UDP'; Why = 'Video (RTCP) - media for plain RTSP' }
            @{ Port = (Get-EnvValue 'VIDEO_SRTP_PORT' '8004');     Proto = 'UDP'; Why = 'Video (SRTP) - media for encrypted RTSPS' }
            @{ Port = (Get-EnvValue 'VIDEO_SRTCP_PORT' '8005');    Proto = 'UDP'; Why = 'Video (SRTCP) - media for encrypted RTSPS' }
            @{ Port = (Get-EnvValue 'VIDEO_WEBRTC_UDP_PORT' '8189');Proto = 'UDP'; Why = 'Video (WebRTC media)' }
            @{ Port = (Get-EnvValue 'VIDEO_SRT_PORT' '8890');      Proto = 'UDP'; Why = 'Video (SRT)' }
        )
    }
    return $rows
}

function New-PortForwardPrompt {
    param(
        [string]$Router, [string]$Isp, [string]$Notes,
        [string]$Lan, [string]$Gateway, [switch]$IncludeOptional
    )

    $rows = Get-ForwardPortTable -IncludeOptional:$IncludeOptional
    $table = ($rows | ForEach-Object { "| {0,-5} | {1,-3} | {2} |" -f $_.Port, $_.Proto, $_.Why }) -join "`r`n"

    $routerLine  = if ($Router) { $Router } else { "I don't know - please help me identify it" }
    $ispLine     = if ($Isp)    { $Isp }    else { 'not sure' }
    $notesBlock  = if ($Notes)  { "`r`n## Anything else you should know`r`n$Notes`r`n" } else { '' }

    return @"
I need step-by-step help setting up port forwarding on my home router.

## My setup

- Router make and model: $routerLine
- Internet provider: $ispLine
- Router admin page: http://$Gateway
- The PC running the server: $Lan (Windows, on my home network)
- What I'm running: OpenTAKServer, a TAK server, in Docker. It's already
  working on my local network - I just need it reachable from the internet.

## Ports I need forwarded to $Lan

| Port  | Proto | What it's for |
|-------|-----|----------------------------------------------------|
$table

## What I'd like from you

1. Step-by-step instructions for **my specific router model**, naming the exact
   menu names and buttons I'll see. If you're not sure of the layout for my
   model, say so and give me the closest equivalent, or tell me what to look
   for rather than guessing.
2. How to give this PC a **DHCP reservation / static lease** so $Lan doesn't
   change and break every rule I just made.
3. How to tell whether my ISP puts me behind **CGNAT** - and what my options
   are if it does, since port forwarding can't work in that case.
4. Some ISPs block inbound **port 80**. How do I check, and what are my options
   if it's blocked? (I need port 80 specifically for Let's Encrypt certificate
   validation and renewal.)
5. A brief note on the **security implications** of opening these ports, and
   anything you'd suggest doing to reduce the risk.
$notesBlock
Please ask me for anything you need - I can read settings off the router and
report back. Go one step at a time rather than giving me everything at once.
"@
}

function Show-TlsPolicyDialog {
    <#  Returns 'on', 'all', 'off' - or $null if cancelled. #>
    $takClosed   = (Get-EnvValue 'OTS_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'
    $videoClosed = (Get-EnvValue 'OTS_VIDEO_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'
    $current = if (-not $takClosed) { 'off' } elseif ($videoClosed) { 'all' } else { 'on' }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Encryption policy'
    # Tall enough that Apply/Cancel clear the third option's description -
    # the title bar and border eat into the client area.
    $dlg.Size = New-Object System.Drawing.Size(660, 490)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $ColBg; $dlg.ForeColor = $ColText; $dlg.Font = $FontUi

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = "Every encrypted port already has a certificate. Some services also run an" + [Environment]::NewLine +
                  "unencrypted copy next to the encrypted one - this chooses which of those stay" + [Environment]::NewLine +
                  "reachable from the network."
    $intro.Location = New-Object System.Drawing.Point(18, 14)
    $intro.Size = New-Object System.Drawing.Size(610, 58)
    $intro.ForeColor = $ColMuted
    $dlg.Controls.Add($intro)

    $opts = @(
        @{ Mode = 'on';  Title = 'TAK encrypted, video either way   (recommended)';
           Body = "Closes 8080 (plain Marti API) and 8088 (unencrypted CoT).`r`nLeaves plain RTSP/RTMP running alongside RTSPS/RTMPS, so cameras`r`nand encoders that only speak plain video keep working." }
        @{ Mode = 'all'; Title = 'Everything encrypted';
           Body = "Also closes plain RTSP, RTMP, HLS and WebRTC. MediaMTX refuses`r`nunencrypted connections entirely. Anything that cannot do RTSPS`r`nor RTMPS will stop working." }
        @{ Mode = 'off'; Title = 'Allow all unencrypted ports';
           Body = "Everything open, encrypted and unencrypted alike. Simplest to get`r`nworking, and the weakest - avoid it on an internet-facing server." }
    )

    $y = 84
    $radios = @()
    foreach ($o in $opts) {
        $r = New-Object System.Windows.Forms.RadioButton
        $r.Text = $o.Title
        $r.Tag = $o.Mode
        $r.Location = New-Object System.Drawing.Point(22, $y)
        $r.Size = New-Object System.Drawing.Size(600, 24)
        $r.Font = $FontBold
        $r.Checked = ($o.Mode -eq $current)
        $dlg.Controls.Add($r)
        $radios += $r

        $b = New-Object System.Windows.Forms.Label
        $b.Text = $o.Body
        $b.Location = New-Object System.Drawing.Point(44, ($y + 24))
        $b.Size = New-Object System.Drawing.Size(590, 56)
        $b.ForeColor = $ColMuted
        $dlg.Controls.Add($b)

        $y += 96
    }

    $cur = New-Object System.Windows.Forms.Label
    $cur.Text = "Currently: $current"
    $cur.Location = New-Object System.Drawing.Point(22, ($y + 2))
    $cur.Size = New-Object System.Drawing.Size(300, 22)
    $cur.ForeColor = $ColAccent
    $dlg.Controls.Add($cur)

    $script:TlsChoice = $null

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Apply'; $ok.Size = New-Object System.Drawing.Size(110, 32)
    $ok.Location = New-Object System.Drawing.Point(410, $y)
    $ok.FlatStyle = 'Flat'; $ok.BackColor = $ColPanel; $ok.ForeColor = $ColText
    $ok.Add_Click({
        foreach ($r in $radios) { if ($r.Checked) { $script:TlsChoice = [string]$r.Tag } }
        $dlg.Close()
    })
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(90, 32)
    $cancel.Location = New-Object System.Drawing.Point(528, $y)
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = $ColPanel; $cancel.ForeColor = $ColText
    $cancel.Add_Click({ $script:TlsChoice = $null; $dlg.Close() })
    $dlg.Controls.Add($cancel)
    $dlg.CancelButton = $cancel

    [void]$dlg.ShowDialog()
    return $script:TlsChoice
}

function Show-PortForwardHelper {
    $lan     = Get-EnvValue 'OTS_FQDN'
    if (-not $lan -or $lan -eq '_' -or $lan -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        $lan = (Get-LanAddressGui)
    }
    $gateway = Get-GatewayAddress
    if (-not $gateway) { $gateway = '192.168.1.1' }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Port forwarding - build a prompt for an AI assistant'
    $dlg.Size = New-Object System.Drawing.Size(880, 720)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $ColBg
    $dlg.ForeColor = $ColText
    $dlg.Font = $FontUi

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = "Every router's menus are different, so this builds a prompt describing your exact" + [Environment]::NewLine +
                  "setup. Paste it into Claude or ChatGPT and it will walk you through your router." + [Environment]::NewLine +
                  "Nothing is sent anywhere by this window - you copy and paste it yourself."
    $intro.Location = New-Object System.Drawing.Point(16, 12)
    $intro.Size = New-Object System.Drawing.Size(830, 58)
    $intro.ForeColor = $ColMuted
    $dlg.Controls.Add($intro)

    function New-Field {
        param([string]$Label, [int]$Y, [string]$Value = '', [string]$Hint = '')
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Label
        $l.Location = New-Object System.Drawing.Point(16, ($Y + 4))
        $l.Size = New-Object System.Drawing.Size(150, 22)
        $dlg.Controls.Add($l)

        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(170, $Y)
        $t.Size = New-Object System.Drawing.Size(420, 24)
        $t.BackColor = $ColPanel
        $t.ForeColor = $ColText
        $t.BorderStyle = 'FixedSingle'
        $t.Text = $Value
        $dlg.Controls.Add($t)

        if ($Hint) {
            $h = New-Object System.Windows.Forms.Label
            $h.Text = $Hint
            $h.Location = New-Object System.Drawing.Point(600, ($Y + 4))
            $h.Size = New-Object System.Drawing.Size(250, 22)
            $h.ForeColor = $ColMuted
            $dlg.Controls.Add($h)
        }
        return $t
    }

    $txtRouter = New-Field 'Router make/model' 82  '' 'e.g. "Netgear R7000" or "ISP box"'
    $txtIsp    = New-Field 'Internet provider' 116 '' 'e.g. Xfinity, Spectrum, BT'
    $txtLan    = New-Field 'This PC''s address' 150 $lan 'detected'
    $txtGw     = New-Field 'Router address'    184 $gateway 'detected'

    $lblNotes = New-Object System.Windows.Forms.Label
    $lblNotes.Text = 'Anything else'
    $lblNotes.Location = New-Object System.Drawing.Point(16, 222)
    $lblNotes.Size = New-Object System.Drawing.Size(150, 22)
    $dlg.Controls.Add($lblNotes)

    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location = New-Object System.Drawing.Point(170, 218)
    $txtNotes.Size = New-Object System.Drawing.Size(420, 48)
    $txtNotes.Multiline = $true
    $txtNotes.BackColor = $ColPanel
    $txtNotes.ForeColor = $ColText
    $txtNotes.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($txtNotes)

    $chkAll = New-Object System.Windows.Forms.CheckBox
    $chkAll.Text = 'Include the optional ports too (video, MQTT, and the two unencrypted ones)'
    $chkAll.Location = New-Object System.Drawing.Point(170, 274)
    $chkAll.Size = New-Object System.Drawing.Size(560, 24)
    $chkAll.ForeColor = $ColMuted
    # Default to the smallest set that gives full TAK functionality. The
    # optional ports include two unencrypted ones, so opting in is deliberate.
    $chkAll.Checked = $false
    $dlg.Controls.Add($chkAll)

    $txtPrompt = New-Object System.Windows.Forms.TextBox
    $txtPrompt.Location = New-Object System.Drawing.Point(16, 310)
    $txtPrompt.Size = New-Object System.Drawing.Size(830, 310)
    $txtPrompt.Multiline = $true
    $txtPrompt.ScrollBars = 'Vertical'
    $txtPrompt.Font = $FontMono
    $txtPrompt.BackColor = [System.Drawing.Color]::FromArgb(16, 18, 21)
    $txtPrompt.ForeColor = $ColText
    $txtPrompt.BorderStyle = 'FixedSingle'
    $txtPrompt.Anchor = 'Top,Left,Right,Bottom'
    $dlg.Controls.Add($txtPrompt)

    $refresh = {
        $text = New-PortForwardPrompt -Router $txtRouter.Text -Isp $txtIsp.Text `
            -Notes $txtNotes.Text -Lan $txtLan.Text -Gateway $txtGw.Text `
            -IncludeOptional:$chkAll.Checked
        # This file is stored with LF endings, so the here-string produces LF.
        # A multiline TextBox only breaks on CRLF - without this the whole
        # prompt renders as one unreadable paragraph.
        $txtPrompt.Text = $text -replace "`r?`n", "`r`n"
    }
    foreach ($c in @($txtRouter, $txtIsp, $txtLan, $txtGw, $txtNotes)) { $c.Add_TextChanged($refresh) }
    $chkAll.Add_CheckedChanged($refresh)
    & $refresh

    function New-DlgButton {
        param([string]$Text, [int]$X, [int]$W, [scriptblock]$OnClick)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.Location = New-Object System.Drawing.Point($X, 634)
        $b.Size = New-Object System.Drawing.Size($W, 34)
        $b.Anchor = 'Bottom,Left'
        $b.FlatStyle = 'Flat'
        $b.BackColor = $ColPanel
        $b.ForeColor = $ColText
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(58, 62, 70)
        $b.Add_Click($OnClick)
        $dlg.Controls.Add($b)
        return $b
    }

    $lblCopied = New-Object System.Windows.Forms.Label
    $lblCopied.Location = New-Object System.Drawing.Point(596, 642)
    $lblCopied.Size = New-Object System.Drawing.Size(250, 22)
    $lblCopied.ForeColor = $ColOk
    $lblCopied.Anchor = 'Bottom,Left'
    $dlg.Controls.Add($lblCopied)

    [void](New-DlgButton 'Copy prompt' 16 130 {
        try {
            [System.Windows.Forms.Clipboard]::SetText($txtPrompt.Text)
            $lblCopied.Text = 'Copied - now paste it into Claude.'
        } catch { $lblCopied.ForeColor = $ColErr; $lblCopied.Text = 'Could not copy.' }
    })

    [void](New-DlgButton 'Copy + open Claude' 154 160 {
        try { [System.Windows.Forms.Clipboard]::SetText($txtPrompt.Text) } catch { }
        # Opened without the prompt in the URL on purpose: query strings get
        # logged and shared, and this text describes your home network.
        Start-Process 'https://claude.ai/new'
        $lblCopied.Text = 'Copied - paste it into the chat.'
    })

    [void](New-DlgButton 'Copy + open ChatGPT' 322 170 {
        try { [System.Windows.Forms.Clipboard]::SetText($txtPrompt.Text) } catch { }
        Start-Process 'https://chatgpt.com/'
        $lblCopied.Text = 'Copied - paste it into the chat.'
    })

    [void](New-DlgButton 'Save as file' 500 90 {
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = 'Text file (*.txt)|*.txt'
        $sfd.FileName = 'port-forwarding-prompt.txt'
        if ($sfd.ShowDialog() -eq 'OK') {
            [System.IO.File]::WriteAllText($sfd.FileName, $txtPrompt.Text)
            $lblCopied.Text = 'Saved.'
        }
    })

    $close = New-DlgButton 'Close' 756 90 { $dlg.Close() }
    $dlg.CancelButton = $close

    [void]$dlg.ShowDialog()
}

# ===========================================================================
#  Buttons
# ===========================================================================
function Add-SectionLabel {
    param([string]$Text)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text.ToUpper()
    $l.ForeColor = $ColMuted
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    $l.Size = New-Object System.Drawing.Size(220, 20)
    $l.Margin = New-Object System.Windows.Forms.Padding(2, 12, 2, 2)
    $l.TextAlign = 'BottomLeft'
    $side.Controls.Add($l)
}

function Add-ActionButton {
    param([string]$Text, [scriptblock]$OnClick, [string]$Tip, [switch]$Danger)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size(220, 32)
    $b.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 3)
    $b.FlatStyle = 'Flat'
    $b.TextAlign = 'MiddleLeft'
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $b.BackColor = if ($Danger) { [System.Drawing.Color]::FromArgb(58, 32, 32) } else { $ColPanel }
    $b.ForeColor = if ($Danger) { $ColErr } else { $ColText }
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(58, 62, 70)
    $b.Add_Click($OnClick)
    if ($Tip) {
        $tt = New-Object System.Windows.Forms.ToolTip
        $tt.SetToolTip($b, $Tip)
    }
    $side.Controls.Add($b)
    $script:Buttons += $b
}

# ---- First-time setup ------------------------------------------------------
Add-SectionLabel 'Setup'

Add-ActionButton '0. Check This PC' {
    Invoke-OtsCommand -Title 'Check prerequisites' -CommandArgs @('preflight') -Verify {
        param($exit)
        if ($exit -eq 0) { @{ Ok = $true; Message = 'This PC can run OpenTAKServer. Continue with step 1.' } }
        else { @{ Ok = $false; Message = 'Something must be fixed first - see the output above.' } }
    } | Out-Null
} 'Checks Windows version, virtualization, WSL, memory and disk'

Add-ActionButton '1. Install Docker Desktop' {
    # Virtualization cannot be enabled by any installer - it is a firmware
    # setting. Check before spending a long download on a machine that
    # cannot run Docker at all.
    if (-not (Test-VirtualizationOk)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Hardware virtualization appears to be turned off in this PC's BIOS/UEFI.`n`nDocker cannot run without it, and no software can switch it on. Reboot into your BIOS setup and enable the option called 'Intel VT-x', 'AMD-V', 'SVM Mode' or 'Virtualization Technology'.`n`nPress '0. Check This PC' for the full report.",
            'Virtualization is disabled', 'OK', 'Warning') | Out-Null
        Set-Banner 'Blocked: hardware virtualization is disabled in BIOS/UEFI.' 'fail'
        return
    }

    if (Test-DockerInstalled) {
        Clear-Console
        Add-Line '==> Docker check' $ColAccent
        Add-Line ''
        Add-Line "[ok] Docker Desktop is already installed." $ColOk
        $exe = Find-DockerDesktop
        if ($exe) { Add-Line "     $exe" $ColMuted }
        Set-Banner 'VERIFIED - Docker is already installed. Go to step 2.' 'ok'
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show(
            "winget is not available on this machine, so Docker cannot be installed automatically.`n`nDownload Docker Desktop manually from docker.com, install it, then come back and press step 2.",
            'Install manually', 'OK', 'Information') | Out-Null
        Start-Process 'https://www.docker.com/products/docker-desktop/'
        Set-Banner 'Opened the Docker download page in your browser.' 'warn'
        return
    }

    $msg = @"
This will install Docker Desktop on this computer.

  - It is downloaded by winget from Microsoft's package repository.
  - Docker Desktop is made by Docker, Inc. and has its own licence terms.
    Larger businesses may require a paid subscription.
  - Continuing accepts the winget package agreements on your behalf.
  - Windows will ask for administrator permission.
  - A restart may be required before Docker will run.

Install Docker Desktop now?
"@
    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Install Docker Desktop', 'YesNo', 'Question', 'Button2')
    if ($r -ne 'Yes') { Set-Banner 'Cancelled - nothing was installed.' 'idle'; return }

    Set-ButtonsEnabled $false
    Clear-Console
    Add-Line '==> Installing Docker Desktop' $ColAccent
    Add-Line 'This downloads several hundred MB and can take a while.' $ColMuted
    Add-Line ''
    Set-Banner 'Installing Docker Desktop...' 'busy'
    try {
        $p = Start-Process winget.exe -PassThru -Wait -ArgumentList @(
            'install', '-e', '--id', 'Docker.DockerDesktop',
            '--accept-package-agreements', '--accept-source-agreements')
        Add-Line "winget finished with exit code $($p.ExitCode)"
    } catch {
        Add-Line "Install failed: $($_.Exception.Message)" $ColErr
    }

    Add-Line ''
    Add-Line 'Verifying...' $ColAccent
    if (Test-DockerInstalled) {
        Add-Line '[ok] Docker Desktop is now installed.' $ColOk
        Add-Line ''
        Add-Line 'Next: press "2. Start Docker Desktop".' $ColMuted
        Add-Line 'If it will not start, restart Windows first - Docker needs WSL 2,' $ColMuted
        Add-Line 'which usually requires a reboot after installation.' $ColMuted
        Set-Banner 'VERIFIED - Docker Desktop installed. Now press step 2.' 'ok'
    } else {
        Add-Line '[x] Docker still is not detected.' $ColErr
        Set-Banner 'NOT APPLIED - Docker was not installed. You may need to restart Windows.' 'fail'
    }
    Set-ButtonsEnabled $true
} 'Installs Docker Desktop using winget'

Add-ActionButton '2. Start Docker Desktop' {
    Set-ButtonsEnabled $false
    Clear-Console
    Add-Line '==> Starting Docker' $ColAccent
    Add-Line ''

    if (Test-DockerUp) {
        Add-Line '[ok] The Docker engine is already running.' $ColOk
        Set-Banner 'VERIFIED - Docker is running. Go to step 3.' 'ok'
        Update-Status
        Set-ButtonsEnabled $true
        return
    }

    $exe = Find-DockerDesktop
    if (-not $exe) {
        Add-Line '[x] Docker Desktop is not installed - do step 1 first.' $ColErr
        Set-Banner 'NOT APPLIED - Docker Desktop is not installed.' 'fail'
        Set-ButtonsEnabled $true
        return
    }

    Add-Line "Launching $exe" $ColMuted
    Add-Line 'Waiting for the engine to come up (up to 3 minutes)...' $ColMuted
    Set-Banner 'Starting Docker Desktop...' 'busy'
    try { Start-Process $exe | Out-Null } catch { Add-Line "Could not launch: $($_.Exception.Message)" $ColErr }

    if (Wait-ForDockerEngine -TimeoutSec 180) {
        Add-Line '[ok] The Docker engine is running.' $ColOk
        Set-Banner 'VERIFIED - Docker is running. Now press step 3.' 'ok'
    } else {
        Add-Line '[x] Docker did not come up within 3 minutes.' $ColErr
        Add-Line '    Open Docker Desktop yourself and complete any first-run prompts,' $ColMuted
        Add-Line '    then press this button again.' $ColMuted
        Set-Banner 'NOT APPLIED - the Docker engine is not responding yet.' 'fail'
    }
    Update-Status
    Set-ButtonsEnabled $true
} 'Launches Docker Desktop and waits for the engine'

Add-ActionButton '3. Build and Install Server' {
    if (-not (Test-DockerUp)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Docker is not running. Do steps 1 and 2 first.', 'Docker required', 'OK', 'Warning') | Out-Null
        Set-Banner 'Blocked: Docker is not running.' 'fail'
        return
    }

    if (Test-SetupComplete) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "This installation is already set up.`n`nRunning setup again will download any missing images, rebuild the web server image and start everything. Your existing configuration and data are left alone.`n`nContinue?",
            'Already set up', 'YesNo', 'Question')
        if ($r -ne 'Yes') { Set-Banner 'Cancelled.' 'idle'; return }
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "First-time setup will:`n`n  - generate secure random passwords`n  - detect this machine's network address`n  - download about 3 GB of container images`n  - build the web server image`n  - start OpenTAKServer`n`nThe first run takes several minutes.",
            'First-time setup', 'OK', 'Information') | Out-Null
    }

    Invoke-OtsCommand -Script 'setup.ps1' -Title 'Build and install OpenTAKServer' `
        -CommandArgs @() -Verify {
        param($exit)
        if (-not (Test-SetupComplete)) { return @{ Ok = $false; Message = 'Setup did not create a .env file.' } }
        Add-Line '  waiting for the server to report healthy...' $ColMuted
        if (Wait-ForHealthy -TimeoutSec 300) {
            @{ Ok = $true; Message = 'Installed and running. Open the web UI and change the admin password.' }
        } else {
            @{ Ok = $false; Message = 'Installed, but the server has not become healthy yet - check View Logs.' }
        }
    } | Out-Null
} 'Downloads images, builds and starts everything'

Add-ActionButton '4. Port Forwarding Help' {
    Show-PortForwardHelper
    Set-Banner 'Prompt builder closed. Forward the ports, then use "Check Internet Setup".' 'idle'
} 'Builds a prompt describing your router and ports for Claude or ChatGPT'

# ---- Server ---------------------------------------------------------------
Add-SectionLabel 'Server'

Add-ActionButton 'Start' {
    Invoke-OtsCommand -Title 'Start the server' -CommandArgs @('start') -Verify $VerifyRunning | Out-Null
} 'Start all containers'

Add-ActionButton 'Stop' {
    Invoke-OtsCommand -Title 'Stop the server' -CommandArgs @('stop') -Verify $VerifyStopped | Out-Null
} 'Stop all containers. Data is kept.'

Add-ActionButton 'Restart / apply .env' {
    Invoke-OtsCommand -Title 'Restart and apply configuration' -CommandArgs @('restart') -Verify $VerifyRunning | Out-Null
} 'Recreates containers so .env changes take effect, then restarts'

Add-ActionButton 'Status' {
    Invoke-OtsCommand -Title 'Container status' -CommandArgs @('status') -Verify {
        param($exit)
        $svc = Get-RunningServices
        if ($svc.Count -gt 0) { @{ Ok = $true; Message = "$($svc.Count) service(s) running." } }
        else { @{ Ok = $false; Message = 'Nothing is running. Press Start.' } }
    } | Out-Null
} 'Show what is running'

Add-ActionButton 'View Logs' {
    Set-ButtonsEnabled $false
    Clear-Console
    Add-Line '==> Recent logs (last 300 lines)' $ColAccent
    Add-Line ('-' * 70) $ColMuted
    Set-Banner 'Fetching logs...' 'busy'
    $out = & docker compose logs --tail 300 --no-color 2>&1
    foreach ($l in $out) { Add-Line ([string]$l) }
    Set-Banner 'Logs shown above.' 'idle'
    Set-ButtonsEnabled $true
} 'Show recent output from every container'

# ---- Maintenance -----------------------------------------------------------
Add-SectionLabel 'Maintenance'

Add-ActionButton 'Backup Now' {
    Invoke-OtsCommand -Title 'Back up database and server data' -CommandArgs @('backup') -Verify $VerifyBackup | Out-Null
} 'Writes a timestamped backup into the backups folder'

Add-ActionButton 'Update' {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Pull newer images and restart?`n`nTake a backup first if you have data you care about.",
        'Update', 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        Invoke-OtsCommand -Title 'Update to the newest images' -CommandArgs @('update') -Verify $VerifyRunning | Out-Null
    }
} 'Pull newer container images and restart'

Add-ActionButton 'Edit .env' {
    $p = Join-Path $Root '.env'
    if (-not (Test-Path $p)) {
        [System.Windows.Forms.MessageBox]::Show('No .env yet. Run Setup first.', 'Not found', 'OK', 'Warning') | Out-Null
        return
    }
    Start-Process notepad.exe -ArgumentList $p -Wait
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Apply the changes now?`n`nThis recreates containers so the new values take effect.",
        'Apply changes', 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        Invoke-OtsCommand -Title 'Apply .env changes' -CommandArgs @('restart') -Verify $VerifyRunning | Out-Null
    } else {
        Set-Banner 'Saved, but not applied yet. Use "Restart / apply .env" when ready.' 'warn'
    }
} 'Edit ports, passwords and versions, then apply'

Add-ActionButton 'Edit config.yml' {
    Invoke-OtsCommand -Title "Edit OpenTAKServer's config.yml" -CommandArgs @('config') `
        -AssumeYes -Verify $VerifyRunning | Out-Null
} "Opens the server's own settings file in Notepad, then restarts"

# ---- Internet --------------------------------------------------------------
Add-SectionLabel 'Internet access'

Add-ActionButton 'Use Tailscale (no ports)' {
    $ts = @("$env:ProgramFiles\Tailscale\tailscale.exe",
            "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe") |
          Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $ts) {
        $msg = @"
Tailscale is not installed.

It creates a private encrypted network between your devices, so this server
becomes reachable from your phone or tablet anywhere - with no port
forwarding and no router changes at all. It works behind CGNAT, which
ordinary port forwarding cannot.

The catch: every device that connects must also run Tailscale and be signed
in to the same account. The server is NOT public - only your own devices
reach it.

Free for personal use (up to 100 devices).

Install it now with winget? Windows will ask for permission.
"@
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Install Tailscale', 'YesNo', 'Question')
        if ($r -ne 'Yes') { Set-Banner 'Cancelled - nothing was installed.' 'idle'; return }

        Set-ButtonsEnabled $false
        Clear-Console
        Add-Line '==> Installing Tailscale' $ColAccent
        Set-Banner 'Installing Tailscale...' 'busy'
        try {
            $p = Start-Process winget.exe -PassThru -Wait -ArgumentList @(
                'install', '-e', '--id', 'Tailscale.Tailscale',
                '--accept-package-agreements', '--accept-source-agreements')
            Add-Line "winget finished with exit code $($p.ExitCode)"
        } catch { Add-Line "Install failed: $($_.Exception.Message)" $ColErr }

        $ts = @("$env:ProgramFiles\Tailscale\tailscale.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($ts) {
            Add-Line ''
            Add-Line '[ok] Tailscale installed.' $ColOk
            Add-Line '     Now open Tailscale from the system tray and sign in,' $ColMuted
            Add-Line '     then press this button again.' $ColMuted
            Set-Banner 'VERIFIED - installed. Sign in to Tailscale, then press this again.' 'ok'
        } else {
            Add-Line '[x] Tailscale still not detected.' $ColErr
            Set-Banner 'NOT APPLIED - Tailscale was not installed.' 'fail'
        }
        Set-ButtonsEnabled $true
        return
    }

    Invoke-OtsCommand -Title 'Point the server at its Tailscale address' `
        -CommandArgs @('tailscale', 'on') -Verify {
        param($exit)
        if ($exit -ne 0) { return @{ Ok = $false; Message = 'Not reachable over Tailscale yet - see the output above.' } }
        $fqdn = Get-EnvValue 'OTS_FQDN'
        @{ Ok = $true; Message = "Reachable at $fqdn over Tailscale - no port forwarding needed." }
    } | Out-Null
} 'Private mesh VPN - works behind CGNAT, no router changes'

Add-ActionButton 'Set Up Internet Access' {
    if (Test-DefaultAdminPassword) {
        [System.Windows.Forms.MessageBox]::Show(
            "The administrator account still uses the default password.`n`nChange it before exposing this server to the internet - use 'Change Admin Password' first.",
            'Change the password first', 'OK', 'Error') | Out-Null
        Set-Banner 'Blocked: change the admin password before going public.' 'fail'
        return
    }

    $sub   = [Microsoft.VisualBasic.Interaction]::InputBox("DuckDNS subdomain (just the name, without .duckdns.org).`n`nCreate one free at duckdns.org.", 'DuckDNS subdomain', (Get-EnvValue 'DUCKDNS_SUBDOMAIN'))
    if (-not $sub) { Set-Banner 'Cancelled.' 'idle'; return }
    $token = [Microsoft.VisualBasic.Interaction]::InputBox('DuckDNS token (shown at the top of duckdns.org)', 'DuckDNS token', (Get-EnvValue 'DUCKDNS_TOKEN'))
    if (-not $token) { Set-Banner 'Cancelled.' 'idle'; return }
    $email = [Microsoft.VisualBasic.Interaction]::InputBox("Email for Let's Encrypt expiry notices", 'Email', (Get-EnvValue 'LETSENCRYPT_EMAIL'))
    if (-not $email) { Set-Banner 'Cancelled.' 'idle'; return }

    Invoke-OtsCommand -Title 'Configure internet access' `
        -CommandArgs @('go-public', $sub, $token, $email) -Verify $VerifyGoPublic | Out-Null
} 'Free DuckDNS hostname that follows your changing IP'

Add-ActionButton 'Check Internet Setup' {
    Invoke-OtsCommand -Title 'Check internet reachability' -CommandArgs @('check-internet') -Verify {
        param($exit)
        if ($exit -eq 0) { @{ Ok = $true; Message = 'DNS and listeners look correct on this side.' } }
        else { @{ Ok = $false; Message = 'Problems found - see the output above.' } }
    } | Out-Null
} 'Confirms your hostname points at your current public IP'

Add-ActionButton 'Request Certificate' {
    Invoke-OtsCommand -Title "Request a Let's Encrypt certificate" -CommandArgs @('cert-request') -Verify $VerifyCert | Out-Null
} "Needs port 80 forwarded from your router"

Add-ActionButton 'Firewall Rules (admin)' {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "This opens the OpenTAKServer ports in Windows Firewall.`n`nWindows will ask for administrator permission.`n`nContinue?",
        'Firewall rules', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $Root 'windows-firewall.ps1'),
            '-Profile', 'Any', '-Video')
        $rules = Get-NetFirewallRule -DisplayName 'OpenTAKServer - *' -ErrorAction SilentlyContinue
        if ($rules) { Set-Banner "VERIFIED - $($rules.Count) firewall rule(s) are in place." 'ok' }
        else { Set-Banner 'NOT APPLIED - no OpenTAKServer firewall rules found.' 'fail' }
    } catch {
        Set-Banner 'Cancelled or failed - administrator permission is required.' 'fail'
    }
} 'Allow the TAK ports through Windows Firewall'

# ---- Security --------------------------------------------------------------
Add-SectionLabel 'Security'

Add-ActionButton 'Change Admin Password' {
    $cur = [Microsoft.VisualBasic.Interaction]::InputBox('Current administrator password', 'Current password', '')
    if (-not $cur) { Set-Banner 'Cancelled.' 'idle'; return }
    $new1 = [Microsoft.VisualBasic.Interaction]::InputBox('New password (at least 8 characters)', 'New password', '')
    if (-not $new1) { Set-Banner 'Cancelled.' 'idle'; return }
    $new2 = [Microsoft.VisualBasic.Interaction]::InputBox('Confirm the new password', 'Confirm password', '')
    if ($new1 -ne $new2) {
        [System.Windows.Forms.MessageBox]::Show('The two passwords do not match.', 'Mismatch', 'OK', 'Warning') | Out-Null
        Set-Banner 'Passwords did not match - nothing changed.' 'warn'
        return
    }
    # Passed through the environment so they never appear on a command line.
    Invoke-OtsCommand -Title 'Change the administrator password' `
        -CommandArgs @('set-admin-password') `
        -EnvVars @{ OTS_CURRENT_PASSWORD = $cur; OTS_NEW_PASSWORD = $new1 } `
        -Verify $VerifyPasswordChanged | Out-Null
} 'Required before exposing the server to the internet'

Add-ActionButton 'Encryption Policy' {
    $mode = Show-TlsPolicyDialog
    if (-not $mode) { Set-Banner 'Cancelled - encryption policy unchanged.' 'idle'; return }

    Invoke-OtsCommand -Title "Set encryption policy: $mode" -CommandArgs @('tls-only', $mode) -Verify {
        param($exit)
        if ($exit -ne 0) { return @{ Ok = $false; Message = 'Some ports are not in the expected state - see above.' } }
        $tak   = (Get-EnvValue 'OTS_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'
        $video = (Get-EnvValue 'OTS_VIDEO_PLAINTEXT_BIND' '0.0.0.0') -eq '127.0.0.1'
        if ($tak -and $video)      { @{ Ok = $true; Message = 'Everything reachable from the network is encrypted.' } }
        elseif ($tak)              { @{ Ok = $true; Message = 'TAK traffic is encrypted-only; video accepts plain and encrypted.' } }
        else                       { @{ Ok = $true; Message = 'All unencrypted ports are open again.' } }
    } | Out-Null
} 'Choose which unencrypted ports stay reachable'

Add-ActionButton 'Export CA Certificate' {
    Invoke-OtsCommand -Title 'Export the CA certificate' -CommandArgs @('ca-export') -Verify $VerifyCaExport | Out-Null
} 'Saves ca.pem for importing into TAK clients'

Add-ActionButton 'Update Server Address' {
    Invoke-OtsCommand -Title 'Update the server address' -CommandArgs @('set-address') -Verify {
        param($exit)
        $fqdn = Get-EnvValue 'OTS_FQDN'
        if ((Get-HttpStatus 'https://localhost/') -eq 200) { @{ Ok = $true; Message = "Address is now $fqdn and the server responds." } }
        else { @{ Ok = $false; Message = 'Address updated but the web UI is not responding.' } }
    } | Out-Null
} 'Re-detect the LAN IP after changing network'

# ---- Diagnostics -----------------------------------------------------------
Add-SectionLabel 'Diagnostics'

Add-ActionButton 'Run Diagnostics' {
    Invoke-OtsCommand -Title 'Diagnostics' -CommandArgs @('doctor') -Verify $VerifyDoctor | Out-Null
} 'Checks Docker, .env, subnet conflicts and firewall profile'

Add-ActionButton 'Open Web UI' {
    $fqdn = Get-EnvValue 'OTS_FQDN' 'localhost'
    if ($fqdn -eq '_' -or -not $fqdn) { $fqdn = 'localhost' }
    Start-Process "https://$fqdn"
    Set-Banner "Opened https://$fqdn in your browser." 'idle'
} 'Open the OpenTAKServer web interface'

Add-ActionButton 'Open Folder' {
    Start-Process explorer.exe $Root
} 'Open this installation folder'

Add-ActionButton 'RESET - delete all data' {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "This permanently deletes:`n`n  - the database`n  - all certificates`n  - uploaded data packages and recordings`n`nEvery TAK client will have to enrol again.`n`nThere is no undo. Continue?",
        'Delete everything?', 'YesNo', 'Warning', 'Button2')
    if ($r -ne 'Yes') { Set-Banner 'Cancelled - nothing was deleted.' 'idle'; return }
    $c = [Microsoft.VisualBasic.Interaction]::InputBox("Type DELETE in capitals to confirm.", 'Confirm reset', '')
    if ($c -ne 'DELETE') { Set-Banner 'Cancelled - nothing was deleted.' 'idle'; return }
    Invoke-OtsCommand -Title 'Reset - delete all data' -CommandArgs @('reset') -AssumeYes -Verify $VerifyReset | Out-Null
} 'Destroys all data and starts over' -Danger

# ===========================================================================
#  Wire-up
# ===========================================================================
$btnRefresh.Add_Click({
    Set-Banner 'Refreshing...' 'busy'
    Update-Status -IncludeSecurity
    Set-Banner 'Status refreshed.' 'idle'
})

$form.Add_Shown({
    Add-Line 'OpenTAKServer Manager' $ColAccent
    Add-Line ''

    # Work out where this installation actually is, and say what to press next.
    $dockerInstalled = Test-DockerInstalled
    $dockerRunning   = if ($dockerInstalled) { Test-DockerUp } else { $false }
    $setupDone       = Test-SetupComplete

    if (-not $dockerInstalled) {
        Add-Line 'Welcome. Nothing is installed yet - this will walk you through it.'
        Add-Line ''
        Add-Line 'Press "0. Check This PC" first, then work down the numbered buttons.' $ColWarn
        Add-Line ''
        Add-Line 'Step 0 confirms this machine can run Docker at all - mainly that' $ColMuted
        Add-Line 'hardware virtualization is on and WSL is available. Those are the' $ColMuted
        Add-Line 'two things that stop a Docker install cold, and only step 0 will' $ColMuted
        Add-Line 'tell you before you spend the download.' $ColMuted
        Set-Banner 'Start here: press "0. Check This PC".' 'warn'
    }
    elseif (-not $dockerRunning) {
        Add-Line 'Docker Desktop is installed but its engine is not running.'
        Add-Line ''
        Add-Line 'Press "2. Start Docker Desktop" on the left.' $ColWarn
        Set-Banner 'Next: press "2. Start Docker Desktop".' 'warn'
    }
    elseif (-not $setupDone) {
        Add-Line 'Docker is running. OpenTAKServer has not been installed yet.'
        Add-Line ''
        Add-Line 'Press "3. Build and Install Server" on the left.' $ColWarn
        Add-Line ''
        Add-Line 'It downloads about 3 GB of images and takes several minutes.' $ColMuted
        Set-Banner 'Next: press "3. Build and Install Server".' 'warn'
    }
    else {
        Add-Line 'Pick an action on the left. Output appears here, and the bar at the'
        Add-Line 'bottom says whether the change actually took effect.'
    }

    Update-Status -IncludeSecurity

    if ($lblSecurity.Text -like '*DEFAULT*') {
        Add-Line ''
        Add-Line '[!]  The administrator account still uses the default password.' $ColWarn
        Add-Line '     Use "Change Admin Password" before anyone else can reach this server.' $ColWarn
    }
})

# Refresh the light-weight parts of the status panel periodically.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$timer.Add_Tick({ if ($btnRefresh.Enabled) { Update-Status } })
$timer.Start()

[void]$form.ShowDialog()
$timer.Stop()

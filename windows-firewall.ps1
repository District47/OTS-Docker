<#
.SYNOPSIS
    Opens the OpenTAKServer ports in Windows Firewall.

.DESCRIPTION
    Docker Desktop usually adds its own rules, but a hardened machine - or a
    network profile set to Public - will still block inbound connections.
    This adds explicit inbound allow rules for the OpenTAKServer ports.

    MUST BE RUN AS ADMINISTRATOR. Right-click PowerShell and choose
    "Run as administrator", then run this script.

    Every rule is named "OpenTAKServer - ...", so you can find and remove them
    later with -Remove, or in wf.msc.

.PARAMETER Profile
    Which firewall profile(s) the rules apply to. Default is Private only,
    which is what you want for a LAN server.

    Use 'Any' when the machine is internet-facing and the network is marked
    Public - but understand this opens the ports on EVERY network you join,
    including coffee shop Wi-Fi.

.PARAMETER Video
    Also open the MediaMTX video streaming ports.

.PARAMETER Remove
    Delete the rules this script created instead of adding them.

.EXAMPLE
    .\windows-firewall.ps1

.EXAMPLE
    .\windows-firewall.ps1 -Profile Any -Video

.EXAMPLE
    .\windows-firewall.ps1 -Remove
#>
[CmdletBinding()]
param(
    [ValidateSet('Private', 'Domain', 'Public', 'Any')]
    [string]$Profile = 'Private',
    [switch]$Video,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

function Write-Ok   { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    [x]  $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Must be elevated - creating firewall rules is an administrative action.
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator."
    Write-Host ""
    Write-Host "    Close this window, right-click PowerShell, choose"
    Write-Host "    'Run as administrator', then run it again:"
    Write-Host ""
    Write-Host "        cd '$PSScriptRoot'" -ForegroundColor White
    Write-Host "        .\windows-firewall.ps1" -ForegroundColor White
    Write-Host ""
    exit 1
}

$prefix = 'OpenTAKServer'

$rules = @(
    @{ Name = 'Web UI (HTTP / ACME)';      Port = 80;   Protocol = 'TCP' }
    @{ Name = 'Web UI (HTTPS)';            Port = 443;  Protocol = 'TCP' }
    @{ Name = 'Marti API (HTTP)';          Port = 8080; Protocol = 'TCP' }
    @{ Name = 'Marti API (HTTPS)';         Port = 8443; Protocol = 'TCP' }
    @{ Name = 'Certificate enrollment';    Port = 8446; Protocol = 'TCP' }
    @{ Name = 'MQTT over TLS';             Port = 8883; Protocol = 'TCP' }
    @{ Name = 'CoT streaming (TCP)';       Port = 8088; Protocol = 'TCP' }
    @{ Name = 'CoT streaming (SSL)';       Port = 8089; Protocol = 'TCP' }
)

$videoRules = @(
    @{ Name = 'Video RTMP';       Port = 1935; Protocol = 'TCP' }
    @{ Name = 'Video RTMPS';      Port = 1936; Protocol = 'TCP' }
    @{ Name = 'Video RTSPS';      Port = 8322; Protocol = 'TCP' }
    @{ Name = 'Video RTSP';       Port = 8554; Protocol = 'TCP' }
    @{ Name = 'Video HLS';        Port = 8888; Protocol = 'TCP' }
    @{ Name = 'Video WebRTC';     Port = 8889; Protocol = 'TCP' }
    @{ Name = 'Video RTP';        Port = 8000; Protocol = 'UDP' }
    @{ Name = 'Video RTCP';       Port = 8001; Protocol = 'UDP' }
    @{ Name = 'Video SRTP';       Port = 8004; Protocol = 'UDP' }
    @{ Name = 'Video SRTCP';      Port = 8005; Protocol = 'UDP' }
    @{ Name = 'Video WebRTC ICE'; Port = 8189; Protocol = 'UDP' }
    @{ Name = 'Video SRT';        Port = 8890; Protocol = 'UDP' }
)

if ($Video) { $rules += $videoRules }

Write-Host ""
Write-Host "  OpenTAKServer - Windows Firewall rules" -ForegroundColor White
Write-Host "  --------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
if ($Remove) {
    $existing = Get-NetFirewallRule -DisplayName "$prefix - *" -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Warn "No OpenTAKServer firewall rules found."
        exit 0
    }
    foreach ($r in $existing) {
        Remove-NetFirewallRule -Name $r.Name
        Write-Ok "removed: $($r.DisplayName)"
    }
    Write-Host ""
    Write-Ok "Done. $($existing.Count) rule(s) removed."
    exit 0
}

# ---------------------------------------------------------------------------
# Add
# ---------------------------------------------------------------------------
if ($Profile -eq 'Public' -or $Profile -eq 'Any') {
    Write-Warn "Opening these ports on the '$Profile' profile."
    Write-Warn "They will be reachable on EVERY network this machine joins,"
    Write-Warn "including untrusted public Wi-Fi. Use -Profile Private if this"
    Write-Warn "server only needs to work on your own network."
    Write-Host ""
}

foreach ($rule in $rules) {
    $display = "$prefix - $($rule.Name)"

    $old = Get-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue
    if ($old) { $old | Remove-NetFirewallRule }

    New-NetFirewallRule `
        -DisplayName $display `
        -Description "Created by the OpenTAKServer Docker setup." `
        -Direction Inbound `
        -Action Allow `
        -Protocol $rule.Protocol `
        -LocalPort $rule.Port `
        -Profile $Profile `
        -Enabled True | Out-Null

    Write-Ok ("{0,-5} {1,-4}  {2}" -f $rule.Port, $rule.Protocol, $rule.Name)
}

Write-Host ""
Write-Ok "$($rules.Count) rule(s) added on the '$Profile' profile."
Write-Host ""
Write-Host "    Remove them later with:  .\windows-firewall.ps1 -Remove" -ForegroundColor DarkGray
Write-Host ""

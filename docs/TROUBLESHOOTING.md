# Troubleshooting

Always start here:

```bash
.\ots.ps1 doctor
```

Then look at the logs for whichever piece is unhappy:

```bash
.\ots.ps1 logs ots        # the server itself
.\ots.ps1 logs nginx      # web UI and TLS
.\ots.ps1 logs ots-db     # database
.\ots.ps1 logs rabbitmq   # message bus
```

---

## Setup and startup

### A script "cannot be loaded" / "is not digitally signed"

```
File ... cannot be loaded. The file ... is not digitally signed.
```

or

```
File ... cannot be loaded because running scripts is disabled on this system.
```

**Fix, in the folder you extracted:**

```bash
cd C:\path\to\OTS-Docker
Get-ChildItem -Recurse | Unblock-File
```

Then run it again.

`Unblock-File` is a built-in command, not a script, so it works even when
every script is blocked. `Get-ChildItem -Recurse` only covers the folder you
are currently in, so `cd` there first.

**Why it happens.** Windows tags every file extracted from a downloaded ZIP
with a "downloaded from the internet" marker. The default `RemoteSigned`
policy then refuses to run them unless they carry a code-signing certificate,
which this project does not have. Nothing is wrong with the files — Windows
simply cannot tell a trustworthy download from an untrustworthy one, so it
blocks all of them.

Both `OTS Manager.cmd` and `Setup.cmd` clear the marker automatically, so
launching through either avoids this entirely. The error only appears if you
run a `.ps1` file directly.

If it still refuses after unblocking, your machine has a stricter policy
(`AllSigned`, or one set by group policy). Allow scripts for one window:

```bash
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

That affects only the window you type it in and resets when you close it.

### "Docker is installed but not running"

Start Docker Desktop and wait for *Engine running* in the bottom-left corner.
On a fresh install it may ask to enable WSL 2 and reboot.

### WSL and virtualization

Docker Desktop runs Linux containers inside WSL 2. Two things underneath it
break more first installs than anything else. Check both at once with:

```bash
.\ots.ps1 preflight
```

or the **0. Check This PC** button in the manager.

**"Hardware virtualization is not enabled in firmware"**

No software can fix this — it is a BIOS/UEFI setting. Reboot into your firmware
setup (usually Del, F2 or F10 during boot) and enable the option named
**Intel VT-x**, **AMD-V**, **SVM Mode** or **Virtualization Technology**. Save
and reboot.

On a laptop that has never run a VM, this is very often the culprit.

> Do not diagnose this with `Get-CimInstance Win32_Processor` alone.
> `VirtualizationFirmwareEnabled` reports **False** whenever a hypervisor is
> already running, so a perfectly healthy machine looks broken. `preflight`
> checks `HypervisorPresent` first for exactly this reason.

**"WSL is not installed or not enabled"**

Docker Desktop's installer normally handles this. If it did not, open
PowerShell **as Administrator** and run:

```bash
wsl --install
```

then restart Windows. If WSL is installed but old:

```bash
wsl --update
```

**"WSL default version is 1"**

Docker needs version 2:

```bash
wsl --set-default-version 2
```

**Docker Desktop starts, then exits or says "WSL 2 installation is incomplete"**

Usually a missing kernel update. Run `wsl --update` as Administrator, reboot,
and start Docker Desktop again.

> Checking Windows optional features with `Get-WindowsOptionalFeature` requires
> an elevated prompt, which is why the manager detects WSL through `wsl.exe`
> instead — that works without administrator rights.

### A port is already in use

```
Bind for 0.0.0.0:443 failed: port is already allocated
```

Something else on the machine owns that port — IIS, Skype and VPN clients are
common culprits. Find it:

```bash
Get-Process -Id (Get-NetTCPConnection -LocalPort 443 -State Listen).OwningProcess
```

Then either stop that program, or change the port in `.env`:

```
OTS_HTTPS_PORT=8443
```

and run `.\ots.ps1 restart`. Remember that clients must then use the new port.

### The network subnet conflicts

```
Pool overlaps with other one on this address space
```

The fixed Docker subnet clashes with something else. First see what is already
taken — Docker Desktop, WSL and Hyper-V all carve out ranges in `172.16-31.x`:

```bash
ipconfig | findstr /i "IPv4"
```

Then pick a range that appears nowhere in that list and edit `.env`:

```
OTS_NETWORK_SUBNET=172.24.0.0/16
OTS_RABBITMQ_IP=172.24.0.10
```

Both must be changed together — the IP has to sit inside the subnet. Avoid
whatever your WSL and "Default Switch" adapters already use (commonly
`172.29.x` and `172.31.x`). Then:

```bash
.\ots.ps1 stop
.\ots.ps1 start
```

### The server never becomes healthy

First runs are slow: migrations run and the certificate authority is generated.
Give it five minutes, then:

```bash
.\ots.ps1 logs ots
```

If you see database connection errors, the most likely cause is a `.env`
password that no longer matches the existing database — see below.

### "password authentication failed for user ots"

You regenerated `.env` (usually with `setup.ps1 -Force`) after the database was
already created. The database still has the old password.

Either restore the old `.env` from the `.env.backup-*` file that `setup.ps1`
saved, or wipe everything and start fresh:

```bash
.\ots.ps1 reset
.\setup.ps1
```

`reset` deletes all data permanently.

---

## Network and clients

### Other devices on the LAN cannot connect

1. Confirm it works locally first: open `https://localhost` on the server itself.
2. Get the server's LAN IP with `ipconfig` and try that address from the server.
3. From the other device, browse to `https://<server-ip>`.

If step 3 is the one that fails, it is Windows Firewall or network isolation:

* **Firewall** — Docker Desktop usually adds rules, but a hardened or
  third-party firewall may not. Allow inbound TCP on 443, 8443, 8446 and 8089.
* **Network profile** — Windows blocks most inbound traffic on networks marked
  *Public*. Check with `Get-NetConnectionProfile`; a home or office LAN should
  be *Private*.
* **Client isolation** — many guest and public Wi-Fi networks stop devices from
  talking to each other at all. Nothing on the server can fix that.

### The browser warns about the certificate

Expected on a self-signed install. OpenTAKServer issues its certificate for the
name `opentakserver`, which never matches your IP, so browsers object. Click
through it, or set up Let's Encrypt (see the README).

### MQTT / Meshtastic clients are rejected

MQTT logins are checked against OpenTAKServer's user database, and the server
only accepts those checks from RabbitMQ's exact IP address. If you changed
`OTS_RABBITMQ_IP` in `.env` after the first start, the value baked into
`config.yml` is now stale. Fix it with:

```bash
.\ots.ps1 config
```

and update `OTS_RABBITMQ_SERVER_ADDRESS` to match.

---

## Configuration

### Changing a setting in `.env` did nothing

Expected for application settings. OpenTAKServer copies `.env` into `config.yml`
on its **first start only**, and `config.yml` wins from then on. Use the web UI's
Settings page, or:

```bash
.\ots.ps1 config
```

`.env` still controls ports, passwords, image versions and TLS mode, because
those are read by Docker and nginx rather than by the application.

### Where is my data?

In Docker named volumes, not in this folder:

| Volume | Contents |
|---|---|
| `opentakserver_ots_data` | Certificates, `config.yml`, logs, uploads, recordings |
| `opentakserver_ots_pgdata` | The PostgreSQL database |
| `opentakserver_ots_rabbitmq` | Message broker state |

To pull a file out:

```bash
docker compose cp ots:/app/ots/config.yml .\config.yml
```

This is deliberate. PostgreSQL cannot run on a Windows bind mount — it needs
POSIX ownership on its data directory — and keeping the files out of the
project folder stops OneDrive and similar tools from touching live database
files.

---

## Video

### Streams do not appear

Check MediaMTX:

```bash
.\ots.ps1 logs mediamtx
```

MediaMTX authenticates its callbacks to OpenTAKServer with a token that the
server writes into `mediamtx.yml` at startup. If you replaced that file by
hand, remove the token line and restart so it is regenerated:

```bash
.\ots.ps1 restart
```

---

## Starting completely over

```bash
.\ots.ps1 backup     # if there is anything worth keeping
.\ots.ps1 reset
.\setup.ps1
```

---

## Still stuck?

Collect the details before asking for help:

```bash
.\ots.ps1 status
.\ots.ps1 logs ots
```

* OpenTAKServer issues: <https://github.com/brian7704/OpenTAKServer/issues>
* OpenTAKServer docs: <https://docs.opentakserver.io/>

Note that this Compose stack is not the official upstream packaging, so report
problems with the containers here rather than upstream.

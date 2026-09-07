# OpenTAKServer on Windows, with Docker

Run [OpenTAKServer](https://github.com/brian7704/OpenTAKServer) — an open source
TAK server for ATAK, WinTAK and iTAK — on a Windows machine with one command.

No WSL commands to memorise, no Linux VM to configure by hand, no services to
install. Everything runs in containers.

---

## What you need

* **Windows 10 (21H2 or newer) or Windows 11**, 64-bit
* **About 6 GB of disk** and **4 GB of free RAM**
* An internet connection for the first run, to download the images

Docker is the only prerequisite, and the installer sets it up for you.

---

## Install

Open **PowerShell** and run:

```bash
irm https://raw.githubusercontent.com/District47/OTS-Docker/main/install.ps1 | iex
```

That downloads the latest release to `C:\OTS-Docker`, unblocks it, puts a
shortcut on your Desktop and opens the control panel. It needs no administrator
rights and installs nothing system-wide — the whole thing is one folder you can
delete.

Prefer to do it by hand? Download the ZIP from
[Releases](https://github.com/District47/OTS-Docker/releases), extract it,
right-click the ZIP → **Properties → Unblock** first, then double-click
**`OTS Manager.cmd`**.

### Then work down the numbered buttons

| | |
|---|---|
| **0. Check This PC** | Confirms this machine *can* run Docker: Windows version, hardware virtualization, WSL, memory, disk. |
| **1. Install Docker Desktop** | Installs Docker via winget, if you don't already have it. Skips itself if you do. |
| **2. Start Docker Desktop** | Launches Docker and waits for its engine to come up. |
| **3. Build and Install Server** | Generates secure passwords, detects your network address, downloads the images, builds, and starts everything. |
| **4. Port Forwarding Help** | Only if you want internet access. Builds a prompt describing your router, ISP and exact ports, to paste into Claude or ChatGPT. |

Step 0 is worth the ten seconds. The two things that stop a Docker install
cold — **hardware virtualization disabled in BIOS** and **WSL not enabled** —
are invisible until the install fails, and the first one can only be fixed from
your firmware setup, not from Windows.

Each step checks its own result and turns the bar at the bottom green
(**VERIFIED**) or red (**NOT APPLIED**) with the reason, and the window tells
you which button to press next. The first run takes several minutes, mostly
downloading.

You may need to restart Windows after installing Docker — it uses WSL 2, which
usually requires a reboot. Reopen the manager afterwards and continue at step 2.

### Prefer the command line?

Everything the GUI does is also a script:

```bash
.\setup.ps1
```

If PowerShell refuses to run it, allow local scripts for this session:

```bash
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### First login

Open the address the script prints — usually `https://<your-lan-ip>`.

| | |
|---|---|
| Username | `administrator` |
| Password | `password` |

> **Change this password immediately.** It is identical on every OpenTAKServer
> install, so anyone who can reach your server knows it:
>
> ```bash
> .\ots.ps1 set-admin-password
> ```
>
> Or use the web UI. This is mandatory before exposing the server to the
> internet — `go-public` will refuse to run otherwise.

Your browser will warn that the certificate is untrusted. That is expected:
OpenTAKServer signs its own certificate with a private certificate authority.
Click through the warning.

---

## Connecting TAK clients

See **[docs/CLIENTS.md](docs/CLIENTS.md)** for step-by-step ATAK, WinTAK and
iTAK setup, including automatic certificate enrollment.

The short version: create a user in the web UI, then point the client at your
server's address on port **8446** using certificate enrollment.

---

## Everyday use

### The control panel

The same window you installed from — **`OTS Manager.cmd`**.

Every command below is a button, with live output and — the useful part — a
check after each action that confirms the change actually took effect. The bar
along the bottom turns green (**VERIFIED**) or red (**NOT APPLIED**) and says
why, so you are never left guessing whether something worked.

The header shows Docker state, how many services are running, whether the web
UI responds, your server address, TLS mode, and a red warning if the
administrator account still has the default password.

It needs no installation — it is a PowerShell window using built-in Windows
components.

### Or the command line

```bash
.\ots.ps1 help
```

| Command | What it does |
|---|---|
| `.\ots.ps1 start` | Start the server |
| `.\ots.ps1 stop` | Stop it (all data is kept) |
| `.\ots.ps1 status` | Show what is running and healthy |
| `.\ots.ps1 logs ots` | Follow the server log |
| `.\ots.ps1 set-address` | Update the server address after changing network |
| `.\ots.ps1 backup` | Back up the database and all server data |
| `.\ots.ps1 restore <folder>` | Restore from a backup |
| `.\ots.ps1 update` | Pull newer images and restart |
| `.\ots.ps1 config` | Edit `config.yml` in Notepad, then restart |
| `.\ots.ps1 set-admin-password` | Change the administrator password |
| `.\ots.ps1 tls-only on` | Choose which unencrypted ports stay reachable |
| `.\ots.ps1 go-public` | Configure internet access (DDNS + TLS) |
| `.\ots.ps1 check-internet` | Verify DNS and listeners |
| `.\ots.ps1 doctor` | Check for common problems |
| `.\ots.ps1 reset` | Delete everything and start over |

---

## Ports

These are opened on your machine. Change any of them by editing `.env` and
running `.\ots.ps1 restart`.

| Port | Protocol | Used for |
|---|---|---|
| 80 | TCP | Web UI — redirects to HTTPS |
| 443 | TCP | Web UI |
| 8080 | TCP | Marti API over HTTP |
| 8443 | TCP | Marti API over HTTPS, client certificate required |
| 8446 | TCP | Automatic certificate enrollment |
| 8883 | TCP | MQTT over TLS (Meshtastic) |
| 8087 | UDP | CoT streaming — off by default, see below |
| 8088 | TCP | CoT streaming, no encryption |
| 8089 | TCP | CoT streaming over TLS — **this is what TAK clients use** |
| 1935 / 1936 | TCP | RTMP / RTMPS video |
| 8554 / 8322 | TCP | RTSP / RTSPS video |
| 8888 / 8889 | TCP | HLS / WebRTC video |
| 8890 | UDP | SRT video |
| 8000 / 8001 | UDP | RTP / RTCP — media for plain RTSP |
| 8004 / 8005 | UDP | SRTP / SRTCP — media for encrypted RTSPS |

To reach the server from other devices on your network, Windows Firewall must
allow these. Docker Desktop normally adds the rules automatically; if clients
cannot connect, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

**UDP CoT (port 8087) is disabled by default.** The published OpenTAKServer
image does not accept the `--udp` flag its own source defines, so the container
would only crash-loop. If you are running an image that supports it:

```bash
docker compose --profile udp up -d
```

TAK clients normally use the SSL streaming port (8089) regardless.

### Encryption policy

Every encrypted port already presents a certificate. The catch is that some
services also run an **unencrypted twin** next to the encrypted one, and a
client will use whichever you point it at.

Pick a policy with **Encryption Policy** in the manager, or:

```bash
.\ots.ps1 tls-only [on|all|off]
```

| Mode | 8080 / 8088 | Plain video (RTSP, RTMP, HLS, WebRTC) |
|---|---|---|
| **`on`** *(recommended)* | closed | **left open** alongside RTSPS/RTMPS |
| `all` | closed | closed — MediaMTX refuses unencrypted |
| `off` | open | open |

`on` is the sensible default because plenty of IP cameras and hardware
encoders only speak plain RTSP or RTMP, while the TAK side has no such excuse —
clients enrol on 8446 and stream on 8089, both encrypted, so closing 8080 and
8088 costs nothing.

Closed ports stay reachable on `127.0.0.1` for local tools; only network access
is removed. Check where you stand with `.\ots.ps1 tls-only status`.

> **On the wire:** RTSPS carries media over SRTP on UDP **8004/8005**, while
> plain RTSP uses RTP on **8000/8001** unencrypted. Both pairs are published,
> because MediaMTX switches between them depending on the mode — if you forward
> video ports through a router, forward all four.

---

## Configuration

### `.env` — infrastructure settings

Passwords, ports, image versions and the server address. Read by Docker
Compose. After changing it, run `.\ots.ps1 restart`.

Note that plain `docker compose restart` will *not* pick up `.env` edits — it
restarts containers with the environment they were created with. `.\ots.ps1
restart` runs `up -d` first so changed containers are recreated.

### `config.yml` — OpenTAKServer's own settings

This is the part that surprises people:

> OpenTAKServer reads the values from `.env` **only on its very first start**.
> It writes them into `config.yml`, and from then on **`config.yml` wins**.

So changing something like `OTS_FQDN` in `.env` after the first start has no
effect on the application. Change application settings in one of these places
instead:

* the **Settings** page in the web UI, or
* `.\ots.ps1 config`, which opens `config.yml` in Notepad and restarts for you

`.env` still controls everything outside the application: ports, the database
password, which image version runs, and the nginx TLS mode.

---

## Putting this on the internet

The default install is LAN-only. To reach it from anywhere — with a real
hostname and a trusted certificate, on a home connection with a changing IP:

```bash
.\ots.ps1 set-admin-password    # required first - see below
.\ots.ps1 go-public             # free DuckDNS hostname + auto-updating DNS
```

Then forward the ports on your router, allow them through Windows Firewall
(`.\windows-firewall.ps1`, as Administrator), and:

```bash
.\ots.ps1 check-internet
.\ots.ps1 cert-request
```

Renewal is fully automatic afterwards — certbot renews, and nginx reloads on a
timer to pick the new certificate up.

**Full walkthrough, including the router steps and what you are exposing:
[docs/INTERNET.md](docs/INTERNET.md).**

Two things worth knowing before you start:

* **The default password must go first.** Every install ships with
  `administrator` / `password`; internet-facing servers with it are found and
  taken over quickly. `go-public` refuses to run until you have changed it.
* **Only the web UI uses the Let's Encrypt certificate.** The TAK ports keep
  using the OpenTAKServer CA, because TAK clients authenticate with client
  certificates issued by that CA and would reject anything else.

---

## Moving between networks

If the machine changes Wi-Fi and gets a new IP, the server keeps working — the
containers bind all interfaces, and OpenTAKServer's certificate is issued for
the name `opentakserver` rather than for an IP, so nothing needs reissuing.

Point the tooling at the new address so it prints the right URL:

```bash
.\ots.ps1 set-address
```

That detects the current LAN IP (or pass one: `.\ots.ps1 set-address 192.168.1.50`).
TAK clients store the old address themselves and must each be updated.

One hazard on an unfamiliar network: if it hands out addresses in `172.28.x.x`,
that overlaps the stack's Docker subnet and breaks routing in confusing ways.
`.\ots.ps1 doctor` checks for this and tells you what to change — see also
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## A note on certificate security

The published OpenTAKServer image ships with a certificate authority already
generated inside it — including the CA private key, encrypted with the
well-known default password. Every deployment that keeps it therefore shares
one CA, and anyone who pulls the public image can extract that key and mint
client certificates your server would accept.

This stack deletes that CA on first start, so OpenTAKServer generates one
unique to your install. You can confirm yours is not the shared one:

```bash
docker compose exec ots openssl x509 -in /app/ots/ca/ca.pem -noout -fingerprint -sha256
```

If you ever see the fingerprint `7F:4F:A1:E0:E8:1B:9A:28:...` you are using the
image's shared CA and should run `.\ots.ps1 reset` and start over.

---

## Backups

```bash
.\ots.ps1 backup
```

Writes a timestamped folder under `backups\` containing a database dump and an
archive of all server data (certificates, uploaded data packages, recordings).

**Keep a copy of `.env` with your backups.** It holds the database password,
and the backup cannot be restored without it.

---

## Upgrading

```bash
.\ots.ps1 backup
.\ots.ps1 update
```

`update` pulls the newest build of the pinned version. To move to a different
OpenTAKServer release, edit `OTS_VERSION` in `.env` first — see the
[release list](https://github.com/brian7704/OpenTAKServer/releases). Database
migrations run automatically on the next start.

---

## A warning about `setup.ps1 -Force`

`-Force` generates **new** database and message broker passwords. The existing
database still expects the old ones, so the stack will fail to start. Only use
`-Force` on a fresh install, or immediately before `.\ots.ps1 reset`.

To change settings on a working install, edit `.env` directly.

---

## How it fits together

```
                    ┌──────────────────────────────┐
   Browser  ────────▶  nginx  (80, 443)            │
                    │    • serves the web UI       │
   TAK client ──────▶    • terminates TLS for      │
   (8443/8446)      │      the TAK API ports       │
                    │    • MQTT TLS ──▶ RabbitMQ   │
                    └───────────┬──────────────────┘
                                │
                    ┌───────────▼──────────────────┐
                    │  opentakserver (8081)        │
                    │    REST API, web backend,    │
                    │    certificate authority     │
                    └───┬────────┬─────────┬───────┘
                        │        │         │
              ┌─────────▼──┐ ┌───▼─────┐ ┌─▼──────────┐
              │ PostGIS    │ │RabbitMQ │ │ MediaMTX   │
              │ database   │ │ message │ │ video      │
              └────────────┘ │ bus     │ └────────────┘
                             └────┬────┘
                                  │
     ┌────────────────────────────┼────────────────────────┐
     │                            │                        │
┌────▼────────┐  ┌────────────────▼───┐  ┌─────────────────▼─┐
│ cot_parser  │  │ eud_handler        │  │ eud_handler_ssl   │
│ parses CoT  │  │ TCP 8088 / UDP 8087│  │ TLS 8089          │
└─────────────┘  └────────────────────┘  └───────────────────┘
```

All data lives in Docker named volumes (`ots_data`, `ots_pgdata`,
`ots_rabbitmq`), not in this folder. That is deliberate: PostgreSQL cannot run
on a Windows bind mount, and it keeps cloud-sync tools away from live database
files.

---

## Troubleshooting

Start with:

```bash
.\ots.ps1 doctor
```

Then see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Credits and licensing

* [OpenTAKServer](https://github.com/brian7704/OpenTAKServer) by Brian Wallen —
  GPL-3.0. This project only packages it; all server functionality is theirs.
* [OpenTAKServer-Docker](https://github.com/brian7704/OpenTAKServer-Docker) —
  the upstream Docker work this configuration builds on.
* [MediaMTX](https://github.com/bluenviron/mediamtx) — MIT.

The packaging in this repository (Compose file, nginx configuration and
PowerShell scripts) is released under the MIT licence — see [LICENSE](LICENSE).
Container images are covered by their own upstream licences.

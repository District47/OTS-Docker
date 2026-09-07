# Putting OpenTAKServer on the internet

This gets you a server reachable from anywhere, with a real hostname and a
trusted TLS certificate, on an ordinary home connection with a changing IP.

Read the [security section](#before-you-open-the-door) first. Once this is
done, anyone on the internet can reach your server.

---

## What has to be true

| | Handled by |
|---|---|
| A hostname that follows your changing IP | `go-public` — DuckDNS + an updater container |
| A certificate browsers trust | `cert-request` — Let's Encrypt, auto-renewed |
| Your router sending traffic to this PC | **you**, in the router admin page |
| Windows Firewall allowing it in | `windows-firewall.ps1` |
| An admin password that isn't the default | `set-admin-password` — enforced |

---

## Before you open the door

**Change the administrator password.** Every OpenTAKServer install starts with
`administrator` / `password`. Publishing port 443 without changing it means
losing the server, quickly and automatically — this is scanned for constantly.

```bash
.\ots.ps1 set-admin-password
```

`go-public` refuses to run until you have.

**Know what you are exposing.** This setup publishes the full TAK port set
including video and plain-HTTP Marti:

| Port | Encrypted? | Notes |
|---|---|---|
| 443, 8443, 8446, 8883 | yes | web UI, Marti API, enrollment, MQTT |
| 8089 | yes | CoT streaming — what clients actually use |
| 80 | no | redirects to HTTPS; needed for certificate renewal |
| **8080** | **no** | **Marti API in the clear — anyone on the path can read it** |
| 8088 | no | CoT streaming without TLS |
| 1935/8554/8888/… | mostly no | video streams |

If you do not have a specific reason for 8080 and 8088, do not forward them.
Nothing in ATAK, WinTAK or iTAK needs them when you use certificate
enrollment — clients use 8446 to enrol and 8089 to stream.

**Not exposed, and should stay that way:** PostgreSQL (5432) and RabbitMQ
(5672/15672) are never published to the host at all — they are reachable only
inside the Docker network.

---

## Step 1 — get a hostname

Sign in at [duckdns.org](https://www.duckdns.org) (free, sign in with Google or
GitHub), create a subdomain, and copy the token shown at the top of the page.

Then:

```bash
.\ots.ps1 go-public
```

It asks for the subdomain, the token, and an email for Let's Encrypt expiry
notices. It verifies the token with DuckDNS before saving anything, writes
`OTS_FQDN`, switches TLS mode to `letsencrypt`, and starts the updater
container that keeps the hostname pointed at your current IP.

Non-interactive form:

```bash
.\ots.ps1 go-public mysubdomain my-duckdns-token me@example.com
```

## Step 2 — forward ports on your router

This is the part only you can do, and every router's menus are different.

**Shortcut:** press **4. Port Forwarding Help** in the manager. It builds a
prompt describing your router model, ISP, LAN address and the exact ports —
already filled in from your configuration — ready to paste into Claude or
ChatGPT, which can then walk you through your specific router's screens. It
also asks them to cover DHCP reservations, CGNAT, and ISPs that block port 80.

The prompt is only copied to your clipboard; nothing is transmitted by the
manager itself, and it deliberately leaves out your hostname, public IP and
every password.

Otherwise, do it by hand. Log in to your router (usually
`http://192.168.1.1`) and find *Port Forwarding*, sometimes under NAT,
Firewall, or Advanced.

Forward each port to **this machine's LAN IP** — `.\ots.ps1 doctor` prints it.

```
 80    TCP    required for certificate issue AND renewal
 443   TCP    web UI
 8443  TCP    Marti API
 8446  TCP    certificate enrollment
 8089  TCP    CoT streaming over TLS
 8883  TCP    MQTT over TLS
 8080  TCP    Marti over plain HTTP        (skip unless needed)
 8088  TCP    CoT without encryption       (skip unless needed)
 1935,1936,8322,8554,8888,8889   TCP   video
 8000,8001                       UDP   video - media for plain RTSP
 8004,8005                       UDP   video - media for encrypted RTSPS
 8189,8890                       UDP   video - WebRTC, SRT
```

**Also give this PC a DHCP reservation** (often "Static Lease" or "Address
Reservation" on the same router page). Otherwise its LAN IP changes on the next
reboot and every forwarding rule silently points at nothing.

> Some ISPs use CGNAT, which makes inbound port forwarding impossible no matter
> what you configure. If your router's WAN address starts with `100.64.`–`100.127.`
> or differs from what `.\ots.ps1 check-internet` reports as your public IP,
> you are behind CGNAT. Ask your ISP for a public IP, or use a tunnel
> (Cloudflare Tunnel, Tailscale Funnel) instead.

## Step 3 — allow it through Windows Firewall

Right-click PowerShell → **Run as administrator**, then:

```bash
cd C:\path\to\OTS-Docker
.\windows-firewall.ps1 -Profile Any -Video
```

`-Profile Any` is needed when your Wi-Fi is marked *Public* in Windows — but be
aware it opens these ports on **every** network the machine joins, including
public Wi-Fi. If the machine stays on one trusted network, prefer:

```bash
.\windows-firewall.ps1
```

which applies to the Private profile only. Undo any time with
`.\windows-firewall.ps1 -Remove`.

## Step 4 — check, then get the certificate

```bash
.\ots.ps1 check-internet
```

This confirms your hostname resolves to your current public IP and that all the
listeners are up. It cannot see your router, so the real test is:

```bash
.\ots.ps1 cert-request
```

Let's Encrypt connects **from the internet** to port 80. If it succeeds, your
forwarding works. If it fails, it is almost always port 80 not reaching this
machine.

That's it. Visit `https://yoursubdomain.duckdns.org` — no certificate warning.

---

## Renewal is automatic

The `certbot` container checks twice a day and renews at 60 days. nginx reloads
every 6 hours to pick up a renewed certificate, because certbot runs in a
separate container and cannot signal it directly.

Two things keep this working, so don't undo them:

* **Port 80 must stay forwarded.** Renewal uses it exactly like issuance did.
* **The `public` profile must stay running** — `.\ots.ps1 start` alone starts
  the LAN services only. Use:

  ```bash
  docker compose --profile public up -d
  ```

Check what you have:

```bash
docker compose ps
docker compose exec certbot certbot certificates
```

---

## What clients use

Your TAK clients now use `yoursubdomain.duckdns.org` instead of a LAN IP.
Certificate enrollment on 8446 and streaming on 8089 work exactly as before —
see [CLIENTS.md](CLIENTS.md).

One difference worth knowing: with Let's Encrypt, **the web UI** uses the
public certificate, but the **TAK ports keep using OpenTAKServer's own CA**.
That is deliberate and required — TAK clients authenticate with client
certificates issued by that CA, so both ends of the handshake must belong to
the same PKI. It also means clients still import the truststore exactly as they
did on the LAN.

The upside of a real certificate: ATAK 1.5.0+ QR code enrollment starts
working, which needs a publicly trusted certificate.

---

## Troubleshooting

**`cert-request` fails with "Timeout during connect"**

Port 80 is not reaching this machine. In order of likelihood: the router
forward is missing or points at the wrong LAN IP; Windows Firewall is blocking
(run `windows-firewall.ps1`); your ISP blocks inbound port 80 (some do — you
can use a different port for the web UI, but ACME HTTP-01 specifically requires
80 to be reachable); or you are behind CGNAT.

**The hostname resolves to the wrong IP**

Your IP changed and the updater has not caught up, or it is not running:

```bash
docker compose ps duckdns
docker compose logs duckdns
```

If it is missing, the `public` profile is not active — start it with
`docker compose --profile public up -d`.

**It worked, then stopped after a reboot**

Almost always the LAN IP changed and the router's forwards now point elsewhere.
Set a DHCP reservation, then run `.\ots.ps1 doctor` to confirm the current IP.

**Certificate expired**

The renewal loop was not running. Check `docker compose ps certbot`, then force
a renewal:

```bash
docker compose run --rm --entrypoint certbot certbot renew --force-renewal
docker compose restart nginx
```

---

## Going back to LAN-only

```bash
docker compose --profile public down
```

Then set `OTS_TLS_MODE=self-signed` in `.env`, run `.\ots.ps1 set-address` to
go back to your LAN IP, and remove the router forwards and firewall rules
(`.\windows-firewall.ps1 -Remove`).

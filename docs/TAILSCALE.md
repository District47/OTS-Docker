# Reaching the server without port forwarding

If port forwarding will not work — your ISP uses CGNAT, blocks inbound ports,
or you simply do not control the router — Tailscale gets you there anyway.

It builds a private encrypted network between your own devices. The server
gets a stable name that works from anywhere, and **nothing is exposed to the
public internet**.

```bash
.\ots.ps1 tailscale on
```

or press **Use Tailscale (no ports)** in the control panel.

---

## What you get, and what it costs

**Works:**

* No port forwarding, no router access, no firewall rules
* Works behind CGNAT, where forwarding is impossible no matter what you try
* **Every** TAK port works — 8089, 8446, 8443, 8883, video, all of it
* A stable name (`yourpc.your-tailnet.ts.net`) that keeps working when the
  machine moves to a different Wi-Fi — no more updating the address
* Traffic is WireGuard-encrypted end to end, on top of TAK's own TLS
* Free for personal use, up to 100 devices

**The trade-off:**

* **Every phone and tablet must also run Tailscale**, signed in to the same
  account. Tailscale has Android and iOS apps.
* The server is *not* public. Someone outside your tailnet cannot reach it —
  which is the point, but it does mean you cannot hand a stranger an address
  and have it work.

If you need a genuinely public server, use [INTERNET.md](INTERNET.md) instead.
The two can coexist: Tailscale does not stop port forwarding from working.

---

## Setup

### 1. On the server

Install Tailscale and sign in:

```bash
winget install -e --id Tailscale.Tailscale
```

Open it from the system tray, sign in, then:

```bash
.\ots.ps1 tailscale on
```

It reads your tailnet name, points the server at it, restarts what needs
restarting, and then **verifies** the web UI and the TAK ports actually answer
over the tailnet before telling you it worked.

Check any time with `.\ots.ps1 tailscale status`.

### 2. On each phone or tablet

1. Install **Tailscale** from the Play Store or App Store
2. Sign in with the **same account** as the server
3. Add the server in ATAK exactly as you would on a LAN — see
   [CLIENTS.md](CLIENTS.md) — using the tailnet name as the address:

   | | |
   |---|---|
   | Address | `yourpc.your-tailnet.ts.net` |
   | Port | `8089` |
   | Protocol | `SSL` |

   Tick **Use Authentication** and **Enroll for Client Certificate**, and
   import the truststore as usual.

That's it. No router touched.

---

## Why not Tailscale Funnel?

Funnel exposes a service to the *public* internet through Tailscale's relays,
which sounds like exactly what you want. It does not work for TAK:

* Funnel listens on **443, 8443 and 10000 only** — enrollment (8446) and CoT
  streaming (8089) are not among them
* Funnel is **HTTPS only**. CoT on 8089 and MQTT on 8883 are raw TLS, not
  HTTP, so they cannot pass through it at all
* Funnel **terminates TLS itself** with a Tailscale certificate, so a TAK
  client's certificate never reaches the server — certificate authentication
  on 8443 breaks even though the port is supported

The same reasoning rules out Cloudflare's proxy (orange cloud). Both are HTTP
reverse proxies; TAK needs a network path, which is what plain Tailscale gives
you.

---

## Going back

```bash
.\ots.ps1 tailscale off
```

Points the server back at its local network address. Tailscale itself is left
alone, so devices on your tailnet can still reach the server — this only
changes which address the tooling advertises.

---

## Troubleshooting

**"Tailscale is installed but not connected"**

Open Tailscale from the system tray and sign in, or run
`& "$env:ProgramFiles\Tailscale\tailscale.exe" up`.

**A client cannot reach the server**

Check the phone is signed in to the same tailnet and shows as connected in the
Tailscale app. On the server, `.\ots.ps1 tailscale status` shows the name
clients should be using.

**The browser still warns about the certificate**

Expected. OpenTAKServer's certificate is issued for the name `opentakserver`
and signed by its own CA, so no hostname matches it — over Tailscale, on a LAN,
or anywhere else. TAK clients validate against the CA in the truststore rather
than the hostname, so this does not affect them.

If the warning bothers you, Tailscale can issue a real certificate for your
`.ts.net` name with `tailscale cert` once HTTPS is enabled in the Tailscale
admin console. That is cosmetic — TAK clients still need the OpenTAKServer
truststore either way, because client-certificate authentication requires both
ends to belong to the same PKI.

**Windows Firewall**

Not usually a problem: Tailscale puts its own network adapter on the
**Private** firewall profile, so inbound connections over the tailnet are
allowed even when your Wi-Fi is marked *Public*. That is one fewer thing to
configure than the port-forwarding route.

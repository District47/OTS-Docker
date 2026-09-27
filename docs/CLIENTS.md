# Connecting TAK clients

Works with ATAK 4.8+, WinTAK, iTAK and TAKX.

The recommended path is **certificate enrollment**: the client asks the server
for its own certificate using a username and password, and everything after
that is automatic. You do not have to build data packages by hand.

The manager's **4. Connect a TAK Client** button shows everything below with
your server's real address filled in, and picks the right method for your
setup automatically.

---

## 1. Create a user

In the web UI (`https://<your-server>`), go to **Users** and add an account for
each device. Do not hand out the `administrator` account. Make sure the account
is **active** — enrollment fails for inactive accounts.

## 2. Which method? It depends on your certificate

Before a phone will send its username and password to the enrollment port
(8446), it has to trust the certificate that port presents.

| Your setup | Enrollment port presents | What the phone needs |
|---|---|---|
| **Let's Encrypt** (after `go-public` + `cert-request`) | a public certificate phones already trust | **nothing** — scan a QR code, or enter the server by hand with default settings |
| **Self-signed** (LAN, Tailscale, or Let's Encrypt not issued yet) | OpenTAKServer's private certificate authority | **the trust store**, imported first |

Either way, once enrollment succeeds the server hands the phone its
certificate authority, which is what the phone uses to trust the streaming
port (8089) from then on.

Not sure which you have? Run `.\ots.ps1 truststore` — with Let's Encrypt active
it tells you no trust store is needed instead of downloading one.

---

## With Let's Encrypt: QR code (easiest)

1. On a computer, open the web UI at **your public name** —
   `https://yourname.duckdns.org`, **not** `https://localhost`. The QR code
   contains whatever address you opened the page with.
2. Log in **as the person who will use the phone** (a QR code enrols the
   account that generated it).
3. In the left menu, click **ATAK QR Code**.
4. In ATAK, add a server using its QR scan option and scan the code.

The code contains the address, the username and a one-time token instead of the
password, and the web UI lets you set when it expires.

## With Let's Encrypt: by hand

1. Hamburger icon (top right) → **Settings**
2. **Network Preferences** → **TAK Servers**
3. Three-dot menu → **Add**
4. Fill in:
   * **Description** — any name you like
   * **Address** — your public name, e.g. `yourname.duckdns.org`
   * **Port** — `8089`
   * **Streaming Protocol** — `SSL`
5. Check **Use Authentication** and enter the username and password
6. Check **Enroll for Client Certificate**
7. **Leave "Use default SSL/TLS Certificates" checked.** Do not import a trust
   store — it would make ATAK trust *only* the private authority and reject the
   public certificate on the enrollment port.
8. Tap **Ok**

---

## Self-signed: import the trust store first — required

Without it, ATAK refuses to connect with *"The TAK Server's identity could not
be verified"*.

**Get the trust store:**

* on the device, browse to `https://<your-server>/api/truststore`, or
* in the web UI, click **Download Truststore**, or
* on the server, run `.\ots.ps1 truststore`

The password is **`atakatak`**. On Android, save it anywhere you can browse to,
such as `Download`.

**Add the server in ATAK:**

1. Hamburger icon (top right) → **Settings**
2. **Network Preferences** → **TAK Servers**
3. Three-dot menu → **Add**
4. Fill in:
   * **Description** — any name you like
   * **Address** — your server's IP, Tailscale name, or domain
   * **Port** — `8089`
   * **Streaming Protocol** — `SSL`
5. Check **Use Authentication**, then enter the username and password
6. Check **Enroll for Client Certificate**
7. Then:
   * uncheck **Use default SSL/TLS Certificates**
   * make sure **Enroll with Preconfigured Trust** is checked
   * tap **Import Trust Store**, pick the file, and enter `atakatak`
8. Tap **Ok**

> Ticking **Enroll for Client Certificate** is not enough on its own.
> Enrollment itself happens over TLS, so the trust has to be in place before
> enrollment can even begin.

QR codes do not work on a self-signed server: a phone scanning one has no trust
store yet, so it has no way to trust the private certificate.

---

The client enrols over port **8446**, receives its certificate, and connects on
port **8089**. You should see it appear under **EUDs** in the web UI within a
few seconds.

## WinTAK and iTAK

The same fields, in slightly different places — add a server, choose the SSL
protocol on port 8089, supply the username and password, and enable certificate
enrollment. Import the truststore only on a self-signed server. The web UI also
has an **iTAK QR Code** item.

---

## If enrollment fails

**"Connection refused" or a timeout**

The device cannot reach the server. From the device's browser, try
`https://<your-server>`. If that fails, it is a network problem, not a TAK
problem — check Windows Firewall and that both devices are on the same network.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**"The TAK Server's identity could not be verified"**

The phone does not trust the enrollment port's certificate. Which fix depends
on your setup:

* **Self-signed:** the trust store was not imported. Follow the self-signed
  steps above — uncheck "Use default SSL/TLS Certificates", check "Enroll with
  Preconfigured Trust", and use **Import Trust Store** (password `atakatak`).
* **Let's Encrypt:** the opposite — a trust store *was* imported, so ATAK only
  trusts the private authority. Delete the server entry and add it again with
  "Use default SSL/TLS Certificates" left checked and no trust store.

**The QR code enrols, then points at "localhost"**

The web UI was opened at `https://localhost` when the code was generated. Open
it at your public name and generate the code again.

**"Invalid certificate" or the client rejects the server**

Same causes as above, or the trust store was imported with the wrong password
(it is `atakatak`).

**Enrollment succeeds but no data flows**

Enrollment uses port 8446 while streaming uses 8089. Confirm 8089 is reachable
and that `ots_eud_handler_ssl` is running:

```bash
.\ots.ps1 status
```

**The address changed**

The server's certificate is issued for the name `opentakserver`, not for your
IP. That is normal and TAK clients accept it. But if you move the server to a
new address, existing clients keep pointing at the old one — update the address
in each client.

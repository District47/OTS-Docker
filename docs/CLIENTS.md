# Connecting TAK clients

Works with ATAK 4.8+, WinTAK, iTAK and TAKX.

The recommended path is **certificate enrollment**: the client asks the server
for its own certificate using a username and password, and everything after
that is automatic. You do not have to build data packages by hand.

---

## 1. Create a user

In the web UI (`https://<your-server>`), go to **Users** and add an account for
each device. Do not hand out the `administrator` account.

## 2. Download the truststore (self-signed only)

Skip this if you set up Let's Encrypt.

Because the server signs its own certificate, clients need a copy of its
certificate authority before they will trust it:

* In the web UI, click **Download Truststore**, or
* browse to `https://<your-server>/api/truststore`

The truststore password is **`atakatak`**.

Copy that file to the device — for Android, anywhere you can browse to, such as
`Download`.

## 3. Add the server in ATAK

1. Hamburger icon (top right) → **Settings**
2. **Network Preferences** → **TAK Servers**
3. Three-dot menu → **Add**
4. Fill in:
   * **Description** — any name you like
   * **Address** — your server's IP or domain
   * **Port** — `8089`
   * **Streaming Protocol** — `SSL`
5. Check **Use Authentication**, then enter the username and password from step 1
6. Check **Enroll for Client Certificate**
7. **If you are using the self-signed certificate:**
   * uncheck **Use default SSL/TLS Certificates**
   * make sure **Enroll with Preconfigured Trust** is checked
   * tap **Import Trust Store**, pick the file from step 2, and enter `atakatak`
8. **If you are using Let's Encrypt:**
   * leave **Use default SSL/TLS Certificates** checked
   * uncheck **Enroll with Preconfigured Trust**
9. Tap **Ok**

The client enrols over port **8446**, receives its certificate, and connects on
port **8089**. You should see it appear under **EUDs** in the web UI within a
few seconds.

## WinTAK and iTAK

The same fields, in slightly different places — add a server, choose the SSL
protocol on port 8089, supply the username and password, and enable certificate
enrollment. Import the truststore when using the self-signed certificate.

## QR codes

ATAK 1.5.0 and newer can be enrolled by scanning a QR code from the web UI.
This only works when the server uses a **Let's Encrypt** certificate — a
self-signed server cannot be trusted from a bare link.

---

## If enrollment fails

**"Connection refused" or a timeout**

The device cannot reach the server. From the device's browser, try
`https://<your-server>`. If that fails, it is a network problem, not a TAK
problem — check Windows Firewall and that both devices are on the same network.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**"Invalid certificate" or the client rejects the server**

You are on a self-signed certificate and skipped the truststore import, or
imported it with the wrong password (it is `atakatak`).

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

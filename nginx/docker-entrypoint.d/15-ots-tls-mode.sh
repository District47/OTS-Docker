#!/usr/bin/env sh
# ============================================================================
#  Decides which certificate the web UI (443) and certificate enrollment
#  (8446) present, and makes sure the OpenTAKServer CA exists before nginx
#  tries to load it.
#
#  With Let's Encrypt, both get the public certificate. For 8446 that is what
#  makes ATAK's QR-code enrollment work: a phone scanning a QR code has no
#  trust store yet, so it can only trust a publicly issued certificate. The
#  enrollment reply then hands the phone the OpenTAKServer CA, which is what
#  it trusts 8089 with from then on.
#
#  8443 and 8883 always use the OpenTAKServer CA - see includes/tak_certificate.
# ============================================================================
set -e

ME="$(basename "$0")"
INCLUDE_DIR=/etc/nginx/includes.d

OTS_CERT=/app/ots/ca/certs/opentakserver/opentakserver.pem
OTS_KEY=/app/ots/ca/certs/opentakserver/opentakserver.nopass.key
LE_DIR="/etc/letsencrypt/live/${OTS_FQDN}"

mkdir -p "$INCLUDE_DIR"

# ---------------------------------------------------------------------------
# OpenTAKServer creates the CA on its first start. Compose already waits for
# it to be healthy, but wait here too so a slow first run cannot leave nginx
# in a crash loop over a missing certificate file.
# ---------------------------------------------------------------------------
waited=0
while [ ! -f "$OTS_CERT" ] && [ "$waited" -lt 120 ]; do
    if [ "$waited" = "0" ]; then
        echo "$ME: waiting for the OpenTAKServer CA to be created..."
    fi
    sleep 2
    waited=$((waited + 2))
done

if [ ! -f "$OTS_CERT" ]; then
    echo "$ME: ERROR - $OTS_CERT still does not exist after ${waited}s."
    echo "$ME: Check 'docker compose logs ots' - the server may have failed to start."
    exit 1
fi

# ---------------------------------------------------------------------------
# Web UI (443) and enrollment (8446) certificates
# ---------------------------------------------------------------------------
if [ "$OTS_TLS_MODE" = "letsencrypt" ] && [ -f "${LE_DIR}/fullchain.pem" ]; then
    echo "$ME: web UI and enrollment (8446) use the Let's Encrypt certificate for ${OTS_FQDN}"
    echo "$ME: QR-code enrollment is available; clients do not need the trust store"
    CERT="${LE_DIR}/fullchain.pem"
    KEY="${LE_DIR}/privkey.pem"
else
    if [ "$OTS_TLS_MODE" = "letsencrypt" ]; then
        echo "$ME: OTS_TLS_MODE=letsencrypt but no certificate exists at ${LE_DIR}."
        echo "$ME: Falling back to the OpenTAKServer CA. Issue one with: .\\ots.ps1 cert-request"
    else
        echo "$ME: web UI and enrollment use the self-signed OpenTAKServer certificate"
    fi
    echo "$ME: clients must import the trust store before enrolling"
    CERT="${OTS_CERT}"
    KEY="${OTS_KEY}"
fi

for name in webui_certificate enrollment_certificate; do
    cat > "$INCLUDE_DIR/$name" <<EOF
ssl_certificate     ${CERT};
ssl_certificate_key ${KEY};
EOF
done

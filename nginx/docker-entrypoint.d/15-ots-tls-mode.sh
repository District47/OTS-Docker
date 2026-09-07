#!/usr/bin/env sh
# ============================================================================
#  Decides which certificate the web UI (port 443) presents, and makes sure
#  the OpenTAKServer CA exists before nginx tries to load it.
#
#  The TAK ports always use the OpenTAKServer CA - see includes/tak_certificate.
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
# Web UI certificate
# ---------------------------------------------------------------------------
if [ "$OTS_TLS_MODE" = "letsencrypt" ] && [ -f "${LE_DIR}/fullchain.pem" ]; then
    echo "$ME: web UI is using the Let's Encrypt certificate for ${OTS_FQDN}"
    cat > "$INCLUDE_DIR/webui_certificate" <<EOF
ssl_certificate     ${LE_DIR}/fullchain.pem;
ssl_certificate_key ${LE_DIR}/privkey.pem;
EOF
else
    if [ "$OTS_TLS_MODE" = "letsencrypt" ]; then
        echo "$ME: OTS_TLS_MODE=letsencrypt but no certificate exists at ${LE_DIR}."
        echo "$ME: Falling back to the OpenTAKServer CA. Issue one with: .\\ots.ps1 cert-request"
    else
        echo "$ME: web UI is using the self-signed OpenTAKServer certificate"
    fi
    cat > "$INCLUDE_DIR/webui_certificate" <<EOF
ssl_certificate     ${OTS_CERT};
ssl_certificate_key ${OTS_KEY};
EOF
fi

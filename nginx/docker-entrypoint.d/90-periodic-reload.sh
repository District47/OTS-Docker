#!/usr/bin/env sh
# ============================================================================
#  Reload nginx periodically so renewed certificates are picked up.
#
#  certbot runs in its own container and renews the Let's Encrypt certificate
#  roughly every 60 days. It has no way to signal this container, so without
#  this loop nginx would keep serving the certificate it loaded at startup and
#  start handing out an EXPIRED one about 90 days in.
#
#  A reload is graceful - existing connections finish on the old worker - so
#  doing it on a timer costs nothing.
#
#  Only runs when Let's Encrypt is actually in use; a self-signed install has
#  nothing to renew.
# ============================================================================
set -e

ME="$(basename "$0")"

if [ "${OTS_TLS_MODE}" != "letsencrypt" ]; then
    exit 0
fi

RELOAD_INTERVAL="${OTS_NGINX_RELOAD_INTERVAL:-21600}"   # 6 hours

echo "$ME: will reload every ${RELOAD_INTERVAL}s to pick up renewed certificates"

# Backgrounded here, then the entrypoint execs nginx and this loop is
# reparented to init. 'nginx -s reload' signals the master via its pid file.
(
    while true; do
        sleep "$RELOAD_INTERVAL"
        if [ -f /var/run/nginx.pid ]; then
            nginx -s reload 2>/dev/null || true
        fi
    done
) &

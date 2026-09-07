# ============================================================================
#  nginx for OpenTAKServer
#
#  Built on top of the published OpenTAKServer-UI image, which is nginx with
#  the compiled web UI already at /usr/share/nginx/html. We layer on our own
#  nginx.conf (which adds a stream{} block for MQTT), the config templates,
#  and the entrypoint scripts.
#
#  Building locally - rather than bind-mounting these files - keeps the
#  executable bits correct, which a Windows bind mount cannot guarantee.
# ============================================================================
ARG OTS_UI_VERSION=master
FROM ghcr.io/brian7704/opentakserver-ui:${OTS_UI_VERSION}

# The stock catch-all site would otherwise claim port 80 ahead of our config.
RUN rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /etc/nginx/stream.d /etc/nginx/includes.d /var/www/certbot

COPY nginx.conf /etc/nginx/nginx.conf
COPY includes/ /etc/nginx/includes.d/
COPY templates/ /etc/nginx/templates/
COPY stream-templates/ /etc/nginx/stream-templates/
COPY --chmod=0755 docker-entrypoint.d/ /docker-entrypoint.d/

EXPOSE 80 443 8080 8443 8446 8883

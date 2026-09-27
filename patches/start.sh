#!/bin/sh
# Applies the runtime fixes in apply.py, then runs the service's real command
# as the unprivileged "ots" user. See apply.py for what is fixed and why.
#
# Compose starts these containers as root only so that apply.py can edit
# code that some of the published images install read-only. Privileges are
# dropped before the service itself runs. A failure to patch never stops the
# service from starting.
/app/venv/bin/python3 /ots-patches/apply.py || true

if [ "$(id -u)" = "0" ]; then
    HOME="$(getent passwd ots | cut -d: -f6)"
    export HOME
    exec setpriv --reuid=ots --regid=ots --init-groups -- "$@"
fi
exec "$@"

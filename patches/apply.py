"""
Runtime fixes for the published OpenTAKServer images, applied at container
start by start.sh. Each fix is a literal find-and-replace that is safe to run
on every start: once applied, or once upstream changes the code, the pattern
no longer matches and nothing happens. This script never stops a container
from starting.

Fix 1 - RabbitMQ credentials missing from the Socket.IO message queue URL
------------------------------------------------------------------------------
app.py and cot_parser.py build it as

    "amqp://" + app.config.get("OTS_RABBITMQ_SERVER_ADDRESS")

with no username or password, so the AMQP client falls back to guest/guest.
This stack has no guest account - RabbitMQ only allows guest from localhost,
and the broker is shared with internet-facing MQTT - so every attempt is
refused. The effects:

  * the thread serving each connected TAK client crashes about every 40
    seconds when it sends a live update to the web UI, so ATAK reports
    "data reception timeout" and reconnects, over and over;
  * the main server retries the login roughly 1,000 times a minute;
  * the web UI's live updates never arrive.

Adding the configured OTS_RABBITMQ_USERNAME/PASSWORD to the URL fixes all
three. Present in OpenTAKServer 1.7.13 and in upstream master at the time of
writing.
"""
import importlib.util
import os
import py_compile
import sys

BROKEN = 'message_queue="amqp://" + app.config.get("OTS_RABBITMQ_SERVER_ADDRESS")'
FIXED = (
    'message_queue="amqp://"'
    ' + __import__("urllib.parse").parse.quote(str(app.config.get("OTS_RABBITMQ_USERNAME")), safe="")'
    ' + ":"'
    ' + __import__("urllib.parse").parse.quote(str(app.config.get("OTS_RABBITMQ_PASSWORD")), safe="")'
    ' + "@" + app.config.get("OTS_RABBITMQ_SERVER_ADDRESS")'
)


def package_dirs():
    # find_spec locates the package without importing (running) it.
    spec = importlib.util.find_spec("opentakserver")
    return list(spec.submodule_search_locations) if spec else []


def main():
    tag = "[ots-patches]"
    dirs = package_dirs()
    if not dirs:
        print(f"{tag} opentakserver package not found - nothing to patch", flush=True)
        return

    patched = already = failed = 0
    for root in dirs:
        for dirpath, _, files in os.walk(root):
            for name in files:
                if not name.endswith(".py"):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root)
                try:
                    with open(path, encoding="utf-8") as f:
                        text = f.read()
                except OSError:
                    continue
                if FIXED in text and BROKEN not in text:
                    already += 1
                    continue
                if BROKEN not in text:
                    continue
                try:
                    with open(path, "w", encoding="utf-8") as f:
                        f.write(text.replace(BROKEN, FIXED))
                    # Compile it now: refreshes the stale .pyc, and if the
                    # edit somehow broke the file, put the original back.
                    try:
                        py_compile.compile(path, doraise=True)
                    except py_compile.PyCompileError as e:
                        with open(path, "w", encoding="utf-8") as f:
                            f.write(text)
                        failed += 1
                        print(f"{tag} WARNING: patched {rel} did not compile - original restored: {e}",
                              flush=True)
                        continue
                    patched += 1
                    print(f"{tag} RabbitMQ credentials added to the Socket.IO queue URL in {rel}",
                          flush=True)
                except OSError as e:
                    failed += 1
                    print(f"{tag} WARNING: could not patch {rel}: {e}", flush=True)

    if failed:
        print(f"{tag} WARNING: {failed} file(s) left unpatched - TAK clients may see "
              "'data reception timeout'", flush=True)
    elif patched == 0 and already == 0:
        print(f"{tag} Socket.IO queue URL pattern not found - upstream may have fixed it; "
              "nothing changed", flush=True)
    elif patched == 0:
        print(f"{tag} already applied ({already} file(s))", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never block startup
        print(f"[ots-patches] WARNING: patching failed: {e}", file=sys.stderr, flush=True)

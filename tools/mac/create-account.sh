#!/bin/bash
# Create a game account via a short-lived mangosd console (same as tools/create-account.ps1).
set -euo pipefail
# shellcheck source=dev-common.sh
. "$(dirname "$0")/dev-common.sh"

NAME="${1:-player}"
PASS="${2:-player}"
GM="${3:-6}"

bash "$(dirname "$0")/layout-run.sh"
bash "$(dirname "$0")/apply-config.sh"

if port_open 8085; then
    echo 'Stop mangosd first (tools/mac/stop.sh).' >&2
    exit 1
fi
if ! port_open 3306; then
    echo 'MariaDB is not running. tools/mac/setup-db.sh or tools/mac/play.sh starts it.' >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
echo "Creating account $NAME (gm $GM)..."
(
    cd "$RUN_DIR"
    # Feed console commands after mangosd is up.
    {
        # wait until ready-ish
        for _ in $(seq 1 120); do
            if nc -z 127.0.0.1 8085 >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        sleep 2
        printf '\naccount create %s %s\n' "$NAME" "$PASS"
        if [ "$GM" -gt 0 ]; then
            sleep 2
            printf 'account set gmlevel %s %s\n' "$NAME" "$GM"
        fi
        sleep 3
        printf 'server exit\n'
        sleep 2
    } | ./mangosd -c mangosd.conf >"$LOG_DIR/create-account.log" 2>&1
) || true

if rg -q "Account created|Account '$NAME'|" "$LOG_DIR/create-account.log" 2>/dev/null \
    || rg -qi "created|gmlevel" "$LOG_DIR/create-account.log" 2>/dev/null; then
    echo "Account $NAME ready (see $LOG_DIR/create-account.log)."
else
    echo "Check $LOG_DIR/create-account.log — mangosd may have printed the result there."
    tail -40 "$LOG_DIR/create-account.log" || true
fi

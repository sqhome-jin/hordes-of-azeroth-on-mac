#!/bin/bash
set -euo pipefail
# shellcheck source=dev-common.sh
. "$(dirname "$0")/dev-common.sh"

for name in mangosd realmd; do
    if pgrep -x "$name" >/dev/null 2>&1; then
        echo "Stopping $name..."
        pkill -x "$name" || true
    fi
done

if [ -f "$LOG_DIR/mariadbd.pid" ]; then
    pid="$(cat "$LOG_DIR/mariadbd.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        echo "Stopping MariaDB pid $pid..."
        if [ -x "$MARIA_DIR/bin/mariadb-admin" ]; then
            "$MARIA_DIR/bin/mariadb-admin" --skip-ssl -h 127.0.0.1 -u root -proot shutdown || kill "$pid" || true
        else
            kill "$pid" || true
        fi
    fi
    rm -f "$LOG_DIR/mariadbd.pid"
elif port_open 3306; then
    echo 'MariaDB still listening; trying mariadb-admin shutdown...'
    "$MARIA_DIR/bin/mariadb-admin" --skip-ssl -h 127.0.0.1 -u root -proot shutdown 2>/dev/null || true
fi

echo 'Stopped.'

#!/bin/bash
# Shared paths for Mac development scripts. Source from other tools/mac/*.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT
CONFIG_DIR="$ROOT/config"
SERVER_DIR="$ROOT/server"
RUN_DIR="$SERVER_DIR/run"
DATA_DIR="$SERVER_DIR/data"
LOG_DIR="$SERVER_DIR/logs"
MARIA_DIR="$SERVER_DIR/mariadb"
MARIA_DATA="$SERVER_DIR/mariadb-data"
WOW_DATA="${WOW_DATA:-$ROOT/client/wow-data}"
BREW_MARIA="$(brew --prefix mariadb 2>/dev/null || true)"

port_open() {
    local port="$1"
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

wait_port() {
    local port="$1" seconds="${2:-60}" what="${3:-port $1}"
    local i=0
    while ! port_open "$port"; do
        i=$((i + 1))
        if [ "$i" -ge "$seconds" ]; then
            echo "Timed out waiting for $what" >&2
            return 1
        fi
        sleep 1
    done
}

sql() {
    # VMaNGOS dumps use MyISAM + varchar(255); utf8mb4 exceeds the 1000-byte key limit.
    "$MARIA_DIR/bin/mariadb" --skip-ssl --default-character-set=utf8mb3 -h 127.0.0.1 -P 3306 -u root -proot "$@"
}

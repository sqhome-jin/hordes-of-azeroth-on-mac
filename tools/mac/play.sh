#!/bin/bash
# Start MariaDB + realmd + mangosd, then the game client (player/player).
set -euo pipefail
# shellcheck source=dev-common.sh
. "$(dirname "$0")/dev-common.sh"

bash "$(dirname "$0")/layout-run.sh"
bash "$(dirname "$0")/apply-config.sh"

mkdir -p "$LOG_DIR"

if ! port_open 3306; then
    echo 'Starting MariaDB...'
    "$MARIA_DIR/bin/mariadbd" \
        --defaults-file="$CONFIG_DIR/mariadb.ini" \
        --basedir="$MARIA_DIR" \
        --datadir="$MARIA_DATA" \
        >"$LOG_DIR/mariadb.log" 2>&1 &
    echo $! > "$LOG_DIR/mariadbd.pid"
    wait_port 3306 60 MariaDB
else
    echo 'MariaDB already running'
fi

if ! port_open 3724; then
    echo 'Starting realmd...'
    (cd "$RUN_DIR" && ./realmd -c realmd.conf >"$LOG_DIR/realmd.log" 2>&1 & echo $! > "$LOG_DIR/realmd.pid")
    wait_port 3724 30 realmd
else
    echo 'realmd already running'
fi

if ! port_open 8085; then
    if [ ! -d "$DATA_DIR/maps" ] && [ ! -d "$DATA_DIR/5875" ]; then
        echo "Missing extracted maps under $DATA_DIR. Run tools/mac/extract-client-data.sh first." >&2
        exit 1
    fi
    echo 'Starting mangosd (world load takes a moment)...'
    (cd "$RUN_DIR" && ./mangosd -c mangosd.conf >"$LOG_DIR/mangosd.log" 2>&1 & echo $! > "$LOG_DIR/mangosd.pid")
    wait_port 8085 300 mangosd
else
    echo 'mangosd already running'
fi

echo 'Server ready on 127.0.0.1'

CLIENT_BIN=""
for candidate in \
    "$ROOT/release/build/macos/client/HordesOfAzeroth" \
    "$CARGO_TARGET_DIR/ship/HordesOfAzeroth" \
    "$CARGO_TARGET_DIR/debug/HordesOfAzeroth" \
    "$ROOT/client/target/ship/HordesOfAzeroth" \
    "$ROOT/client/target/debug/HordesOfAzeroth"
do
    if [ -x "$candidate" ]; then
        CLIENT_BIN="$candidate"
        break
    fi
done

if [ -z "$CLIENT_BIN" ]; then
    echo 'Building client (ship profile)...'
    (
        cd "$ROOT/client"
        cargo build --profile ship --locked -p hoa --no-default-features
    )
    CLIENT_BIN="$ROOT/client/target/ship/HordesOfAzeroth"
    if [ ! -x "$CLIENT_BIN" ] && [ -n "${CARGO_TARGET_DIR:-}" ]; then
        CLIENT_BIN="$CARGO_TARGET_DIR/ship/HordesOfAzeroth"
    fi
fi

export WOW_DATA
export WOW_USER="${WOW_USER:-player}"
export WOW_PASS="${WOW_PASS:-player}"
mkdir -p "$ROOT/WTF"
printf 'set realmlist 127.0.0.1\n' > "$ROOT/realmlist.wtf"
echo "Launching $CLIENT_BIN (WOW_DATA=$WOW_DATA)..."
exec "$CLIENT_BIN"

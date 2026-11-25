#!/bin/bash
# Create datadir, import vmangos db_latest, apply migrations, register the realm.
set -euo pipefail
# shellcheck source=dev-common.sh
. "$(dirname "$0")/dev-common.sh"

bash "$(dirname "$0")/layout-run.sh"
mkdir -p "$LOG_DIR"

if [ ! -d "$MARIA_DATA/mysql" ]; then
    if port_open 3306; then
        echo 'Port 3306 is in use but no project datadir exists. Stop that MariaDB first.' >&2
        exit 1
    fi
    mkdir -p "$MARIA_DATA" "$ROOT/HordesOfAzeroth"
    root_sql="$ROOT/HordesOfAzeroth/root-password.sql"
    printf "%s\n" "UPDATE mysql.global_priv SET priv = JSON_SET(priv, '\$.plugin', 'mysql_native_password', '\$.authentication_string', PASSWORD('root')) WHERE User = 'root';" > "$root_sql"
    (
        cd "$MARIA_DIR"
        ./scripts/mariadb-install-db \
            --defaults-file="$CONFIG_DIR/mariadb.ini" \
            --basedir=. \
            --datadir="$MARIA_DATA" \
            --auth-root-authentication-method=normal \
            --extra-file="$root_sql"
    )
    rm -f "$root_sql"
    echo 'Datadir created.'
else
    echo "Datadir already exists at $MARIA_DATA."
fi

if ! port_open 3306; then
    echo 'Starting MariaDB...'
    : >"$LOG_DIR/mariadb-bootstrap.log"
    daemonize "$LOG_DIR/mariadbd.pid" \
        "$MARIA_DIR/bin/mariadbd" \
        --defaults-file="$CONFIG_DIR/mariadb.ini" \
        --basedir="$MARIA_DIR" \
        --datadir="$MARIA_DATA" \
        >>"$LOG_DIR/mariadb-bootstrap.log" 2>&1
    wait_port 3306 60 MariaDB
else
    echo 'MariaDB already running on 3306.'
fi

DUMP_DIR="$SERVER_DIR/downloads/db/mysql-dump"
if [ ! -f "$DUMP_DIR/mangos.sql" ]; then
    mkdir -p "$SERVER_DIR/downloads"
    echo 'Resolving vmangos db_latest asset...'
    zip_url="$(curl -sL 'https://api.github.com/repos/vmangos/core/releases/tags/db_latest' \
        | python3 -c 'import sys,json; assets=json.load(sys.stdin).get("assets",[]);
print(next(a["browser_download_url"] for a in assets if a["name"].startswith("db-") and "sqlite" not in a["name"]))')"
    zip="$SERVER_DIR/downloads/db_latest.zip"
    echo "Downloading $zip_url ..."
    curl -L --fail -o "$zip" "$zip_url"
    rm -rf "$SERVER_DIR/downloads/db"
    mkdir -p "$SERVER_DIR/downloads/db"
    unzip -q "$zip" -d "$SERVER_DIR/downloads/db"
    found="$(find "$SERVER_DIR/downloads/db" -type d -name mysql-dump | head -1)"
    if [ -z "$found" ]; then
        found="$(find "$SERVER_DIR/downloads/db" -type f -name mangos.sql | head -1)"
        [ -n "$found" ] && found="$(dirname "$found")"
    fi
    if [ -z "$found" ]; then
        echo 'db_latest archive did not contain mangos.sql / mysql-dump' >&2
        exit 1
    fi
    abs_found="$(cd "$found" && pwd)"
    mkdir -p "$(dirname "$DUMP_DIR")"
    abs_dump="$(mkdir -p "$(dirname "$DUMP_DIR")" && cd "$(dirname "$DUMP_DIR")" && pwd)/mysql-dump"
    if [ "$abs_found" != "$abs_dump" ]; then
        rm -rf "$DUMP_DIR"
        mv "$found" "$DUMP_DIR"
    fi
fi

# MariaDB 11+/13 maps CHARSET=utf8 to utf8mb4 in some builds; MyISAM keys then exceed 1000 bytes.
for f in logon.sql logs.sql characters.sql mangos.sql; do
    if [ -f "$DUMP_DIR/$f" ] && ! grep -q 'CHARSET=utf8mb3' "$DUMP_DIR/$f"; then
        echo "Normalizing charset in $f..."
        sed -i.bak 's/CHARSET=utf8mb4/CHARSET=utf8mb3/g; s/CHARSET=utf8/CHARSET=utf8mb3/g; s/utf8mb4_/utf8mb3_/g; s/utf8_/utf8mb3_/g' "$DUMP_DIR/$f"
    fi
done

echo 'Creating databases...'
sql -e "DROP DATABASE IF EXISTS realmd; DROP DATABASE IF EXISTS characters; DROP DATABASE IF EXISTS mangos; DROP DATABASE IF EXISTS logs;"
sql < "$CONFIG_DIR/create-databases.sql"
echo 'Importing logon...'
sql realmd < "$DUMP_DIR/logon.sql"
echo 'Importing logs...'
sql logs < "$DUMP_DIR/logs.sql"
echo 'Importing characters...'
sql characters < "$DUMP_DIR/characters.sql"
echo 'Importing world (this takes a while)...'
sql mangos < "$DUMP_DIR/mangos.sql"
sql -e "INSERT INTO realmd.realmlist (id, name, address, port) VALUES (1, 'Hordes of Azeroth', '127.0.0.1', 8085) ON DUPLICATE KEY UPDATE name=VALUES(name), address=VALUES(address), port=VALUES(port)"

echo 'Applying migrations...'
applied=0
for file in "$SERVER_DIR"/core/sql/migrations/*.sql; do
    base="$(basename "$file" .sql)"
    if [[ ! "$base" =~ ^([0-9]{14})_(world|characters|logon)$ ]]; then
        continue
    fi
    id="${BASH_REMATCH[1]}"
    kind="${BASH_REMATCH[2]}"
    case "$kind" in
        world) db=mangos ;;
        characters) db=characters ;;
        logon) db=realmd ;;
    esac
    known="$(sql -N -B "$db" -e "SELECT COUNT(*) FROM \`migrations\` WHERE \`id\` = '$id'")"
    if [ "${known:-0}" -gt 0 ]; then
        continue
    fi
    echo "Applying $(basename "$file") -> $db"
    sql "$db" < "$file"
    applied=$((applied + 1))
done
echo "$applied migration(s) applied"
echo 'Database setup done. MariaDB left running on 127.0.0.1:3306.'

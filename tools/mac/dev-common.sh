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
# Locale for client MPQs: zhCN (default) or enUS. Override with WOW_LOCALE=enUS.
WOW_LOCALE="${WOW_LOCALE:-zhCN}"
_wow_root="$ROOT/client/wow-data"
# Install root for extractors (directory that contains Data/).
if [ -n "${WOW_INSTALL:-}" ]; then
    :
elif [ -n "${WOW_DATA_INSTALL:-}" ]; then
    WOW_INSTALL="$WOW_DATA_INSTALL"
elif [ "$WOW_LOCALE" = "zhCN" ] && [ -d "$_wow_root/zhCN/Data" ]; then
    WOW_INSTALL="$_wow_root/zhCN"
elif [ -d "$_wow_root/Data.$WOW_LOCALE" ]; then
    WOW_INSTALL="$_wow_root"
elif [ -d "$_wow_root/Data" ]; then
    WOW_INSTALL="$_wow_root"
else
    WOW_INSTALL="$_wow_root"
fi
# Keep a Data/ symlink under the shared wow-data root for tools that expect it.
if [ "$WOW_LOCALE" = "zhCN" ] && [ -d "$_wow_root/zhCN/Data" ]; then
    ln -sfn zhCN/Data "$_wow_root/Data"
elif [ -d "$_wow_root/Data.$WOW_LOCALE" ]; then
    ln -sfn "Data.$WOW_LOCALE" "$_wow_root/Data"
elif [ -d "$_wow_root/Data.enUS" ] && [ ! -e "$_wow_root/Data" ]; then
    ln -sfn Data.enUS "$_wow_root/Data"
fi
# Client binary expects the MPQ directory itself ($WOW_DATA).
if [ -z "${WOW_DATA:-}" ] || [ "$WOW_DATA" = "$WOW_INSTALL" ] || [ "$WOW_DATA" = "$_wow_root" ]; then
    if [ -d "$WOW_INSTALL/Data" ]; then
        WOW_DATA="$WOW_INSTALL/Data"
    elif [ -d "$_wow_root/Data.$WOW_LOCALE" ]; then
        WOW_DATA="$_wow_root/Data.$WOW_LOCALE"
    elif [ -d "$_wow_root/zhCN/Data" ] && [ "$WOW_LOCALE" = "zhCN" ]; then
        WOW_DATA="$_wow_root/zhCN/Data"
    else
        WOW_DATA="$WOW_INSTALL"
    fi
fi
unset _wow_root
export WOW_LOCALE WOW_INSTALL WOW_DATA
BREW_MARIA="$(brew --prefix mariadb 2>/dev/null || true)"

# MariaDB Connector/C 3.4+ requires TLS peer verification unless this is set;
# our brew mysqld is started with skip-ssl for local single-player use.
export MARIADB_TLS_DISABLE_PEER_VERIFICATION=1

# Double-fork so MariaDB (and other daemons) survive the Cursor/agent shell exiting.
# Keeps the caller's cwd (realmd/mangosd expect to run from server/run).
daemonize() {
    local pidfile="$1"
    shift
    python3 - "$pidfile" "$@" <<'PY'
import os, sys, time
pidfile, cmd = sys.argv[1], sys.argv[2:]
cwd = os.getcwd()
# Resolve relative binaries before detaching.
cmd = [os.path.abspath(cmd[0]), *cmd[1:]]
if os.fork() > 0:
    for _ in range(50):
        if os.path.exists(pidfile):
            break
        time.sleep(0.1)
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
os.chdir(cwd)
os.umask(0)
# Keep stdin open on a pipe so console-driven servers (mangosd) do not see EOF and exit.
r, w = os.pipe()
if os.fork() == 0:
    os.close(r)
    while True:
        time.sleep(3600)
    sys.exit(0)
os.close(w)
os.dup2(r, 0)
os.close(r)
with open(pidfile, "w", encoding="utf-8") as f:
    f.write(str(os.getpid()))
os.execv(cmd[0], cmd)
PY
}

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

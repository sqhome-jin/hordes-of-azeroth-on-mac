#!/bin/bash
set -euo pipefail

part="${1:-all}"
client_source="$2"
server_source="$3"
out="$4"
work="${HOA_MAC_BUILD_WORK:-$HOME/.cache/hoa-mac-build}"
openssl_root="$(brew --prefix openssl@4 2>/dev/null || brew --prefix openssl@3 2>/dev/null || true)"
mariadb_root="$(brew --prefix mariadb-connector-c 2>/dev/null || true)"

if [ -z "$openssl_root" ] || [ -z "$mariadb_root" ]; then
    echo 'Install build deps: brew install cmake openssl@4 mariadb-connector-c pkg-config' >&2
    exit 1
fi

export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:${PATH:-}"
export OPENSSL_ROOT_DIR="$openssl_root"
export PKG_CONFIG_PATH="$openssl_root/lib/pkgconfig:$mariadb_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

sync_source() {
    mkdir -p "$2"
    rsync -a --delete --exclude=.git --exclude=/target "$1/" "$2/"
}

set_rpath() {
    local binary="$1"
    install_name_tool -add_rpath '@loader_path' "$binary" 2>/dev/null || true
    local lib
    for lib in $(otool -L "$binary" | awk '/libmariadb|libssl|libcrypto/{print $1}'); do
        case "$lib" in
            @*) continue ;;
        esac
        install_name_tool -change "$lib" "@loader_path/$(basename "$lib")" "$binary" 2>/dev/null || true
    done
}

build_server() {
    sync_source "$server_source" "$work/src/server"
    cmake -S "$work/src/server" -B "$work/cache/server" -DCMAKE_BUILD_TYPE=Release -DBUILD_EXTRACTORS=1 -DBUILD_FOR_HOST_CPU=OFF \
        -DCMAKE_INSTALL_PREFIX="$work/install/server" \
        -DMYSQL_INCLUDE_DIR="$mariadb_root/include/mariadb" \
        -DMYSQL_LIBRARY="$mariadb_root/lib/libmariadb.dylib"
    if ! cmake --build "$work/cache/server" -j"$(sysctl -n hw.ncpu)" > "$work/server-build.log" 2>&1; then
        grep -E 'error:|fatal error' "$work/server-build.log" | sort -u | head -40
        echo 'macOS server build failed' >&2
        exit 1
    fi
    rm -rf "$work/install/server"
    cmake --install "$work/cache/server"
    local bin="$work/install/server/bin"
    # Prefer the versioned connector name mangosd links against (libmariadb.3.dylib).
    if [ -f "$mariadb_root/lib/libmariadb.3.dylib" ]; then
        cp -L "$mariadb_root/lib/libmariadb.3.dylib" "$bin/"
        ln -sfn libmariadb.3.dylib "$bin/libmariadb.dylib"
    else
        cp -L "$mariadb_root/lib/libmariadb.dylib" "$bin/"
    fi
    # Ship OpenSSL dylibs next to the binaries (Homebrew links absolute paths at build time).
    for lib in "$openssl_root/lib"/libssl.*.dylib "$openssl_root/lib"/libcrypto.*.dylib; do
        [ -f "$lib" ] || continue
        case "$lib" in
            *.dylib) cp -L "$lib" "$bin/" ;;
        esac
    done
    for binary in "$bin/mangosd" "$bin/realmd"; do
        set_rpath "$binary"
        strip -x "$binary" || true
    done
    if [ -d "$bin/Extractors" ]; then
        find "$bin/Extractors" -type f -perm +111 -print0 | while IFS= read -r -d '' extractor; do
            set_rpath "$extractor"
            strip -x "$extractor" || true
        done
    fi
    rm -rf "$out/server"
    mkdir -p "$out/server"
    cp -a "$work/install/server/." "$out/server/"
}

build_client() {
    if [ ! -x "$HOME/.cargo/bin/cargo" ] && ! command -v cargo >/dev/null; then
        curl -sSf https://sh.rustup.rs | sh -s -- -y -q --default-toolchain none
    fi
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    sync_source "$client_source" "$work/src/client"
    cd "$work/src/client"
    rustup toolchain install --profile minimal >/dev/null 2>&1 || true
    if ! CARGO_TARGET_DIR="$work/cache/client" cargo build --profile ship --locked -p hoa --no-default-features > "$work/client-build.log" 2>&1; then
        grep -E -A5 '^error' "$work/client-build.log" || true
        echo 'macOS client build failed' >&2
        exit 1
    fi
    grep -E 'Finished' "$work/client-build.log" || true
    mkdir -p "$out/client"
    cp "$work/cache/client/ship/HordesOfAzeroth" "$out/client/"
    strip -x "$out/client/HordesOfAzeroth" || true
}

mkdir -p "$work"

case "$part" in
    server) build_server ;;
    client) build_client ;;
    all) build_server; build_client ;;
    *) echo "usage: $0 server|client|all <client_source> <server_source> <out>" >&2; exit 2 ;;
esac

find "$out" -maxdepth 3 -type f \( -name HordesOfAzeroth -o -name mangosd -o -name realmd -o -name 'libmariadb*' \) -print

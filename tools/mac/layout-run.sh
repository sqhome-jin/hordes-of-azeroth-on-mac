#!/bin/bash
# Arrange server/run like the Linux player layout (binaries + conf next to each other).
set -euo pipefail
# shellcheck source=dev-common.sh
. "$(dirname "$0")/dev-common.sh"

if [ -z "$BREW_MARIA" ] || [ ! -d "$BREW_MARIA" ]; then
    echo 'Install MariaDB: brew install mariadb' >&2
    exit 1
fi

mkdir -p "$RUN_DIR" "$LOG_DIR" "$DATA_DIR"
ln -sfn "$BREW_MARIA" "$MARIA_DIR"

echo "WOW locale=$WOW_LOCALE install=$WOW_INSTALL client WOW_DATA=$WOW_DATA"

# CMake install puts binaries under bin/ and conf under etc/.
ln -sfn bin/mangosd "$RUN_DIR/mangosd"
ln -sfn bin/realmd "$RUN_DIR/realmd"
ln -sfn etc/mangosd.conf.dist "$RUN_DIR/mangosd.conf.dist"
ln -sfn etc/realmd.conf.dist "$RUN_DIR/realmd.conf.dist"
ln -sfn bin/Extractors "$RUN_DIR/Extractors"

# Ship connector next to server bins and rewrite absolute Homebrew paths.
MARIA_CONN="$(brew --prefix mariadb-connector-c)"
OPENSSL_ROOT="$(brew --prefix openssl@4 2>/dev/null || brew --prefix openssl@3)"
copy_lib() {
    local src="$1" dest="$2"
    rm -f "$dest"
    cp -L "$src" "$dest"
    chmod u+w "$dest"
}
if [ -f "$MARIA_CONN/lib/libmariadb.3.dylib" ]; then
    copy_lib "$MARIA_CONN/lib/libmariadb.3.dylib" "$RUN_DIR/bin/libmariadb.3.dylib"
    ln -sfn libmariadb.3.dylib "$RUN_DIR/bin/libmariadb.dylib"
else
    copy_lib "$MARIA_CONN/lib/libmariadb.dylib" "$RUN_DIR/bin/libmariadb.dylib"
fi
for lib in "$OPENSSL_ROOT/lib"/libssl.*.dylib "$OPENSSL_ROOT/lib"/libcrypto.*.dylib; do
    [ -f "$lib" ] || continue
    copy_lib "$lib" "$RUN_DIR/bin/$(basename "$lib")"
done

fix_rpath() {
    local binary="$1"
    install_name_tool -add_rpath '@loader_path' "$binary" 2>/dev/null || true
    local dep
    for dep in $(otool -L "$binary" | awk '/libmariadb|libssl|libcrypto/{print $1}'); do
        case "$dep" in
            @*) continue ;;
        esac
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$binary" 2>/dev/null || true
    done
}
fix_rpath "$RUN_DIR/bin/mangosd"
fix_rpath "$RUN_DIR/bin/realmd"
find "$RUN_DIR/bin/Extractors" -type f -perm +111 2>/dev/null | while read -r exe; do
    fix_rpath "$exe"
done

echo "layout ready: $RUN_DIR (MariaDB -> $BREW_MARIA)"

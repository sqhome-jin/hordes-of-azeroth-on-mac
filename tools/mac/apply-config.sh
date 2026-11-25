#!/bin/bash
# Merge config/*.overrides.conf into server/run/*.conf (same idea as tools/apply-config.ps1).
set -euo pipefail
# shellcheck source=dev-common.sh
. "$(dirname "$0")/dev-common.sh"

merge_config() {
    local name="$1"
    local dist="$RUN_DIR/$name.conf.dist"
    local overrides="$CONFIG_DIR/$name.overrides.conf"
    local target="$RUN_DIR/$name.conf"
    python3 - "$dist" "$overrides" "$target" <<'PY'
import sys
dist, overrides, target = sys.argv[1:4]
lines = open(dist, encoding='utf-8').read().splitlines()
applied = 0
for raw in open(overrides, encoding='utf-8'):
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key = line.split('=', 1)[0].strip()
    found = False
    for i, existing in enumerate(lines):
        if existing.lstrip().startswith(key + ' ') or existing.lstrip().startswith(key + '='):
            lines[i] = line
            found = True
            applied += 1
            break
    if not found:
        raise SystemExit(f"{overrides} sets '{key}', which {dist} does not define.")
open(target, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(f'{target}: {applied} override(s) applied')
PY
}

mkdir -p "$LOG_DIR"
merge_config mangosd
merge_config realmd

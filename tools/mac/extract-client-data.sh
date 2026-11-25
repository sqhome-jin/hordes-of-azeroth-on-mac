#!/bin/bash
# Extract dbc/maps/vmaps and build nav tiles listed in config/navtiles.json.
set -euo pipefail
# shellcheck source=dev-common.sh
. "$(dirname "$0")/dev-common.sh"

bash "$(dirname "$0")/layout-run.sh"

EXTRACTORS="$RUN_DIR/Extractors"
THREADS="${THREADS:-$(sysctl -n hw.ncpu)}"
CLIENT_ROOT="$WOW_DATA"

if [ ! -d "$CLIENT_ROOT/Data" ]; then
    echo "Missing $CLIENT_ROOT/Data" >&2
    exit 1
fi

mkdir -p "$DATA_DIR/vmaps" "$DATA_DIR/mmaps"
cd "$DATA_DIR"

echo "=== Maps and DBC ==="
"$EXTRACTORS/MapExtractor" -i "$CLIENT_ROOT" --silent
if [ -d "$DATA_DIR/dbc" ]; then
    rm -rf "$DATA_DIR/5875/dbc"
    mkdir -p "$DATA_DIR/5875"
    mv "$DATA_DIR/dbc" "$DATA_DIR/5875/dbc"
fi

echo "=== VMap extract ==="
"$EXTRACTORS/VMapExtractor" -d "$CLIENT_ROOT/Data" --silent
echo "=== VMap assemble ==="
"$EXTRACTORS/VMapAssembler" Buildings vmaps --silent

echo "=== MMap generate (navtiles.json groups, $THREADS threads) ==="
python3 - "$EXTRACTORS" "$DATA_DIR" "$CONFIG_DIR/navtiles.json" "$THREADS" <<'PY'
import json, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor, as_completed

extractors, data_dir, nav_path, threads = sys.argv[1:5]
threads = int(threads)
generator = os.path.join(extractors, 'MoveMapGenerator')
opts = ['--silent', '--offMeshInput', os.path.join(extractors, 'offmesh.txt'),
        '--configInputPath', os.path.join(extractors, 'config.json')]
mmaps = os.path.join(data_dir, 'mmaps')
os.makedirs(mmaps, exist_ok=True)
groups = json.load(open(nav_path))['groups']

def tile_name(map_id, tile):
    x, y = tile.split(',')
    return f'{int(map_id):03d}{int(y):02d}{int(x):02d}.mmtile'

def run(args):
    r = subprocess.run([generator, *args, *opts], cwd=data_dir)
    if r.returncode != 0:
        raise SystemExit(f'MoveMapGenerator failed: {args}')

for group in groups:
    whole, tiles = [], []
    for map_id, value in group['maps'].items():
        if isinstance(value, str):
            if not any(name.startswith(f'{int(map_id):03d}') and name.endswith('.mmtile')
                       for name in os.listdir(mmaps)):
                whole.append(map_id)
        else:
            for tile in value:
                if not os.path.exists(os.path.join(mmaps, tile_name(map_id, tile))):
                    tiles.append((map_id, tile))
    print(f"=== {group['name']}: {len(tiles)} tiles, {len(whole)} whole maps ===", flush=True)
    for map_id in whole:
        run([map_id, '--threads', str(threads)])
    with ThreadPoolExecutor(max_workers=threads) as pool:
        futs = [pool.submit(run, [map_id, '--tile', tile, '--threads', '1']) for map_id, tile in tiles]
        for fut in as_completed(futs):
            fut.result()
print('=== MMaps done ===')
PY

echo "=== Extract done ==="

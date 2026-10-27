#!/bin/sh
set -eu
cd "$(dirname "$0")"
output_dir="$(mktemp -d "${TMPDIR:-/tmp}/keyglow-ble-wire.XXXXXX")"
trap 'rm -rf "$output_dir"' EXIT HUP INT TERM
python3 - "$output_dir/vectors.h" <<'PY'
import json,sys
from pathlib import Path
vectors=json.loads(Path('vectors.json').read_text())['frames']
lines=['#include <stddef.h>','#include <stdint.h>',
       'typedef struct { const char *name; unsigned kind; const uint8_t *bytes; size_t size; } wire_vector;']
for i,v in enumerate(vectors):
    data=bytes.fromhex(v['frameHex'])
    lines.append(f'static const uint8_t bytes_{i}[] = {{'+','.join(map(str,data))+'};')
lines.append('static const wire_vector wire_vectors[] = {')
for i,v in enumerate(vectors):
    lines.append('{'+json.dumps(v['name'])+f', {v["kind"]}, bytes_{i}, sizeof(bytes_{i})'+'},')
lines += ['};','#define WIRE_VECTOR_COUNT (sizeof(wire_vectors)/sizeof(wire_vectors[0]))']
Path(sys.argv[1]).write_text('\n'.join(lines)+'\n')
PY
cc -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
  -I. -I"$output_dir" keyglow_ble_wire.c test_wire.c -o "$output_dir/test-wire"
"$output_dir/test-wire"
cc -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
  -I. -I../.. -Itests/stubs -I../../diagnostics/tests/qmk_stub \
  keyglow_ble_wire.c qmk_ble_ota.c ../../ble_rgb_protocol.c tests/test_qmk_ble.c -o "$output_dir/test-qmk-ble"
"$output_dir/test-qmk-ble"

#!/usr/bin/env bash
# Runs the pure-logic tests for lib/date, lib/model, lib/layout and the ICS parser.
#
# Noctalia embeds Luau, which is not installed as a standalone interpreter here
# (`pacman -S luau` provides one). So the modules are mechanically converted to
# Lua 5.4 first: type annotations and casts stripped, `+=`/`-=` expanded, and
# `math.clamp` / `table.clone` shimmed. Only the entry scripts need the real
# Noctalia host; everything tested here is pure arithmetic.
#
# The timezone is pinned so the DST assertions are meaningful.
set -euo pipefail
cd "$(dirname "$0")"

SRC=../fiaker
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/lib"

python3 transpile.py "$SRC"/lib/{date,model,layout,source_vdir}.luau >/dev/null
# transpile.py writes next to itself; move into the sandbox and fix module paths
for f in date model layout source_vdir; do
  mv "lib/$f.luau" "$OUT/lib/$f.lua"
done
rmdir lib 2>/dev/null || true
sed -i 's|require("date")|require("lib.date")|; s|require("model")|require("lib.model")|' "$OUT"/lib/*.lua

cp logic_test.lua ics_test.lua "$OUT/"
cd "$OUT"
echo "--- logic ---"; TZ=Europe/Vienna lua5.4 logic_test.lua
echo; echo "--- ics ---"; TZ=Europe/Vienna lua5.4 ics_test.lua

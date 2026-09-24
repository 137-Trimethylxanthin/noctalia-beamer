#!/usr/bin/env bash
# Runs the pure-logic tests for Häubchen under Lua 5.4: lib/pip.luau, and the
# parsing half of each compositor backend (compositor JSON in, neutral model
# out) against recorded-shape fixtures. The modules are converted with Fiaker's
# transpiler, run through uv (see tests/fiaker/run.sh for why). Moving windows
# needs a real compositor and the Noctalia host, so that is not covered here.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

(cd "$OUT" && uv run --quiet "$HERE/../fiaker/transpile.py" \
  "$HERE"/../../haeubchen/lib/pip.luau \
  "$HERE"/../../haeubchen/lib/backend/{hyprland,sway,niri}.luau >/dev/null)
for f in "$OUT"/lib/*.luau; do mv "$f" "${f%.luau}.lua"; done

cp pip_test.lua backend_test.lua json.lua "$OUT/"
cd "$OUT"
echo "--- pip ---"; lua5.4 pip_test.lua
echo; echo "--- backends ---"; lua5.4 backend_test.lua

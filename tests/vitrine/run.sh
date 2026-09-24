#!/usr/bin/env bash
# Runs the pure-logic tests for Vitrine under Lua 5.4: lib/core.luau (which
# output is which, which layout is on, the steps to another) and the Hyprland
# backend's parsing and rule building. Converted with Fiaker's transpiler, run
# through uv (see tests/fiaker/run.sh for why). Changing real monitors needs a
# compositor, so that is not covered here. lib/outputs.py's `list` has been run
# on Hyprland; its `apply` has not been run on a compositor that implements
# `test` for real (Hyprland 0.56 does not, see the helper's docstring).
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

(cd "$OUT" && uv run --quiet "$HERE/../fiaker/transpile.py" \
  "$HERE"/../../vitrine/lib/{core,hyprland}.luau >/dev/null)
for f in "$OUT"/lib/*.luau; do mv "$f" "${f%.luau}.lua"; done
sed -i 's|require("core")|require("lib.core")|' "$OUT"/lib/*.lua

cp core_test.lua "$OUT/"
cd "$OUT"
echo "--- core ---"; lua5.4 core_test.lua

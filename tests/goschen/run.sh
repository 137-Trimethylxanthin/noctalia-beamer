#!/usr/bin/env bash
# Runs the pure-logic tests for Goschen under Lua 5.4: lib/quiet.luau, which
# turns what pactl lists into mutes, unmutes and resets. The module is
# converted with Fiaker's transpiler, run through uv (see tests/fiaker/run.sh
# for why). Talking to PipeWire needs a real session and the Noctalia host, so
# that is not covered here.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

(cd "$OUT" && uv run --quiet "$HERE/../fiaker/transpile.py" "$HERE"/../../goschen/lib/quiet.luau >/dev/null)
for f in "$OUT"/lib/*.luau; do mv "$f" "${f%.luau}.lua"; done

cp quiet_test.lua "$OUT/"
cd "$OUT"
echo "--- quiet ---"; lua5.4 quiet_test.lua

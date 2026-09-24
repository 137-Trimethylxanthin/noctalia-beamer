#!/usr/bin/env bash
# Runs the pure-logic tests for Kerzenlicht: lib/spot.py, the pixel math behind the
# flashlight (the glow, clipping at the edges, clearing the old square again).
# Drawing on a real compositor needs a Wayland session, so that is not
# covered here.
set -euo pipefail
cd "$(dirname "$0")"
echo "--- spot ---"; uv run --quiet --script spot_test.py

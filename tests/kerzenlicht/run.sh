#!/usr/bin/env bash
# Runs the pure-logic tests for Kerzenlicht: lib/spot.py, the pixel math behind the
# light (the glow, the dimming and its hole, clipping at the edges, repainting the
# old square), and lib/shake.py, which tells a shake from ordinary movement.
# Drawing on a real compositor needs a Wayland session, so that is not
# covered here.
set -euo pipefail
cd "$(dirname "$0")"
echo "--- spot ---"; uv run --quiet --script spot_test.py
echo "--- shake ---"; uv run --quiet --script shake_test.py

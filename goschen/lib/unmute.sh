#!/bin/sh
# Clears a remembered mute:  sh unmute.sh <application.name> <application.id>
# (either may be empty, not both). Exits 0 only once the mute is gone.
#
# WirePlumber remembers a mute per app, keyed by application.id if the stream
# has one and application.name otherwise, and puts it on the app's next
# stream. Goschen mutes an app's live streams, so when Do Not Disturb ends,
# the app may have no stream left to unmute, and it would come back muted. So
# this opens a silent stream with the same name and id, which WirePlumber keys
# the same way, unmutes it (which is what gets remembered), and closes it.
#
# Self-contained on purpose: it also runs from onExit, when nothing is left to
# watch the stream appear.
name=$1 id=$2
[ -n "$name$id" ] || exit 2

# pactl's text output is translated; the parsing below needs the English one.
LC_ALL=C
export LC_ALL

set -- --client-name="${name:-goschen}"
[ -n "$id" ] && set -- "$@" --property=application.id="$id"

pacat --playback "$@" --stream-name=goschen /dev/zero >/dev/null 2>&1 &
pid=$!

# "<index> <yes|no>" for our stream, or nothing while it is not there yet.
ours() {
  pactl list sink-inputs 2>/dev/null | awk -v pid="$pid" '
    /^Sink Input #/ { n = substr($3, 2); m = "" }
    /^[ \t]*Mute: / { m = $2 }
    /application\.process\.id = / { gsub(/"/, "", $3); if ($3 == pid) { print n, m; exit } }'
}

index="" muted=""
tries=0
while [ "$tries" -lt 30 ]; do
  set -- $(ours)
  index=$1 muted=$2
  [ -n "$index" ] && break
  sleep 0.1
  tries=$((tries + 1))
done

ok=1
if [ -n "$index" ]; then
  # WirePlumber puts the remembered mute on the stream a moment after it
  # appears; unmuting before that would change nothing it remembers.
  tries=0
  while [ "$muted" != "yes" ] && [ "$tries" -lt 5 ]; do
    sleep 0.1
    set -- $(ours)
    muted=$2
    tries=$((tries + 1))
  done
  pactl set-sink-input-mute "$index" 0
  # WirePlumber stores the change asynchronously, and drops it if the
  # stream is already gone by then.
  sleep 1
  set -- $(ours)
  if [ "$2" = "yes" ]; then
    pactl set-sink-input-mute "$index" 0
    sleep 1
    set -- $(ours)
  fi
  [ "$2" = "no" ] && ok=0
fi

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
exit "$ok"

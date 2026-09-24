# Goschen — Do Not Disturb that really means it

**A [Noctalia](https://noctalia.dev) shell plugin that makes Do Not Disturb
actually quiet**: no popups, and no pings from Discord, Vesktop, Telegram or
Slack either. The call you are in and your music keep playing.

![Goschen, illustrated: with Do Not Disturb on, a ping from a chat app is muted, while the call you are in keeps playing and your music is untouched](thumbnail.webp)

*Hoit die Goschen* is Viennese for "shut your gob", the thing a waiter mutters
at the loud table in the corner. Goschen says it to your chat apps, and only
while Do Not Disturb is on.

## Why a plugin

Noctalia's Do Not Disturb hides popups and skips the sounds the shell plays
itself, and the notifications still land in the history, so the bar keeps
counting. But Discord and most chat apps never ask the shell to play their
ping. They play it themselves, through their own audio stream, so Do Not
Disturb never hears it.

Goschen follows Noctalia's Do Not Disturb. While it is on, the apps on its
list are muted in PipeWire; when it ends, they get their sound back. Nothing
else is muted: not your music, not your browser, not a game.

## Plugin

| Field | Value |
| --- | --- |
| ID | `137-trimethylxanthin/goschen` |
| Entries | Service: `watch`; shortcut: `toggle` |

## Requirements

- **PipeWire with WirePlumber** and `pipewire-pulse`, which almost every
  PipeWire desktop runs. Goschen relies on how WirePlumber remembers a mute
  (see [Notes](#notes)); plain PulseAudio remembers differently and is not
  supported.
- `pactl` and `pacat`, from `libpulse` (Arch) or `pulseaudio-utils`
  (Debian, Fedora).

Missing tools are reported when the plugin starts.

## Usage

Turn Do Not Disturb on however you like: the control center, a keybind,
`noctalia msg notification-dnd-toggle`, or Goschen's own tile, which you add
under **Settings → Control Center shortcuts**. Goschen notices within two
seconds: plugins are not told when Do Not Disturb changes, so it asks every two
seconds.

### What stays audible

**Calls.** An app that is using the microphone is in a call, so it keeps its
sound: a Discord voice channel, a Telegram call. Its pings are heard during the
call too, see [Notes](#notes). Capturing a screen's audio for a stream does not
count as a call. Switch **Leave calls alone** off to mute an app even then.

**Long playback, if you want it.** With **Leave long playback alone** set to,
say, 30 seconds, an app that keeps playing that long (a video in Telegram, a
Discord stage you only listen to) gets its sound back. It is off by default,
because some apps keep their ping stream open between pings, and those would
get their pings back too. A paused stream never counts.

**Every app not on the list**, always. **System notification sounds** too:
they share a single remembered setting across every app, so muting one would
mute them all, Noctalia's own included.

**Your own mutes.** Goschen only ever unmutes streams it muted itself, or that
came in muted because it had muted that app. A stream you mute stays muted,
during a call or after Do Not Disturb.

### Keybinds

The `watch` service takes these events over IPC:

```sh
noctalia msg plugin 137-trimethylxanthin/goschen:watch all toggle
noctalia msg plugin 137-trimethylxanthin/goschen:watch all on
noctalia msg plugin 137-trimethylxanthin/goschen:watch all off
```

They set Noctalia's own Do Not Disturb, so `noctalia msg notification-dnd-toggle`
works just as well. In `hyprland.lua`:

```lua
hl.bind("SUPER + N", hl.dsp.exec_cmd("noctalia msg plugin 137-trimethylxanthin/goschen:watch all toggle"))
```

## Settings

| Setting | Default | |
| --- | --- | --- |
| Apps to silence | `vesktop, discord, equibop, legcord, webcord, telegram-desktop, signal-desktop, slack, element-desktop` | Process or app names, separated by commas, matched against a stream's `application.process.binary` first and `application.name` second |
| Leave calls alone | On | An app using the microphone keeps its sound |
| Leave long playback alone | `0` | Seconds (up to 600) after which an app that keeps playing gets its sound back; `0` is off |

To find an app's name, play something in it and run:

```sh
pactl list sink-inputs | grep -E "application.name|application.process.binary"
```

## Notes

**Per app, not per sound.** WirePlumber remembers a mute per app, by its
`application.id` or else its `application.name`, and puts it on the app's next
stream. So Goschen cannot mute Vesktop's pings and keep its voice chat: muting
one Vesktop stream mutes the next one, whichever it is. It decides per app
instead, which is what the call rule is for. The upside: once an app is muted,
its next ping starts muted, so not even the first milliseconds get through.

**Getting the sound back.** Because the mute is remembered, an app whose
streams have all closed would come back muted after Do Not Disturb. So when
Goschen gives an app back, it also opens a silent stream for about a second
with the app's name and id, unmutes it and closes it (`lib/unmute.sh`).
WirePlumber files that under the same key, which clears the remembered mute.
An app stays on Goschen's list, in its data directory, until that has worked;
a reset that fails is tried again, and a restart or a crash in between is
caught up on the next start. Disabling the plugin gives everything back first.

**For a quiet ping outside Do Not Disturb too**, turn the app's own sound off
(Discord: *Settings → Notifications*) and let Noctalia play its notification
sound for it, which Do Not Disturb already silences.

**Tests.** `./tests/goschen/run.sh` covers the decisions: which streams to
mute, unmute and reset, for calls, long playback, shared notification sounds,
your own mutes, failed resets and apps leaving the list. Talking to PipeWire
has been run against PipeWire 1.6 with WirePlumber 0.5, using test streams
rather than a real Discord: muting and unmuting, calls, resets by name and by
id, and a restart of `pactl subscribe`.

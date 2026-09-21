# noctaliaPluginBetterCal

A better calendar for [Noctalia](https://noctalia.dev) v5 — the month grid and the day timeline as
**separate, synchronized** widgets, with a Google-style live now-line.

- **[`PROPOSAL.md`](PROPOSAL.md)** — the design doc: what a v5 plugin is written in, why the
  built-in calendar's events are not reachable from a plugin today, the core patch that would fix
  that, and the architecture.
- **[`fiaker/`](fiaker/)** — the plugin itself. See [`fiaker/README.md`](fiaker/README.md).
- **[`test/`](test/)** — pure-logic tests for the date math, the timeline geometry and the ICS
  parser. Run with `./test/run.sh`.

```sh
noctalia plugins lint fiaker
./test/run.sh
```

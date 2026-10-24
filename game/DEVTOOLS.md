# Dev tools

Everything here exists in **debug builds only**. A release export
(`tools/device.sh release`) builds none of it, so there is nothing to hide or strip.

## The dev panel

A small **DEV** tab in the bottom-left corner of every screen opens it. On a
desktop, **F1** opens and closes it too. It remembers which tab you last used
on the map and on the other screens.

| Tab | Where it shows | What it has |
|---|---|---|
| **Screens** | everywhere | Open any screen; *explore map* (the board with no session); *lobby preview* (the team picker with made-up teams); *sign out*; this build's version, profile and server host |
| **Map** | a match | **Move:** Teleport, Aerial, Fast Walk · **Progress:** Answer Monk, Freeze, End Match · **Look:** Show Walls. Switches show "· on" while on |
| **Network** | everywhere | Live readout: line status and HTTP time, the realtime socket, which server address was used, and how far behind other heroes are played back. Switches below |

Network switches:

| Switch | Does | Same as |
|---|---|---|
| Force IPv4 | connect by the server's IPv4 address, the path for networks with broken IPv6 | `NUMX_DIAL=v4` |
| Log realtime | every realtime socket message printed to the console | `RT_DEBUG=1` |

## Launch flags

After `--` on the Godot command line, e.g. `godot --path game -- --touch`.

| Flag | Does |
|---|---|
| `--explore` | straight onto the board with no session |
| `--touch` | the phone's touch controls on a desktop |
| `--profile=NAME` | a separate save and login, so several windows can be different accounts |

## Environment variables

| Variable | Does |
|---|---|
| `LAKBAYIN_SERVER_URL` | point the game at another server (the suites use a dead address) |
| `RT_DEBUG=1` | print every realtime message |
| `NUMX_DIAL=v4` | always take the pinned IPv4 path |

## Tools (`game/tools/`)

| Tool | Does |
|---|---|
| `run_tests.sh` | every Godot test suite, one exit code (the server's: `server/tests`) |
| `device.sh` | build, install, run and screenshot on a USB phone (`build`, `install`, `run`, `shot`, `release`) |
| `flow_shots.py` | windowed clients through the online flow against a throwaway local server, with screenshots (`FLOW_CLIENTS`, `FLOW_SCREENS`, `FLOW_CHECKS`, ...) |
| `layout.tscn` | does every screen fit 640×360 and 800×360, and does the DEV tab cover nothing |
| `ui_shot.tscn`, `backdrop_shot.tscn`, `collision_shot.tscn` | screenshots of screens, the menu backdrop, a map's walls and levels |
| `guide_shot.tscn`, `guide_shots.py` | How to Play's pages, and its screenshots of the game (staged by `guide_moments.tscn`) |
| `logo_shot.tscn` | the logo and the app icon's layers |
| `map_export.tscn`, `walk_export.tscn` | a match's map for the server, and honest walks on it for the server's tests |
| `make_words.py`, `make_icons.py`, `fix_glyphs.py`, `tune_fonts.py` | the word list, the menu icons, glyph and font fixes |

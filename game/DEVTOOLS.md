# Dev tools

Everything here exists in **debug builds only**. A release export
(`tools/device.sh release`) builds none of it, so there is nothing to hide or strip.

## The dev panel

A small **DEV** tab in the bottom-left corner of every screen opens it. On a
desktop, **F1** opens and closes it too. It remembers which tab you last used
on the map, on Game Controls, and on the other screens.

| Tab | Where it shows | What it has |
|---|---|---|
| **Screens** | everywhere | Open any screen; *explore map* (the board with no session); *lobby preview* (the team picker with made-up teams); *sign out*; this build's version, profile, Supabase host and relay host |
| **Map** | the adventure map | **Move:** Teleport, Aerial, Fast Walk, Open Gates · **Progress:** Skip Station, +1:00, Freeze, End Run · **Look:** Show Walls, Hero −, Hero +. Switches show "· on" while on. Keys: `[` and `]` size the hero |
| **Network** | everywhere | Live readout: line status and HTTP time, realtime socket, which server address was used, relay state, rtt, echo and playback buffer, phone reports. Switches below |
| **Hub** | Game Controls | The teacher's live message counts, players and message log. **Pin on screen** keeps a one-line summary on Game Controls with the panel shut |

Network switches:

| Switch | Does | Same as |
|---|---|---|
| Relay off | this device uses the teacher's hub, as if the relay were blocked (tests the bridge) | — |
| Echo ghost | your own walk drawn as the relay returns it; the gap is the delay classmates see | — |
| Reports | phones send a network report to the laptop every 10 s (`tools/sim/netreport_listen.py`) | — |
| Force IPv4 | the path for networks with broken IPv6, even where nothing is broken | `NUMX_DIAL=v4` |
| Log realtime | every realtime socket message printed to the console | `RT_DEBUG=1` |

## Launch flags

After `--` on the Godot command line, e.g. `godot --path game -- --touch`.

| Flag | Does |
|---|---|
| `--explore` | straight onto the board with no session |
| `--touch` | the phone's touch controls on a desktop |
| `--profile=NAME` | a separate saved login, so several windows can be different accounts |
| `--hub-debug` | Game Controls opens with the Hub stats pinned |

## Environment variables

| Variable | Does |
|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | point the game at another Supabase project |
| `RT_DEBUG=1` | print every realtime message |
| `NUMX_DIAL=v4` | always take the pinned IPv4 path |

## Tools (`game/tools/`)

| Tool | Does |
|---|---|
| `run_tests.sh` | every test suite, one exit code |
| `device.sh` | build, install, run and screenshot on a USB phone (`build`, `install`, `run`, `shot`, `release`) |
| `layout.tscn` | does every screen fit 640×360 and 800×360, and does the DEV tab cover nothing |
| `ui_shot.tscn`, `map_shot.gd`, `tower_shot.gd` | screenshots of screens, the map, the towers |
| `board_dump.gd`, `check_guards.gd`, `make_tower_pool.tscn`, `scatter_props.tscn` | the map's build: dump, gate check, tower spots, props |
| `supabase_check.gd`, `realtime.tscn`, `admin.tscn`, `auth_screens.tscn`, `scores.tscn`, `rescue.tscn`, `done.tscn` | checks against the **live** Supabase project (they create test accounts) |
| `relay.gd` | the movement relay on its own; `--test-auth` for local load tests |
| `relay/run.sh` | the home relay behind a free tunnel, kept running, address published: Cloudflare, or Pinggy while Cloudflare's tunnels fail (back to Cloudflare once it answers) |

## Load and network tools (`game/tools/sim/`)

| Tool | Does |
|---|---|
| `classroom.py` | a whole class played against the live backend |
| `join_and_walk.py` | fill a real session with walking students (`--bundle S` for path bundles) |
| `movers.py` | phones walking on Realtime, with delivery and lag figures |
| `relay_load.py` | simulated phones against the relay (needs `relay.gd --test-auth`) |
| `netreport_listen.py` | print and save the network reports test phones send |
| `leaderboard_live.py`, `rescue_live.py`, `ratelimit.py` | live checks of boards, Rescue, and the auth rate limit |

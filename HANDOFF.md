# Lakbayin — Handoff

Updated 2026-11-20. Read this, then `DESIGN.md` (the source of truth for
every game rule), then `server/README.md`.

## 1. What this is

**Lakbayin** is a Godot 4.6 game for the **DOST Level Up 3.0 Esports Game Dev
Challenge** (Student Category; themes: Education + Philippine culture).

- 3 v 3 (setting goes 1–5 a side), matchmade, timed matches.
- Each match builds a **procedurally generated, mirrored island** from a seed.
- **Monks** are scattered around it, each holding a Filipino word.
- A player walks to any monk and types the word in **Baybayin** on a 20-key
  keypad.
- A correct answer is **carried**; it counts only once **deposited** at the
  **Monastery** on the centre line.
- The first team to deposit every word wins; otherwise the clock decides
  (more words, then whoever reached that total sooner).
- **Practice** is the same match, solo and offline.

**Finals:** 2026-11-26/27 (General Santos City). Entries were due 2026-10-25.

## 2. Repo

- Repo: `~/Workspace/games/levelup-entry` (git, branch `main`, remote `origin` = github.com/Ken-n7/lakbayin).
- Godot project: `game/`.
- Backend: `server/` (FastAPI + SQLite + WebSockets). The former Supabase backend (`supabase/`) and the movement relay were deleted on Oct 25; git history keeps them.
- The original asset pack downloads (Tiny Swords, Super Retro World, Pixel
  Crawler) sit at the root but are gitignored; the game uses its copies in
  `game/assets/`. Pixel Crawler is unused.
- This repo is a **fork** of an earlier client project, NumXventure, at
  `~/Workspace/games/NumXventure`. **Never change that repo.**
  - The fork's history was rewritten: client documents were removed, and every
    commit is authored by `Ken-n7 <canetejohnkenneth04@gmail.com>`.
  - Don't mention the client in docs or commits.

## 3. State

### Tests widened (Nov 20, branch `chore/trim-dead-code`)
- `game/scripts/tests/net_contract_test.gd`: every client server call
  (Backend, Teams, Lobby, Monks, WatchFeed) against a real server, answers
  and refusals. Run by the server suite
  (`test_client_calls_against_a_real_server`), not `run_tests.sh`.
- It found one bug, fixed in `server/app.py` `read_rows`: a code typed for a
  room already under way said "Not a member or viewer"; your own member row,
  when you have none, is now `[]`, so it says "That room has already started."
- New server tests for the WebSocket refusals, rate limit, token recheck,
  watch lease, code clashes, login lockout expiry, failed map build, APK
  download, and `manage.py`. Checked by breaking each guarded line in a copy:
  every break is caught.

### Maps and slow lines (Nov 11)
- **Map generator, found by a seed sweep** (`WORLD_SEEDS`, DEVTOOLS; the
  suite's own eight seeds never hit them):
  - About 1 world in 200 walled Red in at its spawn: where a plateau across
    the axis kept the halves apart, `_let_up` / `_let_down` mended by what
    Blue's spawn reached alone and raised Red's half. `_levels_sound()` now
    throws such a try away (levels mirrored, reach mirrored), and after
    `LEVEL_TRIES` the island stays flat.
  - 1 in 800 put the Monastery down across a cliff (`base_row = H / 2` when
    it fitted nowhere): a try with no place for it is unsound too.
  - Every other seed builds exactly the map it did before.
- **One read for a match** (`match_state` rpc, `Monks.state`, `Match.reload`):
  opening a match was six reads one after another, its results seven, each
  a new connection. Through `slow_proxy.py` at a 300 ms round trip: joining
  7.5 s -> 2.1 s, results 10 s -> 1.3 s; at 800 ms: 19 s -> 4.5 s, 25 s ->
  3.6 s. Results also read again while the server has not ended the match.
- **Bursts after a freeze:** `BURST_S` 2 -> 5 and a lost hero keeps the time
  they were away (`LOST_BANK_S`): on a line freezing 6 s in every 20, dropped
  movement went from 113 packets a match to 17.
- **Kept connections (Nov 11):** every call goes over
  `HttpPool` (`game/scripts/net/HttpPool.gd`, `Backend.pool`), not a new
  `HTTPRequest` each: a connection is kept 45 s and used again; one the far
  end let go of is given 5 s, then the call is made once more on a new one.
  A match keeps one warm with a `/health` every 20 s of silence
  (`Net.warm`). Measured: over the public address the first call 319 ms, the
  next five about 60 ms; through `slow_proxy.py` an answer at a monk on a
  300 ms round trip 1.2 s -> 0.47 s, on 800 ms 3.2 s -> 1.2 s; joining
  7.5 s -> 1-2 s. `http_test` (12 checks, its own HTTP server) is in
  `run_tests.sh`; `tools/net_check.tscn` times six calls to the server from
  wherever it is run. `run.sh` has `--timeout-keep-alive 75`. Checked on the
  Realme over the public address: sign-in restore, a Find Match game, forfeit,
  Results. No gzip is asked for (`HTTPRequest` did): answers are a few KB.

### The booth (Nov 10)
- For the finals the user runs a booth: two of their own phones for
  visitors, this laptop as the server, on the venue's WiFi.
  `server/README.md` "The booth" has the commands.
- **Control panel:** `control` rpc (admins only; `users.admin`, set by
  `server.manage admin NAME`), `config.hints` copied into matchmade sessions;
  Home → Settings → Control (`HomeScreen._open_control`). No account is an
  admin yet -- the user has to name theirs.
- **Local network: parked** on branch `lan-fallback` (commit `c715305`),
  Nov 10. The user chose the venue's WiFi and the public address instead.
  The branch has `Backend._reroute` / `_find_local` (scan this device's /24
  for port 8000 + `/health`), `Realtime`'s probe, `game/tools/lan_check.tscn`
  and `LAKBAYIN_HOST` in `run.sh`. It worked laptop-to-laptop (found in
  0.4 s); on the phone it was stopped by ufw blocking port 8000, which needs
  `sudo ufw allow 8000/tcp` -- never finished. To bring it back:
  `git diff main lan-fallback -- game/scripts/net server/run.sh game/tools`.
- **Install:** `/get` serves the release APK; `server/booth.py` makes the QR
  sheet. Release APK rebuilt Nov 10 22:34 with everything up to here.
- **Backups:** `lakbayin-backup.timer` is enabled; first copy made.
- `ken` is the admin account. The Realme has the current debug build.
- **Public route checked from the phone (Nov 10):** on a different WiFi from
  the laptop, through `server.lakbayin.space`: sign-in restore, a 1 v 1 Find
  Match with letters on, forfeit after 60 s, Results. Config put back to
  3 v 3, letters off.
- Open: a GitHub release for the download link -- the user said not yet, the
  app is still changing. Until then the QR points at this server's `/get`,
  so the 88 MB APK goes out through the tunnel on the laptop's upload.

### Bug fixes before the finals (Nov 10)
- **Viewer movement delay:** the delayed copy sent the sender's *latest*
  socket message, not the packet from a minute before (`app.py`, the
  `call_later` lambda now binds topic and payload).
- **Forfeit:** a running match one side has been off for
  `ABANDON_S` (60 s, `LAKBAYIN_ABANDON_S`, 0 = off) ends and the side that
  stayed wins (`abandon` in the ticker sets `winner_team` and `forfeit_by`;
  DESIGN.md 3.4). "Off" = no socket of that side on the match's snap channel.
  Both sides off: ends with the score standing. `team_standings` rows carry
  `forfeit`; `ResultsScreen._rank_key` sorts a forfeiting side last, so the
  title, WINNER tag and "<side> left the match" all follow from it.
- **Lost heroes:** a hero whose line dropped for more than
  about 2 s of walking was never taken again -- every later packet was
  measured from where they were last seen, and every answer refused ("Walk up
  to it first"). Now a hero unheard for `LOST_S` (5 s) is taken where they
  next say they are, within what they could have walked (`hero`'s `lost`,
  `moved_ok`'s jump; `placed_ok` moves them and spends the walk). The way
  across the gap is not checked: a silent client can cross a cliff, no faster
  than walking.
- **Match end:** a movement packet arriving after the match
  ended closed the sender's socket; it is dropped now. `_deposit` runs one at
  a time.
- **Menus:** Android's back in a lobby or the Find Match
  queue is now Leave / Cancel (`TeamNameScreen.go_back`; it went Home and
  left the place taken, so a match could start with nobody in it), and does
  nothing once the match has started. `_rejoin_match` no longer forgets the
  match on a failed request (`Teams.session_read`). Login and Register
  ignore a second Enter while the first is on its way.
- **Realme:** unplugged mid-session with a USB test build on it that points
  at `127.0.0.1:8000` -- it cannot reach the server on its own. Reinstall
  `build/Lakbayin.apk` (`game/tools/device.sh install`).
- **Joining on a bad line:** `_join_online` retries the session read three
  times and no longer forgets the match on a failed request.
- **Teams not arriving:** `Match.start_online` now fails with a message
  instead of putting everyone on Blue.
- Two new server tests (30 total). The client fixes have no test of their own.
- **Server optimizations:** a socket's token is looked up every
  `TOKEN_RECHECK_S` (5 s), not per message; finished matches are parsed once
  and kept (`Store.archives`, `_ranked`): Records with 2,000 matches went
  from ~320 ms to ~40 ms a request; a failed map build is logged once.
  The 50 ms movement send rate stays: a 3 v 3 with a spectator (seven
  windows, position checks on) peaked at 5% of one core on this laptop.
- **Tested Nov 10:** 30 server tests, 12 Godot suites; `flow_shots.py` room
  scenario with 7 clients, with and without `FLOW_CHECKS`; on the Realme
  against the live server process (over `adb reverse`, the phone was in
  airplane mode), a Find Match game whose opponent never connected ended
  after 60 s and showed Results (Draw 0-0).
- **Live:** `lakbayin.service` was restarted on this code. `build/Lakbayin.apk`
  (debug, public server address) is rebuilt and on the Realme; the release
  APK is not rebuilt. Live config is `team_size = 3` since Nov 10 (a fresh
  database still starts at 1). Test accounts on the live server:
  `t_phone_*`, five `t_ghost_*`. Forfeit checked on the Realme the same way:
  a live 3 v 3 Find Match, the other side never connected, Results said
  Victory, "Pula left the match" (31 server tests, match suite 47).

### Server checks positions (Oct 24)
- The server runs **Godot** (`LAKBAYIN_GODOT`, else `godot` on PATH, else
  `~/.local/bin/godot`, see `server/run.sh`) once per match on
  `game/tools/map_export.tscn` to build that match's map, so the server
  machine needs Godot 4.6 and an imported `game/` (`godot --headless --path
  game --import` on a fresh checkout). If the map cannot be built the match
  goes on unchecked and the journal says `map for <sid> failed`.
- Movement off the ground, up a cliff (levels are followed, ramps only) or
  over the distance budget (5% over walking speed, 2 s banked) is dropped
  (`movement dropped: ...` in the journal); answers and deposits need `p_at`
  by the monk / door. `server/tests/test_server.py` replays the game's own
  movement on real maps (`game/tools/walk_export.gd`) and needs every step
  accepted: change the client's movement rules and that test says if the
  server's copy (`cell_ok`, `level_at` in app.py) no longer agrees.
- Test servers (`flow_shots.py`, `server/tests/run_godot.py`) set
  `LAKBAYIN_GODOT=` because their bots answer from anywhere;
  `FLOW_CHECKS=1 FLOW_SCENARIO=room FLOW_CLIENTS=3` runs a bot that walks
  to a monk and the door for real with the checks on.
- The dev panel's Answer Monk / teleport / fast walk are refused or dropped
  by a checking server, as they should be.

### Self-hosted server (Oct 24)
- All accounts, rules, state, records and realtime run on this laptop,
  publicly reachable. Username/password, no emails or password reset.
  Domain **lakbayin.space** (Namecheap, Cloudflare DNS).
- `Net` loads `net/Backend.gd` (the old Supabase client was merged into it and
  removed Oct 25). The default endpoint is `https://server.lakbayin.space`;
  local tests set `LAKBAYIN_SERVER_URL=http://127.0.0.1:8000`. The server
  keeps the REST/Phoenix shapes (`/rest/v1/...`, `/realtime/v1/websocket`)
  the client was first written against.
- `server/app.py`: Argon2id username auth, hashed opaque 30-day revocable
  sessions, SQLite atomic checkpoints, ranked matching, custom rooms,
  answers/lockouts/deposits, rankings, history/board, read-only spectators.
  Auth rate limiting and bounded messages; private sockets enforce
  membership and publisher identity.
- Persistent match data survives a process restart. Absolute clocks continue
  through outages; position/presence are transient and not checkpointed.
- `lakbayin.service` and `lakbayin-tunnel.service` (systemd user units) are
  enabled and restart on failure; linger is on, so they start before login.
  `python -m server.manage config` prints config.
- Public tunnel: **lakbayin-game**, UUID
  `602e56f1-54e1-4b7c-a72d-b946aea626f2`. Its credentials and `lakbayin.yml`
  live under `~/.cloudflared`, never in the repository. Only
  `server.lakbayin.space` routes to `http://127.0.0.1:8000`; unmatched hosts
  return 404. Do not modify the unrelated `fscs-laptop` tunnel.
- `server/tests/run_godot.py` repeats a live check with two real Godot clients.

### Done and tested
- **Day 1:** Baybayin keypad, word list, server answer checking, monk node,
  rename to Lakbayin.
- **Day 2:** procedural world, the match screen and HUD (with a minimap and
  team vision), carry/deposit, timer win, results screen, Practice.
- **Removed:** teacher mode, gems, stations, quizzes, Rescue and the old
  leaderboard.
- **Menu scenery:** Home now shows a Purple Monastery village, houses,
  monks with Baybayin glyphs, and the selected adventurer. `Backdrop.gd` pans
  across peaceful monastery/village/forest islands; military scenery is gone.
  Fonts and Home button layout are retained. Match-generation files are unchanged.
- **Built:** typing marker on monks (DESIGN.md), custom rooms with host
  Move/Shuffle and host transfer (§6.2, `RoomScreen.gd`), Watch (§6.4,
  `WatchScreen.gd`), Records (§7). Each was checked live across laptop
  clients and the Realme, and a full 3 v 3 (five laptop clients plus the
  Realme) played to a ten-word finish and to a timeout.

### Phones
- Realme RMX1851: `6d718c9c`. Second phone (23106RN0DA): `8DSWAYCU99PRWOMN`.
  USB debugging is authorized on both. With both connected, use
  `ANDROID_SERIAL` or `adb -s SERIAL`. The second phone may ask to accept
  the install again after each rebuild.


### Known rough edges
- The minimap (132×74) covers the top-right of the play view.
- Islets and coasts are blocky (4-neighbour autotile).
- Movement goes out every 50 ms (`Net.movement_interval()`) on the match's
  snapshot channel; the server checks each path and passes it on. There is no
  relay any more.

## 4. Where things are

| Area | Files |
|---|---|
| World generation (pure data, seeded, mirrored) | `game/scripts/map/WorldGen.gd` |
| World nodes (tiles, props, monks, Monastery, houses) | `game/scripts/map/MapWorld.gd`, `MapBuilder.gd`, `MapGrid.gd`, `Decor.gd`, `config/MapCfg.gd` |
| Match screen (walk, look, monks, deposit, online sync, end) | `game/scripts/AdventureScreen.gd` (route `"adventure"`, `{"practice": true}` for Practice) |
| HUD + minimap | `game/scripts/AdventureHud.gd` (`Minimap` inner class) |
| Match state, Practice and online | `game/scripts/Match.gd` |
| Monk answer panel, keypad, Baybayin rules | `MonkOverlay.gd`, `BaybayinKeypad.gd`, `Baybayin.gd`, `Monk.gd` |
| Results | `game/scripts/ResultsScreen.gd` |
| Matchmaking lobby UI | `game/scripts/TeamNameScreen.gd` (Find Match; code join is teacher-era) |
| Network | `game/scripts/net/` (`Backend.gd` = `Net` autoload, `Realtime.gd`, `Dial.gd`, `Teams.gd`, `Monks.gd`, `Lobby.gd`) |
| Clock, profile, input | `game/scripts/Game.gd` (`Game` autoload) |
| Words | `game/tools/make_words.py` → `game/data/words.json`, which the server reads too (from the Tagalog Swadesh list; both spellings generated by rule) |
| Server rules | `server/app.py` (`rpc()`: matchmaking, rooms, answers, deposits, records; `moved_ok`/`placed_ok`: position checks); tests in `server/tests/` |

## 5. Running things

```bash
cd ~/Workspace/games/levelup-entry/game
godot --headless --import --path .        # after adding any new class_name script
tools/run_tests.sh                         # every Godot suite (~4 min); forces an offline dummy backend
godot --headless --path . res://scripts/tests/match_test.tscn   # one suite
python3 tools/make_words.py               # regenerate words after editing WORDS
```

Server tests (from the repo root; one plays real maps with this project's Godot):

```bash
server/.venv/bin/python -m unittest server.tests.test_server
```

Phone (Realme RMX1851, shared with other apps; check it's in front before
injecting input):
- `game/tools/device.sh install|run|shot NAME|log`
- Package `com.lakbayin.game`.
- If an Android/Gradle export hangs at full CPU with no output, it's the
  laptop's Gradle memory cap. Raise it for that run only:
  `export GRADLE_OPTS='-Dorg.gradle.jvmargs="-Xmx2g -XX:MaxMetaspaceSize=1g"'`.

Screenshots of a running build: a `SceneTree` script run with
`godot --path . --resolution 1280x720 --script <file>`, saving
`root.get_texture().get_image()`. Headless can't render.

## 6. Gotchas learned the hard way

- **New `class_name` scripts** aren't visible until
  `godot --headless --import --path .` updates the class cache. Until then
  you get "Identifier not declared".
- **A script parse error makes a test scene hang** instead of fail. If a suite
  times out with no output, run
  `godot --headless --path . --quit-after 60` and grep for `Parse Error`.
- `match` is a GDScript keyword. The match screen's state is `play`.
- **Don't add the Baybayin font as a global fallback.** It made every line in
  the game 1 px taller and broke the layout suite. It's applied per label with
  `Art.baybayin()`.
- **Godot `:=` can't infer types** from untyped array or dictionary elements.
  Declare them, e.g. `var x: String = ...`.
- **Tests expect a configured server.** `run_tests.sh` exports
  `LAKBAYIN_SERVER_URL=https://offline.invalid`. Run single suites with it
  set too, or login-gate checks fail.
- **Windowed tools stall when the screen sleeps** (vsync waits on a display
  that is off). Pass `--disable-vsync`.
- **Use `MapGrid.flood` sparingly:** it tests every wall at every step. For
  reachability, rasterise walls to cells first (see `world_test.gd`).
- **Never `pgrep -f` / `pkill -f`** with a pattern that appears in your own
  command line: it kills the shell that runs it. Wait on PIDs.
- **Online the server decides everything.** It checks answers, owns carried
  and deposited state, ends the match, and names the winner. The phone only
  shows it. Keep it that way.

## 7. House rules (the user's)

- **Commits:** caveman style (Conventional Commits, imperative, subject
  ≤ 50 chars, hard cap 72, body only for the why). **No AI attribution and
  no `Co-Authored-By` trailer.**
  - Identity: `git -c user.name=Ken-n7 -c user.email=canetejohnkenneth04@gmail.com commit`.
  - Commit in logical batches when asked.
- The user prefers **short, direct answers** ("answer only" means no tool
  work), decisions laid out as options with a recommendation, and nothing
  built that wasn't asked for.
- **Keep `DESIGN.md` current** when a rule changes; §13 records decisions and
  §14 the open questions.
- The design's spelling convention accepts **both** modern (krus-kudlit) and
  traditional Baybayin. Don't add words with *r* or loan letters.
- Credits (Settings → Credits) must keep the license-required lines:
  - Super Retro World artists
  - "Original music by Marllon Silva (xDeviruchi)"
  - The words source (Wiktionary Tagalog Swadesh list, CC BY-SA)
- AI use is disclosed in the game's credits and in the competition's Form 03.

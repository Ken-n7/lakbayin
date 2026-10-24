# Lakbayin — Handoff

Updated 2026-10-24 for the next agent (Codex). Read this, then `DESIGN.md`
(the source of truth for every game rule), then `server/README.md`. Former Supabase notes below are historical.

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

**Deadlines:** entries (videos + forms) due **2026-10-25**; finalists announced
2026-11-09; finals 2026-11-26/27 (General Santos City).

## 2. Repo

- Repo: `~/Workspace/games/levelup-entry` (git, **no remote**, branch `main`).
- Godot project: `game/`.
- Backend: `server/` (FastAPI + SQLite + WebSockets). `supabase/` is the former backend, retained for reference.
- The asset packs at the root (Tiny Swords, Super Retro World, Pixel
  Crawler) are tracked. Pixel Crawler is unused.
- This repo is a **fork** of an earlier client project, NumXventure, at
  `~/Workspace/games/NumXventure`. **Never change that repo.**
  - The fork's history was rewritten: client documents were removed, and every
    commit is authored by `Ken-n7 <canetejohnkenneth04@gmail.com>`.
  - Don't mention the client in docs or commits.

## 3. State

### Current: self-hosted server migration (Oct 24)
- User changed architecture: all accounts, rules, state, records and realtime
  run on this machine, publicly reachable, not LAN-only. Username/password,
  no emails or password reset. Domain **lakbayin.space**, registered at
  Namecheap. On Oct 24 the user corrected/confirmed **lakbayin.space**
  (earlier `.website` was wrong). Cloudflare DNS and the named tunnel are live.
- `Net` now loads `net/SelfHosted.gd`. The default endpoint is
  `https://server.lakbayin.space`; local tests set
  `LAKBAYIN_SERVER_URL=http://127.0.0.1:8000`. No Supabase URL/key in the
  shipped project settings. The inherited legacy HTTP helper and compatible
  REST/Phoenix envelopes do not contact Supabase; all requests hit this server.
- `server/app.py` supplies Argon2id username auth, hashed opaque 30-day
  revocable sessions, SQLite atomic checkpoints, ranked matching, custom
  host controls/cleanup, answers/lockouts/deposits, finish/timeout rankings,
  history/board and read-only spectators. Auth rate limiting and bounded
  messages; private sockets enforce membership and publisher identity.
- New local config: **1v1**, **900 seconds**, ten monks. Current map generation,
  art, fonts and Home placement remain unchanged. Movement is 20Hz with a
  100ms minimum playback buffer; this is not a measured Internet latency.
  Movement/collision are still client simulated; outcomes are server-owned.
- Persistent match data survives process restart. Absolute clocks continue
  through outages; position/presence are transient and are not checkpointed.
  Local accounts start fresh; remote Supabase users/history were neither
  imported nor deleted. Do not alter the unrelated connected projects.
- Login/Register have no email or recovery controls. The reset router entry
  is removed. Results fetch final spellings and deposit states after the
  server ends a match; no correct spellings in active-match responses.
- Start with `server/run.sh` after installing `server/requirements.txt` into
  `server/.venv`. The user systemd unit is installed/enabled: `systemctl --user status lakbayin.service`. Both it and `lakbayin-tunnel.service` are enabled/active and restart on failure. `loginctl show-user ken -p Linger` reports `yes`, so they can start before login.
  `python -m server.manage config` prints config; `backup DEST` makes a
  consistent SQLite backup. Database/venv ignored; protect/retain backups.
- Validation so far: all 15 Godot suites pass (match 46, multiplayer 69,
  e2e 56, layout 0); 11 Python integration cases; isolated two-real-Godot
  clients pass identical seed, movement, presence, answer/deposit and clocks. A real server process restart preserves progress; both clients reconnect and agree on a 10–0 finish and all ten final spellings.
  Server auth/scoring/restart/permissions/concurrency covered. Use
  `server/.venv/bin/python server/tests/run_godot.py` to repeat the live check.
- Public tunnel: **lakbayin-game**, UUID
  `602e56f1-54e1-4b7c-a72d-b946aea626f2`. Its private JSON credentials and
  `lakbayin.yml` live under `~/.cloudflared`, never in the repository. Only
  `server.lakbayin.space` routes to `http://127.0.0.1:8000`; unmatched hosts
  return 404. Do not modify the unrelated `fscs-laptop` tunnel.
- Public validation: `/health`, register/sign-in, private WSS join and movement;
  one movement-delivery sample was 106ms (not a general latency guarantee).
  Restarted the actual tunnel; the same hostname recovered. Two actual Godot
  clients then completed a custom match through public HTTPS/WSS: identical
  seed `596247768`, both received movement and **Blue 10–0 Red** Results with
  ten final spellings. Playback buffers were 100ms. This was automated API/
  client testing, not a human balance playtest or a phone/cellular test.
- Public probe clients have stopped. New private test accounts/info are in
  `/tmp/lakbayin-cloudflare-test/info.json` (mode 600, directory 700); evidence
  and logs are in the same directory. Earlier `/tmp` test credentials and the
  four desktop test windows were lost/closed across the desktop/reboot; do not
  assume those earlier temporary helpers or windows are still present.
- The initial authorization selected `.space`; a DNS CLI call for the earlier
  wrong `.website` name therefore created a suffixed record. That exact
  accidental record was removed through the Cloudflare API before publishing
  the user's confirmed `.space` hostname. It is no longer present.
- Migration/tunnel changes and preceding latency/timer tuning are uncommitted.
  Android export now targets `https://server.lakbayin.space`; APK signature
  and compiled endpoint are verified at `build/Lakbayin.apk`. Phone testing
  remains: ADB currently has no connected devices.



### Movement latency improvement
- The user explicitly kept live matchmaking at **1 v 1** after reporting the
  early start; do not restore 3 v 3 yet. The 15-minute clock remains.
- No fast relay was published. Fixed the direct path: sample every 50 ms;
  send as often as 100 ms for a small match, with an adaptive 60-event/s
  project budget based on active players/rooms and viewers. Idle updates stay
  sparse, but first positions and stops publish promptly. Paths retain actual
  timestamps instead of reconstructing frame-hitched samples with uniform dt.
- Peer playback now follows the sender's cadence (+50 ms), instead of giving
  every direct sender the legacy 750 ms buffer. Old senders and relay playback
  remain compatible. A more aggressive predictive buffer was tested and
  rejected because it caused tracking errors.
- Two-account live movement traces, relay off: baseline **1190 ms** delay /
  6.08 px RMS error; revised path **420 ms** / 0.56 px with other rooms active,
  repeat **320 ms** / 0.68 px with a 150 ms playback buffer. These are local
  live-test measurements, not a guarantee for every network. Evidence:
  ignored `build/shots/latency/` (summaries and traces).
- All **15 client suites pass**; multiplayer **69**, including traffic pacing,
  viewers, real timestamps, backward compatibility, stop packets and retaining
  pending movement while a private channel joins. The four isolated desktop
  test windows are refreshed and signed in on Home. No SQL change needed.
- The new Android APK is built and verified at `build/Lakbayin.apk`. Realme
  installation could not run because the phone is no longer connected over
  USB (ADB has no devices). Install this APK after reconnecting it.
- The isolated latency probe clients have stopped; their custom session
  expires normally. Verified live config is still `team_size = 1`,
  `duration_s = 900`.
- These changes and the earlier timer/results tuning remain uncommitted.

### Latest requested tuning
- Results now display the Filipino word and Baybayin spelling only; English
  meanings remain in source data but are not rendered.
- The match clock is now **15 minutes (900 s)** in Practice and new server
  defaults. Schema reruns upgrade the former 360 s config to 900 s while
  preserving team size, other custom durations, and existing session clocks.
- Local checks: match suite **46**, clock rules, layout **0** overflows at
  640/800; full SQL suite **266** plus upgrade/rerun/concurrency checks.
- The user applied the live config update and reported 900. Verified through
  the authenticated API: `duration_s = 900`, `team_size = 1`. A newly created
  custom room also had 900 s; its empty lobby was closed after the check.
  The connector still cannot access this project. Confirm email stays off.
- Updated Android APK exported and installed on the Realme; Practice runs
  with the fifteen-minute clock. These tuning changes are uncommitted.

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
- **Two-phone test setup:** `match_config.team_size` now accepts **1–5**,
  with a re-runnable upgrade for existing projects. The default remains **3**.
  The full SQL suite passes, including 29 matchmaking checks and an explicit
  upgrade from the old 2–5 constraint that preserves a configured 1 v 1.

### Live online play: two-phone 1 v 1 verified 2026-10-23
- The user's Supabase project is `https://yvklwmtsvjgppnmtlede.supabase.co`;
  its anon key is already in `game/project.godot`.
- The user reported running `schema.sql` and `words.sql`. The old 2–5
  team-size check was still active, so the user applied the explicit
  drop/add-constraint upgrade in the SQL Editor. Live API reads confirmed
  `team_size = 1`.
- Never ask for, or store, the `service_role` key.
- **Current live settings, by the user's explicit request:** leave
  `team_size = 1` and **Confirm email off** for more testing. The schema's
  default is still 3. Restore 3 v 3 and email confirmation when the user wants
  normal settings again.
- The Supabase connector's account **cannot access** Lakbayin's project.
  The user must run administrative SQL in its SQL Editor; do not change
  either of the unrelated projects the connector lists. Normal authenticated
  API access as the test players works.
- **Both phones have the current debug APK installed and are signed in:**
  - Realme RMX1851: `6d718c9c`, player `laktest_a_e6be92`, hero 1.
  - Second phone (23106RN0DA): `8DSWAYCU99PRWOMN`, player `laktest_b_e6be92`,
    hero 2.
  - USB debugging and USB installation are authorized. With both connected,
    use `ANDROID_SERIAL` or `adb -s SERIAL` explicitly. The second phone may
    require accepting an installation prompt again after each rebuild.
- **Verified live:** both enter the same match and build the same island;
  each manually typed a correct Baybayin answer; carried words do not score.
  In the final match (`1df4e1b8-ee7f-4d54-8df6-1e77065381a4`), the Realme
  deposited ten words at the Monastery. The server ended the match, and both
  phones loaded **Red 10–0 Blue**, matching player standings and word lists.
  The winner's words were marked deposited. Neither updated phone process
  logged a script error.
  - Existing debug Teleport and Answer Monk tools accelerated that earlier
    finish. Six-player ordinary walking and teammate updates have now been
    verified below.
  - Evidence: `build/shots/1v1-results-realme.png` and
    `build/shots/1v1-results-second-phone.png` (ignored build artifacts).
- **Two live bugs fixed:**
  - `Lobby.load` now selects `teams!teams_session_id_fkey`; the unqualified
    embed became ambiguous after adding the match's winner relationship.
  - `ResultsScreen` treats a null `team_standings.finished` as false, avoiding
    a crash on timeout when there is no `winner_team`. Parsing and ranking
    have regression coverage. Reading the actual timed-out match's standings
    now succeeds with both teams, both players, and a draw title.
- **Validation:** full SQL suite (179 checks plus schema/concurrency checks),
  Godot multiplayer suite (14 checks), Godot match suite (44 checks), live
  timeout standings read, Android export, and the two-phone finish above.
  The user has authorized testing and a separate commit after each remaining
  feature. Baseline commit: `ad34cb7` (rooms, fonts, scenery, 1 v 1 fixes).
- **Current verification:** six-player custom matches now pass normal walking,
  teammate updates, reconnect/carry recovery, timeout ties and a ten-word
  finish (below). Human balance review remains. Online code paths:
  `AdventureScreen._join_online`, `_go_live`, `_on_row`, `Match.start_online`
  / `take_row`, `ResultsScreen._standings`.

### Completed features and remaining submission work
1. **Typing marker built:** teammate presence shows “Teammate typing…” on
   monks. Hints expire after 12 s and clear on close, lockout, answer, or
   disconnect; they never block interaction or transmit typed answers.
   Verified between two real laptop clients in the same live room: opening
   one keypad marks the monk on the other client. The public key was valid;
   an OpenAPI discovery failure was initially mistaken for a key error.
   Core game API requests work. Typing commit: `c420069`.
2. **Custom rooms** (§6.2): built. Home → Custom Room → `RoomScreen.gd`
   (extends `TeamNameScreen`'s lobby); server `create_room` / `start_room` /
   `leave_room` (schema 4f, `rooms_test.sql`). Host Move/Shuffle and room
   heartbeat cleanup are now implemented. Lobby phones poll every 3 s;
   30 s silence drops a member and transfers hosting if needed. Running
   memberships remain intact. The user applied the SQL. Verified live Move,
   Shuffle, closed-client cleanup, and host transfer across laptop clients,
   with the Realme joining the same room. SQL: 37 room checks plus both
   Start/cleanup lock-order races; client multiplayer: 38 checks. Room commit: `ee83e9d`.
3. **Watch mode built** (§6.4): Custom Room → code → Watch. Read-only aerial
   island, both rosters, per-team monk markers, carried/deposited counts,
   final result. Renewable viewer registrations never create memberships;
   movement receive only. Relay players also send bounded snapshots while
   viewers are present. Local SQL: 24 authorization/state checks; multiplayer:
   48 checks, plus a clean 640/800 layout run. All other client suites pass.
   The user applied the SQL. A live viewer receives both laptop positions,
   lobby/start updates, independent monk state and carried/deposited counts.
   Watch commit: `4cda679`.
4. **Records built** (§7): Settings → Player Records; online Results also
   links to My Matches. Completed history includes Custom tags, own rank and
   deposits. Global Players counts only matchmade games, ordered by wins then
   deposited answers. Abandoned lobbies / active matches / Practice are
   excluded; exact ties award no wins. 20 rows/page, server-derived results;
   24 SQL checks. Client multiplayer: 53 checks; match: 44; layout: zero
   overflow at 640/800. Results now retain sub-second deposit tie-breaks.
   The user applied the SQL. Verified actual My Matches and Global Players
   on the updated Realme, including its earlier 10-deposit matchmade win.
   All Godot suites and the complete SQL suite pass.
5. **Full 3 v 3 verified:** five isolated laptop clients plus the Realme,
   three players per team. See the live playtest notes below.
6. **Videos and forms** for the 25 Oct entry: 1–2 min trailer, 3–5 min
   gameplay video, Forms 01–03, a ≤500-word synopsis. Practice mode records
   fine solo.

### Live six-player playtest: verified 2026-10-23
- **Timeout:** room `889Y`, session `fa96d515-956b-4d9d-8cdd-2eb7a7e21ed3`.
  All six connected, five remote positions on every laptop, identical seed
  `93709977`. Blue teammate typing/answered states propagated. Carried words
  survived restarting all five laptop clients. Both sides walked to monks,
  answered and walked to the Monastery. Final: **Red wins 2–2**, reaching two
  deposits at `09:45:12.151046Z` before Blue at `09:45:23.760422Z`.
- **Ten-word finish:** room `E4KU`, session
  `3f39041a-041a-4312-8c82-ffb13e22a964`. Automated laptop controls used normal
  movement, collision checks, keypad entry and interaction throughout; no
  teleport or direct scoring RPC shortcut. All three Blue players contributed
  (4/3/3 deposits), and both Red laptop players deposited three each. The
  Realme stayed connected on Red. Final: **Blue 10–6 Red**, ending for all six
  at `13:01:46.628282Z`. All five laptop Results and the Realme agreed.
- The phone's history records the Custom loss, rank 6, zero own deposits.
  The global board stayed unchanged by both custom matches. Live Watch also
  received a complete 10–0 finish in room `NRC6` before these tests.
- Evidence under ignored `build/shots/features/`: `six-timeout.json`,
  `six-complete.json`, `six-live-run.json`, `six-finish-progress.json`,
  `six-teammate-typing.json`, `watch-live-*.json`. Phone captures copied there
  as `six-timeout-realme.png`, `six-complete-realme.png`, `records-realme.png`,
  `board-realme.png`. Private test credentials remain only in `/tmp`.
- Live-play fixes: completed Watch shows **Final**, and Results shares ranks
  for exact contribution/time ties, matching My Matches. Neither changes map
  generation, fonts or the approved Home composition.
- Latest validation: all 15 Godot suites, including multiplayer **55**, match
  **44**, and layout **0** overflows at 640/800; complete SQL suite **264**
  numbered checks plus schema upgrade/rerun and concurrency checks. Android
  debug export and updated Realme install. Records commit: `06b8a7e`.
- This was automated multi-client testing with a connected phone, not six
  human players. Word review, human usability/balance and submission media
  still need attention. Live ranked size remains **1** and email confirmation
  remains **off**, as requested; custom 3 v 3 needs no configuration change.

### Known rough edges
- The minimap (132×74) covers the top-right of the play view.
- `schema.sql` still holds the dead teacher/gem functions and tables
  (`apply_answer`, `rescue`, `questions`, `team_scores`, …). They're harmless;
  remove them in a cleanup, along with their SQL tests (rescue, leaderboard,
  scoring, isolation).
- Islets and coasts are blocky (4-neighbour autotile).
- Direct movement rate adapts to project load: up to 10 Hz for a small match,
  about 1.67 Hz for an otherwise idle 3 v 3. Use the movement relay for high
  rates in larger rooms or many simultaneous games.

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
| Network | `game/scripts/net/` (`SelfHosted.gd` = `Net` autoload, `Realtime.gd`, `RelayLink.gd`, `Teams.gd`, `Monks.gd`, `Lobby.gd`) |
| Clock, profile, input | `game/scripts/Game.gd` (`Game` autoload) |
| Words | `game/tools/make_words.py` → `game/data/words.json` + `supabase/words.sql` (from the Tagalog Swadesh list; both spellings generated by rule) |
| Server rules | `supabase/schema.sql`: §4d matchmaking (`find_match`, `poll_match`, `leave_match`, `match_config`); §4e monks (`words`, `session_words`, `monk_answers`, `answer_monk`, `deposit`, `team_standings`, `player_standings`) |

## 5. Running things

```bash
cd ~/Workspace/games/levelup-entry/game
godot --headless --import --path .        # after adding any new class_name script
tools/run_tests.sh                         # every Godot suite (~4 min); forces an offline dummy backend
godot --headless --path . res://scripts/tests/match_test.tscn   # one suite
python3 tools/make_words.py               # regenerate words after editing WORDS
```

SQL tests (no psql on the host; use Docker):

```bash
docker run -d --rm --name nx-pg -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v ~/Workspace/games/levelup-entry:/repo:ro postgres:15
docker exec -e PGUSER=postgres -e PGHOST=/var/run/postgresql nx-pg \
  bash -c 'cd /repo && bash supabase/test/run.sh'
docker stop nx-pg
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
- **Tests expect a configured backend.** `run_tests.sh` exports
  `SUPABASE_URL=https://offline.invalid`. Run single suites with those env vars
  set too, or login-gate checks fail.
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

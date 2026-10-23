# Lakbayin — Handoff

Written 2026-10-23 for the next agent (Codex). Read this, then `DESIGN.md`
(the source of truth for every game rule), then `supabase/README.md`.

## 1. What this is

**Lakbayin** is a Godot 4.6 game for the **DOST Level Up 3.0 Esports Game Dev
Challenge** (Student Category; themes: Education + Philippine culture).

- 3 v 3 (setting goes 2–5 a side), matchmade, timed matches.
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
- Backend: `supabase/` (Postgres schema + SQL tests).
- The asset packs at the root (Tiny Swords, Super Retro World, Pixel
  Crawler) are tracked. Pixel Crawler is unused.
- This repo is a **fork** of an earlier client project, NumXventure, at
  `~/Workspace/games/NumXventure`. **Never change that repo.**
  - The fork's history was rewritten: client documents were removed, and every
    commit is authored by `Ken-n7 <canetejohnkenneth04@gmail.com>`.
  - Don't mention the client in docs or commits.

## 3. State

### Done and tested
- **Day 1:** Baybayin keypad, word list, server answer checking, monk node,
  rename to Lakbayin.
- **Day 2:** procedural world, the match screen and HUD (with a minimap and
  team vision), carry/deposit, timer win, results screen, Practice.
- **Removed:** teacher mode, gems, stations, quizzes, Rescue and the old
  leaderboard.

### Not tested yet: online play on the live project
- The user's Supabase project is `https://yvklwmtsvjgppnmtlede.supabase.co`;
  its anon key is already in `game/project.godot`.
- Its tables exist. The user was asked to **re-run `supabase/schema.sql` and
  then `supabase/words.sql`** in the SQL Editor; the house-removal change needs
  the re-run.
- Never ask for, or store, the `service_role` key.
- **First job: a real 2-phone match.**
  1. Set `update public.match_config set team_size = 2;` for testing.
  2. Two accounts press Find Match.
  3. Check that the match starts, both see the same world, answers grey out
     monks for teammates, deposits update the scoreline, and the results load
     standings.
  4. Online code paths to watch: `AdventureScreen._join_online`, `_go_live`,
     `_on_row`, `Match.start_online` / `take_row`, `ResultsScreen._standings`.

### Not built (from DESIGN.md)
1. The "teammate is typing" **busy** marker on monks (§3.2).
2. **Custom rooms** (§6.2): `TeamNameScreen` still has join-by-code and the
   team picker from teacher mode.
   - Rework so a player is host: create room, code, start.
   - The server's `can_use_movement` lets members publish snapshots only in
     `matchmade` sessions; custom rooms need the same.
   - `is_matchmade` gates the join rules.
3. **Watch mode** (§6.4, spectator for the event screen).
4. **My Matches** history and the **global player board** (§7); the
   Leaderboard button was taken off Home.
5. **Videos and forms** for the 25 Oct entry: 1–2 min trailer, 3–5 min
   gameplay video, Forms 01–03, a ≤500-word synopsis. Practice mode records
   fine solo.

### Known rough edges
- On Home, the tower's floating glyphs draw over open dialogs
  (`HomeScreen._build_tower`, `holder.z_index = 1`). Pre-existing.
- The minimap (132×74) covers the top-right of the play view.
- `schema.sql` still holds the dead teacher/gem functions and tables
  (`apply_answer`, `rescue`, `questions`, `team_scores`, …). They're harmless;
  remove them in a cleanup, along with their SQL tests (rescue, leaderboard,
  scoring, isolation).
- Islets and coasts are blocky (4-neighbour autotile).
- With the relay down, each phone broadcasts its own position once a second
  (about 30 messages/s at 3 v 3, inside the Supabase free tier). For bigger
  matches run the relay: `game/tools/relay/run.sh`.

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
| Network | `game/scripts/net/` (`Supabase.gd` = `Net` autoload, `Realtime.gd`, `RelayLink.gd`, `Teams.gd`, `Monks.gd`, `Lobby.gd`) |
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

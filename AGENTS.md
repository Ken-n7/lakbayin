# Agent notes

Start with `HANDOFF.md` (current state, what's next, gotchas), then
`DESIGN.md` (every game rule; keep it current).

- Godot 4.6 project in `game/`; tests: `game/tools/run_tests.sh`. Run
  `godot --headless --import --path game` after adding a `class_name` script.
- Server in `server/` (FastAPI + SQLite); tests:
  `server/.venv/bin/python -m unittest server.tests.test_server` from the repo root.
- Commits: caveman style (Conventional Commits, subject ≤ 50 chars), author
  `Ken-n7 <canetejohnkenneth04@gmail.com>`, **no AI attribution or
  Co-Authored-By trailer**. Commit only when asked.
- Never touch `~/Workspace/games/NumXventure` (the original client project).

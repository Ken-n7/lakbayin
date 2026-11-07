# Lakbayin

![Lakbayin title screen](https://ken-n7.github.io/portfolio/previews/lakbayin-cover.webp)

A 3v3 word race on a procedurally generated island. Monks are scattered around
the map, each holding a Filipino word. Find one, write the word in **Baybayin**
on the in-game keypad, then carry the answer back to the Monastery, which is
hidden somewhere on the map. The first team to deposit every word wins. If the
clock runs out, the team with more words wins.

This is transliteration, not translation: *bahay* written in Baybayin is still
*bahay*. Made for the DOST Level Up 3.0 Esports Game Dev Challenge (student
category).

[Watch the trailer](https://ken-n7.github.io/portfolio/previews/lakbayin-trailer.mp4)

## What's in here

- `game/` is the Godot 4.6 client (Android landscape and Windows). It has
  online rooms, a spectator view, and an offline solo practice mode.
- `server/` is the game server: FastAPI, SQLite and WebSockets for accounts,
  matchmaking, scoring and records. Setup is in [`server/README.md`](server/README.md).
- [`DESIGN.md`](DESIGN.md) has every game rule.
- [`HANDOFF.md`](HANDOFF.md) has the current state of the project.
- [`game/DEVTOOLS.md`](game/DEVTOOLS.md) covers the screenshot and video tools.

## Run it

```sh
# server
python3 -m venv server/.venv
server/.venv/bin/pip install -r server/requirements.txt
server/run.sh

# client
LAKBAYIN_SERVER_URL=http://127.0.0.1:8000 godot --path game
```

Practice mode works without the server.

Tests: `game/tools/run_tests.sh` for the client, and
`server/.venv/bin/python -m unittest server.tests.test_server` for the server.

## Credits

- Art: [Tiny Swords](https://pixelfrog-assets.itch.io/tiny-swords) by Pixel Frog.
  Characters from Super Retro World by Gif (@gif_not_jif), Noiracide
  (@Noiracide) and Romi (@DessRomaric).
- Music: original music by Marllon Silva (xDeviruchi).
- Fonts: Kaushan Script, Kalam, Noto Sans Tagalog.

The art and music belong to their creators and are under their own licences.
They are not covered by this repo.

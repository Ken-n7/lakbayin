# Lakbayin self-hosted server

Accounts, matches, scoring, records and WebSockets run here. No Supabase or
email service is required. The client keeps its existing protocol envelopes,
so `/rest/v1/` and Phoenix message names are local compatibility routes.

## Start locally

From the repository root:

```sh
python3 -m venv server/.venv
server/.venv/bin/pip install -r server/requirements.txt
server/run.sh
```

The server binds **127.0.0.1:8000**, ready for a named Cloudflare Tunnel. Test:

```sh
curl http://127.0.0.1:8000/health
LAKBAYIN_SERVER_URL=http://127.0.0.1:8000 godot --path game
```

Create a new username/password account. Former remote accounts and history
are not migrated. Passwords use Argon2id; sessions are random opaque tokens,
stored hashed in SQLite, valid for 30 days and revoked on online logout.
There is no email, confirmation or password reset. Accounts always have the
player role. Passwords are 8–256 characters; usernames are 3–20 ASCII letters,
digits, `_` or `-`, unique regardless of case.

`server/data/lakbayin.sqlite3` holds accounts and atomic match checkpoints.
Keep it across restarts. SQLite uses WAL and full synchronous commits. The
DB and virtual environment are ignored by git. Set `LAKBAYIN_DB` to relocate
it, or `LAKBAYIN_PORT` to change the loopback port.

The current defaults are **1v1**, **15 minutes**, **10 monks**. Change new-game
settings locally, never through a public admin endpoint:

```sh
server/.venv/bin/python -m server.manage config
server/.venv/bin/python -m server.manage config --team-size 3 --duration 900
server/.venv/bin/python -m server.manage backup /absolute/private/backup.sqlite3
```

Backups contain account hashes and session hashes; keep them private. The
backup command uses SQLite's online backup API so it includes committed WAL
contents. An existing destination is refused.

## Public hostname and restart

The client defaults to **https://server.lakbayin.space**. The domain remains
registered at Namecheap, with Cloudflare DNS and a persistent named tunnel.
Configure the tunnel's public hostname to send HTTP to
**http://127.0.0.1:8000**. The same hostname serves HTTPS auth and secure
WebSockets; no separate relay, UDP forwarding, or email login gate is needed.
Cloudflare routes traffic; this machine owns all game/account data.

The named `lakbayin-game` tunnel and DNS route are live. Public HTTPS auth,
private WSS movement, a complete two-Godot-client match and tunnel restart
have been verified. A fixed hostname retains its address after a restart,
but the game is unavailable while this server or Internet is down.

The user systemd unit is installed/enabled on this machine and is tracked at `server/deploy/lakbayin.service`. After
installing dependencies, it can be installed with:

```sh
mkdir -p ~/.config/systemd/user
cp server/deploy/lakbayin.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now lakbayin.service
journalctl --user -u lakbayin.service -f
```

On this machine both services are enabled and user lingering is already on,
so startup can occur before login. Both restart on failure. On another machine,
boot before login requires enabling user lingering separately. The units
assume this repository's current location.

The tunnel configuration is private at `~/.cloudflared/lakbayin.yml`; it
routes only `server.lakbayin.space` to the loopback server, with a final
`http_status:404` rule. Its tunnel-specific credential JSON stays in that
private directory. To install the tracked tunnel service:

```sh
cp server/deploy/lakbayin-tunnel.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now lakbayin-tunnel.service
journalctl --user -u lakbayin-tunnel.service -f
```

Use **one worker**. Live sockets belong to one process; multiple workers need
a shared broker first. Match state is persisted transactionally, including
words, rosters, carry, deposits, lockouts and absolute match deadlines. A
server restart preserves progress; clocks continue during downtime. Positions
and typing/presence are transient and reconnect, not checkpointed. Movement
is client simulated; this server checks publisher identity and scoring rules,
not world collisions or interaction distance. This retains existing gameplay
trust boundaries rather than adding a new anti-cheat simulation.

## Checks

```sh
server/.venv/bin/pip install -r server/requirements-test.txt
server/.venv/bin/python -m unittest discover -s server/tests -v
server/.venv/bin/python server/tests/run_godot.py
bash game/tools/run_tests.sh
```

The live integration check starts an isolated loopback server/database and two
actual Godot clients, verifies matching seeds, movement, presence and scoring,
restarts the actual server with its database, then verifies both clients
reconnect and reach matching 10–0 Results with all final spellings. It then
stops its processes. It never needs remote accounts. The
Python integration cases cover auth hashing/revocation, queue capacity/expiry,
room authority/cleanup, spectators, concurrent answers, durable progress,
finish/timeout, history and ranked-only records. Procedural generation is
unchanged.

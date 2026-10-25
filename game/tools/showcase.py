"""Records footage for the trailer and the gameplay video (tools/showcase.gd)
from real matches against a throwaway local server. Run from the repo root:

  server/.venv/bin/python game/tools/showcase.py match OUT   # hero's matchmade 3 v 3
  server/.venv/bin/python game/tools/showcase.py room OUT    # a spectator's custom room

The recorded client is windowed; the other players run headless."""
import json, os, secrets, socket, sqlite3, subprocess, sys, tempfile, time
from pathlib import Path
import httpx

ROOT = Path(__file__).resolve().parents[2]
SCENARIO = sys.argv[1]
OUT = Path(sys.argv[2]).resolve()
OUT.mkdir(parents=True, exist_ok=True)
for f in ('queue', 'room_code.txt'):
    (OUT / f).unlink(missing_ok=True)
# Name, hero sheet. The first is the one recorded in `match`.
PLAYERS = [('Malaya', 1), ('Bayani', 7), ('Dalisay', 12), ('Tala', 21), ('Ligaya', 5), ('Amihan', 28)]
if SCENARIO == 'room':
    PLAYERS = [('Hiraya', 3)] + PLAYERS
with tempfile.TemporaryDirectory(prefix='lakbayin-show-') as tmp:
    tmp = Path(tmp)
    db = sqlite3.connect(tmp / 'db.sqlite3')
    db.execute('create table checkpoint (id integer primary key check(id=1), data text not null)')
    db.execute('insert into checkpoint values(1,?)', (json.dumps({'sessions': {}, 'config': {
        'id': 1, 'team_size': 3, 'duration_s': 900, 'monks': 10, 'search_s': 90}}),))
    db.commit(); db.close()
    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
    url = f'http://127.0.0.1:{port}'
    env = {**os.environ, 'LAKBAYIN_DB': str(tmp / 'db.sqlite3'), 'LAKBAYIN_SERVER_URL': url,
           'LAKBAYIN_TEST_INFO': str(tmp / 'info.json'), 'LAKBAYIN_SPECTATOR_DELAY_S': '0',
           'SHOW_SCENARIO': SCENARIO, 'SHOW_PLAYERS': str(len(PLAYERS) - 1)}
    log = open(OUT / 'server.log', 'w')
    server = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'server.app:create_app', '--factory',
                               '--host', '127.0.0.1', '--port', str(port)], cwd=ROOT, env=env, stdout=log, stderr=log)
    clients = []
    try:
        c = httpx.Client(base_url=url, timeout=5)
        for _ in range(100):
            try:
                if c.get('/health').is_success: break
            except httpx.ConnectError: pass
            time.sleep(.05)
        accounts = []
        for name, hero in PLAYERS:
            pw = secrets.token_urlsafe(18)
            c.post('/auth/register', json={'username': name, 'password': pw}).raise_for_status()
            accounts.append({'username': name, 'password': pw, 'hero': hero})
        (tmp / 'info.json').write_text(json.dumps({'accounts': accounts}))
        for i in range(len(PLAYERS)):
            role = ('hero' if SCENARIO == 'match' else 'watch') if i == 0 else 'bot'
            o = open(OUT / f'godot-{i}.log', 'w')
            args = ['godot', '--path', 'game', '--disable-vsync']
            args += ['--resolution', '640x360'] if i == 0 else ['--headless']
            args += ['res://tools/showcase.tscn', '--', f'--player={i}', f'--role={role}', f'--out={OUT}', f'--profile=show-{i}']
            clients.append((subprocess.Popen(args, cwd=ROOT, env=env, stdout=o, stderr=o), o))
        codes = [p.wait(timeout=1200) for p, _ in clients]
        for i, code in enumerate(codes):
            print(f'--- client {i} exit {code}')
            print('\n'.join(l for l in (OUT / f'godot-{i}.log').read_text().splitlines()
                            if 'ERROR' in l or 'recorded' in l or 'WARNING' in l)[-2000:])
    finally:
        for p, o in clients:
            if p.poll() is None: p.terminate()
            o.close()
        server.terminate(); server.wait(timeout=5); log.close()

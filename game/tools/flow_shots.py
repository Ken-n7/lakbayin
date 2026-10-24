"""Two windowed clients through the online flow against a throwaway local
server; screenshots land in OUT (default /tmp/lakbayin-flow). Run from the
repo root:  server/.venv/bin/python game/tools/flow_shots.py [OUT]"""
import json, os, secrets, socket, subprocess, sys, tempfile, time
from pathlib import Path
import httpx

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/lakbayin-flow').resolve()
OUT.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='lakbayin-flow-') as tmp:
    tmp = Path(tmp)
    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
    url = f'http://127.0.0.1:{port}'
    env = {**os.environ, 'LAKBAYIN_DB': str(tmp / 'db.sqlite3'), 'LAKBAYIN_SERVER_URL': url,
           'LAKBAYIN_TEST_INFO': str(tmp / 'info.json'),
           # The bots answer monks from wherever they stand: no position checks,
           # unless FLOW_CHECKS asks for them (the bot then walks).
           'LAKBAYIN_GODOT': os.environ.get('LAKBAYIN_GODOT', 'godot') if os.environ.get('FLOW_CHECKS') else ''}
    log = open(OUT / 'server.log', 'w')
    server = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'server.app:create_app', '--factory',
                               '--host', '127.0.0.1', '--port', str(port)],
                              cwd=os.environ.get('FLOW_SERVER_ROOT', ROOT), env=env, stdout=log, stderr=log)
    clients = []
    try:
        c = httpx.Client(base_url=url, timeout=5)
        for _ in range(100):
            try:
                if c.get('/health').is_success: break
            except httpx.ConnectError: pass
            time.sleep(.05)
        names = ['Malaya', 'Dalisay', 'Tala', 'Bayani', 'Ligaya', 'Mayumi', 'Amihan', 'Dakila', 'Hiraya', 'Kalinaw', 'Liwayway'][:int(os.environ.get('FLOW_CLIENTS', '2'))]
        accounts = []
        for n in names:
            pw = secrets.token_urlsafe(18)
            c.post('/auth/register', json={'username': n, 'password': pw}).raise_for_status()
            accounts.append({'username': n, 'password': pw})
        (tmp / 'info.json').write_text(json.dumps({'accounts': accounts}))
        for i in range(len(names)):
            o = open(OUT / f'godot-{i}.log', 'w')
            p = subprocess.Popen(['godot', '--path', 'game', '--resolution', '960x540',
                                  'res://tools/flow_shots.tscn', '--', f'--player={i}', f'--out={OUT}',
                                  f'--profile=flow-{i}'], cwd=ROOT, env=env, stdout=o, stderr=o)
            clients.append((p, o))
        codes = [p.wait(timeout=240) for p, _ in clients]
        for i in range(len(names)):
            print(f'--- client {i} exit {codes[i]}')
            print('\n'.join(l for l in (OUT / f'godot-{i}.log').read_text().splitlines()
                            if 'shot' in l or 'ERROR' in l)[-3000:])
    finally:
        for p, o in clients:
            if p.poll() is None: p.terminate()
            o.close()
        server.terminate(); server.wait(timeout=5); log.close()

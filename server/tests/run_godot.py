"""Run two real Godot clients against an isolated server; no remote accounts."""
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import httpx

ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='lakbayin-live-') as tmp:
    tmp=Path(tmp)
    sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
    url=f'http://127.0.0.1:{port}'
    env={**os.environ,'LAKBAYIN_DB':str(tmp/'db.sqlite3'),'LAKBAYIN_SERVER_URL':url,'LAKBAYIN_TEST_INFO':str(tmp/'info.json'),'LAKBAYIN_TEST_OUTPUT':str(tmp),'LAKBAYIN_GODOT':''}  # bots answer from anywhere
    log=open(tmp/'server.log','w')
    server=subprocess.Popen([sys.executable,'-m','uvicorn','server.app:create_app','--factory','--host','127.0.0.1','--port',str(port),'--no-access-log'],cwd=ROOT,env=env,stdout=log,stderr=log)
    clients=[]
    try:
        c=httpx.Client(base_url=url,timeout=5)
        for _ in range(100):
            try:
                if c.get('/health').is_success:break
            except httpx.ConnectError:pass
            time.sleep(.05)
        else:raise RuntimeError('Server did not start')
        accounts=[]
        for i in range(2):
            username='live_'+secrets.token_hex(4);password=secrets.token_urlsafe(24)
            r=c.post('/auth/register',json={'username':username,'password':password});r.raise_for_status()
            accounts.append({'username':username,'password':password,**r.json()})
        for account in accounts:
            r=c.post('/rest/v1/rpc/find_match',headers={'Authorization':'Bearer '+account['access_token']},json={});r.raise_for_status()
        session=r.json();assert session['state']=='running'
        db=sqlite3.connect(tmp/'db.sqlite3');state=json.loads(db.execute('select data from checkpoint').fetchone()[0]);db.close()
        info={'accounts':accounts,'session':session['id'],'code':session['code'],'answer':state['sessions'][session['id']]['words'][0]['modern']}
        (tmp/'info.json').write_text(json.dumps(info));os.chmod(tmp/'info.json',0o600)
        for i in range(2):
            out=open(tmp/f'godot-{i}.log','w')
            process=subprocess.Popen(['godot','--headless','--path','game','res://scripts/tests/selfhost_live.tscn','--',f'--player={i}',f'--profile=selfhost-live-{secrets.token_hex(4)}'],cwd=ROOT,env=env,stdout=out,stderr=out)
            clients.append((process,out))
        # Restart the actual server after the first deposit. Clients keep
        # running and reconnect to the same local address/database.
        time.sleep(8)
        server.terminate();server.wait(timeout=5)
        server=subprocess.Popen([sys.executable,'-m','uvicorn','server.app:create_app','--factory','--host','127.0.0.1','--port',str(port),'--no-access-log'],cwd=ROOT,env=env,stdout=log,stderr=log)
        for process,out in clients:
            assert process.wait(timeout=45)==0, 'Godot client failed'
            out.flush()
        rows=[json.loads((tmp/f'client-{i}.json').read_text()) for i in range(2)]
        assert rows[0]['seed']==rows[1]['seed']
        for i,row in enumerate(rows):
            assert row['results'] and row['movement_received'] and row['words']==10
            assert row['deposited_blue']==10 and row['deposited_red']==0
            assert 'SCRIPT ERROR' not in (tmp/f'godot-{i}.log').read_text()
        print('PASS: two Godot clients, identical seed, movement, server restart/reconnect, 10–0 finish and final spellings.')
        print(json.dumps(rows,indent=2))
    except Exception:
        log.flush()
        print((tmp/'server.log').read_text())
        for i in range(2):
            p=tmp/f'godot-{i}.log'
            if p.exists():print(p.read_text())
        raise
    finally:
        for process,out in clients:
            if process.poll() is None:process.terminate();process.wait(timeout=5)
            out.close()
        server.terminate();server.wait(timeout=5);log.close()

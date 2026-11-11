"""Offline configuration and consistent SQLite backup; no public admin API."""
import argparse
import json
from pathlib import Path
import sqlite3
from server.app import Store

p=argparse.ArgumentParser()
p.add_argument('--db',default='server/data/lakbayin.sqlite3')
sub=p.add_subparsers(dest='command',required=True)
c=sub.add_parser('config')
c.add_argument('--team-size',type=int,choices=range(1,6))
c.add_argument('--duration',type=int)
c.add_argument('--hints',choices=['on','off'],help="letters under the keys in Find Match")
m=sub.add_parser('admin',help="mark an account for the in-game control panel");m.add_argument('username');m.add_argument('--off',action='store_true')
b=sub.add_parser('backup');b.add_argument('destination')
a=p.parse_args()
store=Store(a.db)
if a.command=='config':
    # Use BEGIN IMMEDIATE and read inside the transaction so a running
    # server cannot overwrite this change with an older checkpoint.
    store.db.execute('begin immediate')
    state=store.load()
    if a.team_size is not None: state['config']['team_size']=a.team_size
    if a.duration is not None:
        if not 60<=a.duration<=7200: p.error('duration must be 60–7200 seconds')
        state['config']['duration_s']=a.duration
    if a.hints is not None: state['config']['hints']=a.hints=='on'
    store.save(state)
    print(json.dumps(state['config'],indent=2))
elif a.command=='admin':
    done=store.db.execute('update users set admin=? where username=? collate nocase',(0 if a.off else 1,a.username)).rowcount
    store.db.commit()
    if not done: p.error('no account named '+a.username)
    print(a.username,'is no longer an admin.' if a.off else 'is an admin.')
else:
    import os
    dest=Path(a.destination)
    if dest.exists(): p.error('destination already exists')
    dest.parent.mkdir(parents=True,exist_ok=True)
    fd=os.open(dest,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd)
    target=sqlite3.connect(dest)
    store.db.backup(target)
    target.close()
    print('Backup saved.')
store.db.close()

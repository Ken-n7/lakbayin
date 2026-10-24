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
    store.save(state)
    print(json.dumps(state['config'],indent=2))
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

import json
from pathlib import Path
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient
from server.app import create_app, TOPIC


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'game.sqlite3'
        self.app = create_app(self.path)
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.users = []
        for name in ('alpha', 'bravo', 'charlie', 'delta'):
            r = self.client.post('/auth/register', json={'username': name, 'password': 'testing-password'})
            self.assertEqual(r.status_code, 200, r.text)
            self.users.append(r.json())

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.tmp.cleanup()

    def request(self, n, method, path, body=None):
        return self.client.request(method, path, headers={'Authorization': 'Bearer ' + self.users[n]['access_token']}, json=body)

    def rpc(self, n, name, **kw):
        return self.request(n, 'POST', '/rest/v1/rpc/' + name, kw)

    def room(self):
        s = self.rpc(0, 'create_room').json()
        sid = s['id']
        state = self.app.state.store.load()
        teams = state['sessions'][sid]['teams']
        for n in (1, 2):
            r = self.request(n, 'POST', '/rest/v1/members', {'session_id': sid, 'profile_id': self.users[n]['user']['id']})
            self.assertEqual(r.status_code, 200, r.text)
            r = self.request(n, 'PATCH', f'/rest/v1/members?session_id=eq.{sid}&profile_id=eq.{self.users[n]["user"]["id"]}', {'team_id': teams[n % 2]['id']})
            self.assertEqual(r.status_code, 200)
        return s

    def join_ws(self, ws, n, topic=TOPIC, changes=None):
        ws.send_json({'topic': topic, 'event': 'phx_join', 'ref': '1', 'payload': {'access_token': self.users[n]['access_token'], 'config': {'postgres_changes': changes or []}}})
        reply = ws.receive_json()
        self.assertEqual(reply['payload']['status'], 'ok')
        if topic == TOPIC:
            self.assertEqual(ws.receive_json()['event'], 'system')
            self.assertEqual(ws.receive_json()['event'], 'presence_state')

    def test_auth_and_revocation(self):
        self.assertEqual(self.client.post('/auth/login', json={'username': 'ALPHA', 'password': 'testing-password'}).status_code, 200)
        self.assertEqual(self.client.post('/auth/register', json={'username': 'ALPHA', 'password': 'testing-password'}).status_code, 409)
        for name in ('alpha', 'nobody'):
            r = self.client.post('/auth/login', json={'username': name, 'password': 'incorrect'})
            self.assertEqual((r.status_code, r.json()['message']), (401, 'Invalid login credentials'))
        self.assertEqual(self.client.post('/auth/register', json={'username': 'bad email@', 'password': 'short'}).status_code, 400)
        db = self.app.state.store.db
        self.assertTrue(db.execute('select password from users').fetchone()[0].startswith('$argon2id$'))
        self.assertNotIn(self.users[0]['access_token'], [r[0] for r in db.execute('select hash from tokens')])
        self.assertEqual(self.client.get('/rest/v1/match_config').status_code, 401)
        self.assertEqual(self.request(0, 'POST', '/auth/logout', {}).status_code, 200)
        self.assertEqual(self.request(0, 'GET', '/rest/v1/match_config').status_code, 401)
        self.assertEqual(self.client.post('/auth/restore', json={'refresh_token': self.users[0]['refresh_token']}).status_code, 401)
        self.assertEqual(self.client.post('/auth/v1/recover', json={}).status_code, 404)

    def test_matchmaking_size_and_rejoin(self):
        db = self.app.state.store
        state = db.load(); state['config']['team_size'] = 3; db.save(state)
        s = self.rpc(0, 'find_match').json()
        t = self.rpc(1, 'find_match').json()
        self.assertEqual(s['id'], t['id'])
        self.assertEqual(t['state'], 'lobby')
        self.assertEqual(self.rpc(0, 'find_match').json()['id'], s['id'])
        poll = self.rpc(1, 'poll_match', p_session=s['id']).json()
        self.assertEqual((poll['players'], poll['needed']), (2, 6))
        self.assertEqual(self.rpc(0, 'start_room', p_session=s['id']).status_code, 403)
        self.rpc(0, 'leave_match', p_session=s['id']); self.rpc(1, 'leave_match', p_session=s['id'])
        state=db.load(); state['config']['team_size']=1; db.save(state)
        a=self.rpc(0,'find_match').json(); b=self.rpc(1,'find_match').json()
        self.assertEqual((a['id'], b['state'], b['duration_s']), (b['id'], 'running', 900))

    def test_authoritative_score_and_restart(self):
        s = self.room(); sid=s['id']
        self.assertEqual(self.rpc(1,'start_room',p_session=sid).status_code,403)
        self.assertEqual(self.rpc(0,'start_room',p_session=sid).status_code,200)
        words=self.request(0,'GET',f'/rest/v1/session_words?session_id=eq.{sid}').json()
        self.assertNotIn('modern',words[0]['words'])
        self.assertEqual(self.request(3,'GET',f'/rest/v1/monk_answers?session_id=eq.{sid}').status_code,403)
        self.assertEqual(self.rpc(3,'answer_monk',p_session=sid,p_monk=0,p_typed='bad').status_code,403)
        self.assertEqual(self.rpc(0,'answer_monk',p_session=sid,p_monk=-1,p_typed='bad').status_code,400)
        self.assertEqual(self.rpc(0,'answer_monk',p_session=sid,p_monk=0,p_typed='bad').json(),'wrong')
        state=self.app.state.store.load(); word=state['sessions'][sid]['words'][0]
        self.assertEqual(self.rpc(0,'answer_monk',p_session=sid,p_monk=0,p_typed=word['modern']).json(),'locked')
        self.assertEqual(self.rpc(2,'answer_monk',p_session=sid,p_monk=0,p_typed=word['traditional']).json(),'correct')
        self.assertEqual(self.rpc(0,'answer_monk',p_session=sid,p_monk=0,p_typed=word['modern']).json(),'taken')
        self.assertEqual(self.rpc(0,'deposit',p_session=sid).json(),0)
        self.assertEqual(self.rpc(2,'deposit',p_session=sid).json(),1)
        self.assertEqual(self.rpc(2,'deposit',p_session=sid).json(),0)
        # A separate process can reopen accounts and the match checkpoint.
        reopened=create_app(self.path)
        with TestClient(reopened) as client:
            restored=client.post('/auth/restore',json={'refresh_token':self.users[2]['refresh_token']})
            self.assertEqual(restored.status_code,200)
            state=reopened.state.store.load()
            self.assertIsNotNone(state['sessions'][sid]['answers'][0]['deposited_at'])
        for i,w in enumerate(state['sessions'][sid]['words'][1:],1):
            self.assertEqual(self.rpc(2,'answer_monk',p_session=sid,p_monk=i,p_typed=w['modern'].replace('᜔','᜕')).json(),'correct')
        self.assertEqual(self.rpc(2,'deposit',p_session=sid).json(),9)
        result=self.request(0,'GET',f'/rest/v1/sessions?id=eq.{sid}').json()[0]
        self.assertEqual(result['state'],'ended')
        self.assertIsNotNone(result['winner_team'])
        self.assertIn('modern',self.request(0,'GET',f'/rest/v1/session_words?session_id=eq.{sid}').json()[0]['words'])
        self.assertEqual(self.rpc(2,'my_matches').json()[0]['deposited'],10)
        self.assertEqual(self.rpc(2,'player_board').json(),[])

    def test_room_permissions_cleanup_watch(self):
        s=self.room(); sid=s['id']
        self.assertEqual(self.rpc(0,'watch_match',p_code=s['code']).status_code,403)
        self.assertEqual(self.rpc(3,'watch_match',p_code=s['code']).json(),sid)
        snap=self.rpc(3,'watch_snapshot',p_session=sid).json()
        self.assertEqual(len(snap['players']),3)
        self.assertNotIn('words',snap['session'])
        self.assertEqual(self.rpc(3,'deposit',p_session=sid).status_code,403)
        self.assertEqual(self.request(1,'PATCH',f'/rest/v1/members?session_id=eq.{sid}&profile_id=eq.{self.users[0]["user"]["id"]}',{'team_id':snap['teams'][1]['id']}).status_code,403)
        self.assertEqual(self.request(0,'PATCH',f'/rest/v1/sessions?id=eq.{sid}',{'state':'ended'}).status_code,403)
        self.assertEqual(self.rpc(1,'shuffle_room',p_session=sid).status_code,403)
        self.assertEqual(self.rpc(0,'shuffle_room',p_session=sid).status_code,200)
        db=self.app.state.store; state=db.load(); state['sessions'][sid]['members'][self.users[0]['user']['id']]['seen']=time.time()-40; db.save(state)
        poll=self.rpc(1,'poll_room',p_session=sid).json()
        self.assertEqual(poll['session']['owner_id'],self.users[1]['user']['id'])
        self.assertFalse(self.rpc(0,'poll_room',p_session=sid).json()['member'])

    def test_websocket_movement_isolation_and_spoof(self):
        s=self.room(); sid=s['id']; self.rpc(0,'start_room',p_session=sid)
        self.rpc(3,'watch_match',p_code=s['code'])
        topic=TOPIC+':snap:'+sid
        with self.client.websocket_connect('/realtime/v1/websocket') as one, self.client.websocket_connect('/realtime/v1/websocket') as two:
            self.join_ws(one,0,topic); self.join_ws(two,3,topic)
            data={'sid':sid,'p':[{'id':self.users[0]['user']['id'],'hero':1,'cadence':0.05,'p':[[1,100,200],[1.05,101,200]]}]}
            one.send_json({'topic':topic,'event':'broadcast','payload':{'event':'snap','payload':data}})
            self.assertEqual(two.receive_json()['payload']['payload'],data)
            # A viewer is disconnected if they attempt to publish.
            two.send_json({'topic':topic,'event':'broadcast','payload':{'event':'snap','payload':data}})
            self.assertEqual(two.receive()['type'],'websocket.close')
            # A player cannot impersonate their teammate in a path packet.
            data['p'][0]['id']=self.users[1]['user']['id']
            one.send_json({'topic':topic,'event':'broadcast','payload':{'event':'snap','payload':data}})
            self.assertEqual(one.receive()['type'],'websocket.close')

    def test_websocket_score_events(self):
        s=self.room(); sid=s['id']; self.rpc(0,'start_room',p_session=sid)
        with self.client.websocket_connect('/realtime/v1/websocket') as ws:
            self.join_ws(ws,0,changes=[{'table':'monk_answers','filter':'session_id=eq.'+sid}])
            w=self.app.state.store.load()['sessions'][sid]['words'][0]
            self.rpc(2,'answer_monk',p_session=sid,p_monk=0,p_typed=w['modern'])
            event=ws.receive_json()
            self.assertEqual(event['event'],'postgres_changes')
            self.assertEqual(event['payload']['data']['record']['profile_id'],self.users[2]['user']['id'])

    def test_concurrent_answer_and_timeout(self):
        s=self.room(); sid=s['id']; self.rpc(0,'start_room',p_session=sid)
        word=self.app.state.store.load()['sessions'][sid]['words'][0]
        with ThreadPoolExecutor(2) as pool:
            results=list(pool.map(lambda n:self.rpc(n,'answer_monk',p_session=sid,p_monk=0,p_typed=word['modern']).json(),[0,2]))
        self.assertEqual(sorted(results),['correct','taken'])
        for n in (0,2): self.rpc(n,'deposit',p_session=sid)
        state=self.app.state.store.load(); state['sessions'][sid]['deadline']=time.time()-1; self.app.state.store.save(state)
        ended=self.request(0,'GET',f'/rest/v1/sessions?id=eq.{sid}').json()[0]
        self.assertEqual(ended['state'],'ended')
        self.assertIsNotNone(ended['winner_team'])
        self.assertEqual(self.rpc(1,'deposit',p_session=sid).status_code,403)

    def test_ranked_records_and_queue_expiry(self):
        s=self.rpc(0,'find_match').json(); sid=s['id']
        state=self.app.state.store.load()
        state['sessions'][sid]['members'][self.users[0]['user']['id']]['joined']=time.time()-91
        self.app.state.store.save(state)
        self.assertFalse(self.rpc(0,'poll_match',p_session=sid).json()['queued'])
        a=self.rpc(0,'find_match').json(); b=self.rpc(1,'find_match').json(); sid=b['id']
        words=self.app.state.store.load()['sessions'][sid]['words']
        for i,w in enumerate(words):
            self.assertEqual(self.rpc(0,'answer_monk',p_session=sid,p_monk=i,p_typed=w['modern']).json(),'correct')
        self.rpc(0,'deposit',p_session=sid)
        board=self.rpc(0,'player_board').json()
        self.assertEqual((board[0]['wins'],board[0]['deposited'],board[0]['played']),(1,10,1))
        self.assertEqual(self.rpc(1,'my_matches').json()[0]['result'],'loss')
        self.assertEqual(self.rpc(3,'my_matches').json(),[])

    def test_six_player_queue_starts_only_when_full(self):
        for name in ('echo','foxtrot'):
            response=self.client.post('/auth/register',json={'username':name,'password':'testing-password'})
            self.assertEqual(response.status_code,200)
            self.users.append(response.json())
        state=self.app.state.store.load();state['config']['team_size']=3;self.app.state.store.save(state)
        ids=[]
        for index in range(6):
            response=self.rpc(index,'find_match');self.assertEqual(response.status_code,200)
            session=response.json();ids.append(session['id'])
            self.assertEqual(session['state'],'running' if index==5 else 'lobby')
        self.assertEqual(len(set(ids)),1)
        session=self.app.state.store.load()['sessions'][ids[0]]
        self.assertEqual([sum(m['team_id']==t['id'] for m in session['members'].values()) for t in session['teams']],[3,3])

    def test_malformed_and_limited_auth(self):
        self.assertEqual(self.client.post('/auth/login',content='bad',headers={'Content-Type':'application/json'}).status_code,400)
        self.assertEqual(self.client.post('/auth/login',json=['bad']).status_code,400)
        self.assertEqual(self.client.post('/auth/restore',json={'refresh_token':[]}).status_code,401)
        self.assertEqual(self.client.post('/auth/login',json={'username':'alpha','password':'x'*17000}).status_code,413)
        for i in range(16):
            self.client.post('/auth/login',json={'username':'nobody','password':'wrong'})
        self.assertEqual(self.client.post('/auth/login',json={'username':'nobody','password':'wrong'}).status_code,429)

    def test_private_channel_denies_outsider(self):
        from starlette.websockets import WebSocketDisconnect
        s=self.room();sid=s['id']
        with self.client.websocket_connect('/realtime/v1/websocket') as ws:
            ws.send_json({'topic':TOPIC+':snap:'+sid,'event':'phx_join','payload':{'access_token':self.users[3]['access_token']}})
            self.assertEqual(ws.receive()['type'],'websocket.close')


if __name__ == '__main__': unittest.main()

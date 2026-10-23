-- Event spectators are read-only outsiders, never players.
create temp table results (n serial, ok boolean, name text, detail text);
create function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$ insert into results(ok,name,detail) values(coalesce(ok,false),name,detail) $$;
create function pg_temp.uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
-- Runs `stmt` as a signed-in player and returns its one text value, or the error.
create function pg_temp.as_player(who uuid, stmt text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  perform set_config('role', 'authenticated', true);
  execute stmt into v;
  perform set_config('role', 'postgres', true);
  return coalesce(v, '');
exception when others then
  perform set_config('role', 'postgres', true);
  return 'ERROR: ' || sqlerrm;
end $$;

insert into auth.users(id,email,raw_user_meta_data)
select pg_temp.uid(n), 'watch'||n||'@t.dev', ('{"username":"watch'||n||'"}')::jsonb
  from generate_series(1, 4) n;
update public.match_config set monk_count=3;
do $$
declare s uuid; blue uuid; red uuid; code text; got text; snap jsonb; topic text;
begin
  s := pg_temp.as_player(pg_temp.uid(1),'select (public.create_room()).id::text')::uuid;
  select id into blue from public.teams where session_id=s and name='Blue';
  select id into red from public.teams where session_id=s and name='Red';
  select sessions.code into code from public.sessions where id=s;
  perform pg_temp.as_player(pg_temp.uid(2),format('insert into public.members(session_id,profile_id,team_id) values(%L,%L,%L) returning 1',s,pg_temp.uid(2),red));
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.watch_snapshot(%L)',s));
  perform pg_temp.check(got like 'ERROR%watch expired%', 'an unregistered spectator cannot read the event snapshot',got);
  got := pg_temp.as_player(pg_temp.uid(1),format('select public.watch_match(%L)',code));
  perform pg_temp.check(got like 'ERROR%players cannot watch%', 'a participant cannot watch their own match',got);
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.watch_match(%L)',lower(code)));
  perform pg_temp.check(got=s::text, 'a signed-in outsider watches by code',got);
  perform pg_temp.check((select count(*)=2 from public.members where session_id=s), 'watching does not add a player or affect team sizes');
  snap := pg_temp.as_player(pg_temp.uid(3),format('select public.watch_snapshot(%L)',s))::jsonb;
  perform pg_temp.check(snap->'session'->>'state'='lobby' and (snap->>'monks')::int=3, 'watching a lobby waits for the actual start');
  perform pg_temp.check(not (snap->'session' ? 'question_bank') and not (snap::text like '%@t.dev%'), 'snapshot contains no emails or legacy answer bank');
  topic := 'numxventure:snap:'||s;
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.can_use_movement(%L,false)',topic));
  perform pg_temp.check(got='true', 'registered spectators can receive movement',got);
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.can_use_movement(%L,true)',topic));
  perform pg_temp.check(got='false', 'spectators cannot publish movement',got);
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.can_use_movement(%L,true)','numxventure:in:'||s||':'||pg_temp.uid(3)));
  perform pg_temp.check(got='false', 'spectators cannot publish player input',got);
  perform pg_temp.as_player(pg_temp.uid(1),format('select public.start_room(%L)',s));
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.answer_monk(%L,0,%L)',s,'bad'));
  perform pg_temp.check(got like 'ERROR%not in this match%', 'spectators cannot answer monks',got);
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.deposit(%L)',s));
  perform pg_temp.check(got like 'ERROR%not in this match%', 'spectators cannot deposit',got);
  insert into public.monk_answers(session_id,team_id,monk,profile_id,deposited_at)
    values(s,blue,0,pg_temp.uid(1),null),(s,blue,1,pg_temp.uid(1),now()),(s,red,0,pg_temp.uid(2),null);
  snap := pg_temp.as_player(pg_temp.uid(3),format('select public.watch_snapshot(%L)',s))::jsonb;
  perform pg_temp.check(snap->'session'->>'id'=s::text and snap->'session'->>'state'='running', 'snapshot identifies the same seeded running match');
  perform pg_temp.check(snap->'teams'->0->>'carried'='1' and snap->'teams'->0->>'deposited'='1', 'team carried words stay separate from deposited scores');
  perform pg_temp.check(jsonb_array_length(snap->'players')=2 and jsonb_array_length(snap->'answers')=3, 'both rosters and independent per-team monk states are visible');
  perform pg_temp.check(snap->'players'->0->>'carried'='1' and snap->'players'->0->>'deposited'='1', 'individual carry and deposit counts are visible');
  got := pg_temp.as_player(pg_temp.uid(3),format('update public.match_watchers set seen_at=now() where session_id=%L',s));
  perform pg_temp.check(got like 'ERROR%permission denied%', 'spectators cannot forge or extend leases with table writes',got);
  got := pg_temp.as_player(pg_temp.uid(4),'select count(*) from public.match_watchers');
  perform pg_temp.check(got='0','RLS hides other spectators registrations',got);
  update public.match_watchers set seen_at=now()-interval '31 seconds' where session_id=s;
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.can_use_movement(%L,false)',topic));
  perform pg_temp.check(got='false','expired registrations fail movement authorization',got);
  got := pg_temp.as_player(pg_temp.uid(3),format('select public.watch_snapshot(%L)',s));
  perform pg_temp.check(got like 'ERROR%watch expired%', 'expired viewers must register again',got);
  perform pg_temp.as_player(pg_temp.uid(3),format('select public.watch_match(%L)',code));
  perform pg_temp.as_player(pg_temp.uid(3),format('select public.leave_watch(%L)',s));
  perform pg_temp.check(not exists(select 1 from public.match_watchers where session_id=s),'Leave clears the viewers registration');
  perform pg_temp.as_player(pg_temp.uid(3),format('select public.watch_match(%L)',code));
  update public.sessions set state='ended',winner_team=blue where id=s;
  snap := pg_temp.as_player(pg_temp.uid(3),format('select public.watch_snapshot(%L)',s))::jsonb;
  perform pg_temp.check(snap->'session'->>'winner_team'=blue::text,'existing spectators receive the final result');
  got := pg_temp.as_player(pg_temp.uid(4),format('select public.watch_match(%L)',code));
  perform pg_temp.check(got like 'ERROR%no live match%', 'new spectators cannot enter an ended match',got);
end $$;
select pg_temp.check(not has_function_privilege('anon','public.watch_match(text)','EXECUTE')
  and not has_function_privilege('anon','public.watch_snapshot(uuid)','EXECUTE'), 'watch APIs require authentication');
select pg_temp.check((select not prosecdef from pg_proc where oid='public.watch_snapshot(uuid)'::regprocedure)
  and (select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid='lakbayin_private.watch_snapshot(uuid)'::regprocedure),
  'watch API uses an invoker wrapper and private fixed-path implementation');
select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- WATCH SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;

-- Custom rooms (schema 4f): a host makes one, friends join by code and pick
-- sides, any number a side, the host starts it, and leaving hands it on.
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
select pg_temp.uid(n), 'p'||n||'@t.dev', ('{"username":"p'||n||'"}')::jsonb
  from generate_series(1, 8) n;
update public.match_config set team_size = 1, monk_count = 3;

do $$
declare s uuid; blue uuid; red uuid; got text; r uuid;
begin
  s := pg_temp.as_player(pg_temp.uid(1), 'select (public.create_room()).id::text')::uuid;
  select id into blue from public.teams where session_id = s and name = 'Blue';
  select id into red from public.teams where session_id = s and name = 'Red';
  perform pg_temp.check((select custom and not matchmade and state = 'lobby'
                                and admin_id = pg_temp.uid(1) and length(code) = 4
                           from public.sessions where id = s),
    'create_room: a custom lobby with a code, hosted by its maker');
  perform pg_temp.check((select duration_s=900 from public.sessions where id=s),
    'new custom rooms use a fifteen-minute clock');
  perform pg_temp.check(blue is not null and red is not null
    and (select team_id = blue from public.members where session_id = s and profile_id = pg_temp.uid(1)),
    'it has Blue and Red, the host on Blue');

  got := pg_temp.as_player(pg_temp.uid(1), format('select public.start_room(%L)::text', s));
  perform pg_temp.check(got like 'ERROR%both sides%', 'one side empty: it cannot start', got);

  got := pg_temp.as_player(pg_temp.uid(8), 'select (public.find_match()).id::text');
  perform pg_temp.check(got <> s::text, 'Find Match never lands in a room', got);

  got := pg_temp.as_player(pg_temp.uid(2), format(
    'insert into public.members (session_id, profile_id) values (%L, %L) returning profile_id::text', s, pg_temp.uid(2)));
  perform pg_temp.check(got = pg_temp.uid(2)::text, 'a friend joins by the code, on no side yet', got);
  got := pg_temp.as_player(pg_temp.uid(1), format('select public.start_room(%L)::text', s));
  perform pg_temp.check(got like 'ERROR%pick a side%', 'somebody on no side: it cannot start', got);
  perform pg_temp.as_player(pg_temp.uid(2), format(
    'update public.members set team_id = %L where session_id = %L and profile_id = %L returning 1', blue, s, pg_temp.uid(2)));
  got := pg_temp.as_player(pg_temp.uid(2), format(
    'update public.members set team_id = %L where session_id = %L and profile_id = %L returning team_id::text', red, s, pg_temp.uid(2)));
  perform pg_temp.check(got = red::text, 'and picks a side, and switches it', got);
  got := pg_temp.as_player(pg_temp.uid(3), format(
    'insert into public.members (session_id, team_id, profile_id) values (%L, %L, %L) returning 1', s, red, pg_temp.uid(3)));
  perform pg_temp.check(got = '1', 'sides can be uneven: 1 v 2', got);

  got := pg_temp.as_player(pg_temp.uid(2), format('select public.start_room(%L)::text', s));
  perform pg_temp.check(got like 'ERROR%only the host%', 'only the host starts it', got);
  got := pg_temp.as_player(pg_temp.uid(1), format('select (public.start_room(%L)).state', s));
  perform pg_temp.check(got = 'running', 'the host starts it', got);
  perform pg_temp.check((select count(*) = 3 from public.session_words where session_id = s),
    'Start draws the words');
  perform pg_temp.check(pg_temp.as_player(pg_temp.uid(2), format(
      'select public.can_use_movement(%L, true)::text', 'numxventure:snap:' || s)) = 'true'
    and pg_temp.as_player(pg_temp.uid(5), format(
      'select public.can_use_movement(%L, true)::text', 'numxventure:snap:' || s)) = 'false',
    'members send their positions on the snapshot channel; others cannot');

  got := pg_temp.as_player(pg_temp.uid(2), format(
    'update public.members set team_id = %L where session_id = %L and profile_id = %L returning 1', blue, s, pg_temp.uid(2)));
  perform pg_temp.check(got like 'ERROR%locked%', 'sides lock at Start', got);
  got := pg_temp.as_player(pg_temp.uid(4), format(
    'insert into public.members (session_id, team_id, profile_id) values (%L, %L, %L) returning 1', s, blue, pg_temp.uid(4)));
  perform pg_temp.check(got like 'ERROR%already started%', 'nobody joins after Start', got);
  perform pg_temp.as_player(pg_temp.uid(3), format('select public.leave_room(%L)::text', s));
  perform pg_temp.check((select count(*) = 3 from public.members where session_id = s),
    'leaving after Start keeps the row: the result counts');

  perform pg_temp.check((select ends_at between now()+interval '899 seconds' and now()+interval '901 seconds'
    from public.sessions where id=s), 'Start sets a fifteen-minute server deadline');

  -- Leaving a lobby: the host hands it on; the last one out closes it.
  r := pg_temp.as_player(pg_temp.uid(5), 'select (public.create_room()).id::text')::uuid;
  perform pg_temp.as_player(pg_temp.uid(6), format(
    'insert into public.members (session_id, profile_id) values (%L, %L) returning 1', r, pg_temp.uid(6)));
  perform pg_temp.as_player(pg_temp.uid(5), format('select public.leave_room(%L)::text', r));
  perform pg_temp.check((select admin_id = pg_temp.uid(6) and state = 'lobby' from public.sessions where id = r)
    and not exists (select 1 from public.members where session_id = r and profile_id = pg_temp.uid(5)),
    'the host leaves: out of the room, and the next player hosts');
  perform pg_temp.as_player(pg_temp.uid(6), format('select public.leave_room(%L)::text', r));
  perform pg_temp.check((select state = 'ended' from public.sessions where id = r),
    'the last one out closes the room');
end $$;

do $$
declare s uuid; other uuid; blue uuid; red uuid; foreign_team uuid; got text; data jsonb; before_seen timestamptz;
begin
  s := pg_temp.as_player(pg_temp.uid(1), 'select (public.create_room()).id::text')::uuid;
  select id into blue from public.teams where session_id = s and name = 'Blue';
  select id into red from public.teams where session_id = s and name = 'Red';
  insert into public.members(session_id,profile_id,team_id) values
    (s,pg_temp.uid(2),blue),(s,pg_temp.uid(3),blue),(s,pg_temp.uid(4),null);
  select updated_at into before_seen from public.members where session_id=s and profile_id=pg_temp.uid(2);
  got := pg_temp.as_player(pg_temp.uid(1),format('select public.move_room_member(%L,%L,%L)',s,pg_temp.uid(2),red));
  perform pg_temp.check(got='' and (select team_id=red and updated_at=before_seen from public.members where session_id=s and profile_id=pg_temp.uid(2)),
    'host moves a member without fabricating their heartbeat',got);
  got := pg_temp.as_player(pg_temp.uid(2),format('select public.move_room_member(%L,%L,%L)',s,pg_temp.uid(3),red));
  perform pg_temp.check(got like 'ERROR%only the host%', 'a member cannot move another player',got);
  got := pg_temp.as_player(pg_temp.uid(5),format('select public.move_room_member(%L,%L,%L)',s,pg_temp.uid(3),red));
  perform pg_temp.check(got like 'ERROR%only the host%', 'an outsider cannot move players',got);
  other := pg_temp.as_player(pg_temp.uid(7),'select (public.create_room()).id::text')::uuid;
  select id into foreign_team from public.teams where session_id=other limit 1;
  got := pg_temp.as_player(pg_temp.uid(1),format('select public.move_room_member(%L,%L,%L)',s,pg_temp.uid(2),foreign_team));
  perform pg_temp.check(got like 'ERROR%not in this room%', 'a host cannot move players across rooms',got);
  got := pg_temp.as_player(pg_temp.uid(1),format('select public.move_room_member(%L,%L,%L)',s,pg_temp.uid(8),red));
  perform pg_temp.check(got like 'ERROR%player is not in this room%', 'a host cannot recruit an outsider with Move',got);
  got := pg_temp.as_player(pg_temp.uid(2),format('select public.shuffle_room(%L)',s));
  perform pg_temp.check(got like 'ERROR%only the host%', 'a member cannot shuffle',got);
  got := pg_temp.as_player(pg_temp.uid(1),format('select public.shuffle_room(%L)',s));
  perform pg_temp.check(got='' and (select count(*)=2 from public.members where session_id=s and team_id=blue)
    and (select count(*)=2 from public.members where session_id=s and team_id=red),
    'host Shuffle balances sides, including unassigned players',got);
  update public.members set updated_at=clock_timestamp()-interval '31 seconds'
    where session_id=s and profile_id in (pg_temp.uid(1),pg_temp.uid(3));
  update public.members set updated_at=clock_timestamp()-interval '10 seconds' where session_id=s and profile_id=pg_temp.uid(2);
  data := pg_temp.as_player(pg_temp.uid(2),format('select public.poll_room(%L)',s))::jsonb;
  perform pg_temp.check((data->>'member')::boolean and jsonb_array_length(data->'roster')=2,
    'room poll removes silent phones and returns the authoritative roster',data::text);
  perform pg_temp.check((select updated_at > clock_timestamp()-interval '5 seconds' from public.members where session_id=s and profile_id=pg_temp.uid(2)),
    'poll refreshes the caller heartbeat');
  perform pg_temp.check((select admin_id=pg_temp.uid(2) from public.sessions where id=s),
    'a silent host is replaced by the oldest active member');
  data := pg_temp.as_player(pg_temp.uid(3),format('select public.poll_room(%L)',s))::jsonb;
  perform pg_temp.check(data='{"member":false}'::jsonb and not exists(select 1 from public.members where session_id=s and profile_id=pg_temp.uid(3)),
    'an expired member cannot resurrect its row by polling',data::text);
  data := pg_temp.as_player(pg_temp.uid(5),format('select public.poll_room(%L)',s))::jsonb;
  perform pg_temp.check(data='{"member":false}'::jsonb,'an outsider cannot poll the roster',data::text);
  got := pg_temp.as_player(pg_temp.uid(1),format('select public.shuffle_room(%L)',s));
  perform pg_temp.check(got like 'ERROR%only the host%', 'a removed host loses host powers',got);

  insert into public.members(session_id,profile_id,team_id)
    select other,pg_temp.uid(8),id from public.teams where session_id=other and name='Red';
  got := pg_temp.as_player(pg_temp.uid(7),format('select (public.start_room(%L)).state',other));
  perform pg_temp.check(got='running','control fixture starts normally',got);
  update public.members set updated_at=clock_timestamp()-interval '1 minute' where session_id=other and profile_id=pg_temp.uid(8);
  data := pg_temp.as_player(pg_temp.uid(7),format('select public.poll_room(%L)',other))::jsonb;
  perform pg_temp.check((select count(*)=2 from public.members where session_id=other),
    'room cleanup never deletes running match memberships');
  got := pg_temp.as_player(pg_temp.uid(7),format('select public.shuffle_room(%L)',other));
  perform pg_temp.check(got like 'ERROR%locked%', 'Shuffle locks at Start',got);
  got := pg_temp.as_player(pg_temp.uid(7),format('select public.move_room_member(%L,%L,%L)',other,pg_temp.uid(8),foreign_team));
  perform pg_temp.check(got like 'ERROR%locked%', 'Move locks at Start',got);
  perform pg_temp.check(not has_function_privilege('anon','public.poll_room(uuid)','EXECUTE')
    and not has_function_privilege('anon','public.move_room_member(uuid,uuid,uuid)','EXECUTE')
    and not has_function_privilege('anon','public.shuffle_room(uuid)','EXECUTE'),
    'room controls are not callable anonymously');
  perform pg_temp.check(not has_schema_privilege('authenticated','numxventure_private','USAGE'),
    'clients cannot invoke the private cleanup helper');
end $$;

select pg_temp.check((select not prosecdef from pg_proc where oid='public.move_room_member(uuid,uuid,uuid)'::regprocedure)
  and (select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid='lakbayin_private.move_room_member(uuid,uuid,uuid)'::regprocedure),
  'public room API is an invoker; privileged implementation has a fixed private search path');

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- ROOMS SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;

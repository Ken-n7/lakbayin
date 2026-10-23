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

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- ROOMS SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;

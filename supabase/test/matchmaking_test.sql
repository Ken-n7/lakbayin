-- The match finder (schema 4d): queues, fair teams, starting with no teacher,
-- dropping phones that went quiet, and the direct movement path.
create temp table results (n serial, ok boolean, name text, detail text);
create function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$ insert into results(ok,name,detail) values(coalesce(ok,false),name,detail) $$;
create function pg_temp.as_player(who uuid, stmt text) returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  perform set_config('role', 'authenticated', true);
  execute stmt;
  perform set_config('role', 'postgres', true);
  return '';
exception when others then
  perform set_config('role', 'postgres', true);
  return sqlerrm;
end $$;
create function pg_temp.uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.match_of(n int) returns uuid language sql as $$
  select m.session_id from public.members m join public.sessions s on s.id = m.session_id
   where m.profile_id = pg_temp.uid(n) and s.matchmade and not m.finished limit 1 $$;

insert into auth.users(id,email,raw_user_meta_data)
select pg_temp.uid(n), 'p'||n||'@t.dev',
       ('{"username":"p'||n||'"}')::jsonb
  from generate_series(1, 12) n;

create function pg_temp.poll_as(who uuid, sid uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  perform set_config('role', 'authenticated', true);
  v := public.poll_match(sid);
  perform set_config('role', 'postgres', true);
  return v;
end $$;

do $$
declare err text; s uuid; s2 uuid; t1 uuid; t2 uuid; row public.sessions; v jsonb;
begin
  perform pg_temp.check((select team_size = 3 from public.match_config),
    'the default remains 3 v 3');
  begin
    update public.match_config set team_size = 0;
    perform pg_temp.check(false, 'zero players a side is rejected');
  exception when check_violation then
    perform pg_temp.check(true, 'zero players a side is rejected');
  end;
  begin
    update public.match_config set team_size = 6;
    perform pg_temp.check(false, 'more than five players a side is rejected');
  exception when check_violation then
    perform pg_temp.check(true, 'more than five players a side is rejected');
  end;
  update public.match_config set team_size = 5;
  perform pg_temp.check((select team_size = 5 from public.match_config),
    'five players a side is still supported');

  -- Two phones can play a full match, with the same queue and fairness rules.
  update public.match_config set team_size = 1, search_s = 90, duration_s = 300;
  err := pg_temp.as_player(pg_temp.uid(1), 'select public.find_match()');
  s := pg_temp.match_of(1);
  v := pg_temp.poll_as(pg_temp.uid(1), s);
  perform pg_temp.check(err = '' and (v->>'queued')::boolean
    and (v->>'players')::int = 1 and (v->>'needed')::int = 2
    and v->'session'->>'state' = 'lobby',
    '1 v 1: the first phone waits for a second player', err || v::text);

  err := pg_temp.as_player(pg_temp.uid(12), 'select public.find_match()');
  select * into row from public.sessions where id = s;
  perform pg_temp.check(err = '' and pg_temp.match_of(12) = s and row.state = 'running'
    and row.ends_at between now() + interval '299 seconds' and now() + interval '301 seconds',
    '1 v 1: the second phone starts the match on the configured clock', err);
  perform pg_temp.check((select count(*) = 2 and count(distinct team_id) = 2
    from public.members where session_id = s),
    '1 v 1: each team has exactly one player');
  v := pg_temp.poll_as(pg_temp.uid(1), s);
  perform pg_temp.check((v->>'players')::int = 2 and (v->>'needed')::int = 2
    and v->'session'->>'state' = 'running',
    '1 v 1: both phones see a full running match', v::text);
  err := pg_temp.as_player(pg_temp.uid(10), 'select public.find_match()');
  s2 := pg_temp.match_of(10);
  perform pg_temp.check(err = '' and s2 <> s
    and (select state = 'lobby' from public.sessions where id = s2),
    '1 v 1: a third player waits in a separate lobby', err);

  -- Keep the existing 2 v 2 coverage independent of the playtest matches.
  update public.sessions set state = 'ended' where id in (s, s2);
  update public.match_config set team_size = 2, search_s = 90, duration_s = 300;

  err := pg_temp.as_player(pg_temp.uid(2), 'select public.find_match()');
  s := pg_temp.match_of(2);
  select * into row from public.sessions where id = s;
  perform pg_temp.check(err = '' and row.matchmade and row.state = 'lobby' and row.admin_id = pg_temp.uid(2)
    and (select count(*) from public.teams where session_id = s) = 2,
    'the first player opens a lobby with two teams, and owns it', err);

  err := pg_temp.as_player(pg_temp.uid(3), 'select public.find_match()');
  select team_id into t1 from public.members where session_id = s and profile_id = pg_temp.uid(2);
  select team_id into t2 from public.members where session_id = s and profile_id = pg_temp.uid(3);
  perform pg_temp.check(err = '' and pg_temp.match_of(3) = s and t1 <> t2,
    'the second player joins the same lobby, on the other team', err);

  err := pg_temp.as_player(pg_temp.uid(2), 'select public.find_match()');
  perform pg_temp.check(err = '' and (select count(*) from public.members where profile_id = pg_temp.uid(2)) = 1,
    'Find Match again returns the same lobby, not a second place', err);

  err := pg_temp.as_player(pg_temp.uid(2), format(
    'update public.members set team_id = %L where session_id = %L and profile_id = %L', t2, s, pg_temp.uid(2)));
  perform pg_temp.check((select team_id = t1 from public.members where session_id = s and profile_id = pg_temp.uid(2)),
    'a player cannot switch to the other team', err);
  err := pg_temp.as_player(pg_temp.uid(4), format(
    'insert into public.members(session_id, team_id, profile_id) values (%L, %L, %L)', s, t1, pg_temp.uid(4)));
  perform pg_temp.check(err <> '' and pg_temp.match_of(4) is null,
    'nobody joins a match by inserting themselves', err);

  v := pg_temp.poll_as(pg_temp.uid(2), s);
  perform pg_temp.check((v->>'queued')::boolean and (v->>'players')::int = 2 and (v->>'needed')::int = 4
    and (v->>'search_s')::int = 90 and v->'session'->>'state' = 'lobby',
    'a check-in reports the queue: 2 of 4, still waiting', v::text);

  err := pg_temp.as_player(pg_temp.uid(4), 'select public.find_match()');
  perform pg_temp.check(err = '' and pg_temp.match_of(4) = s and (select state = 'lobby' from public.sessions where id = s),
    'three of four: a match never starts short-handed', err);

  -- A quiet phone is dropped.
  update public.members set updated_at = now() - interval '1 minute' where session_id = s and profile_id = pg_temp.uid(4);
  v := pg_temp.poll_as(pg_temp.uid(2), s);
  perform pg_temp.check(pg_temp.match_of(4) is null and (v->>'players')::int = 2,
    'a phone that stopped checking in leaves the lobby', v::text);

  -- Waiting too long: out of the queue, told so, not an error.
  update public.members set queued_at = now() - interval '91 seconds' where session_id = s and profile_id = pg_temp.uid(3);
  v := pg_temp.poll_as(pg_temp.uid(3), s);
  perform pg_temp.check(not (v->>'queued')::boolean and pg_temp.match_of(3) is null,
    'after search_s a player drops out with "no match found"', v::text);

  -- Full: 2 v 2 starts at once.
  err := pg_temp.as_player(pg_temp.uid(5), 'select public.find_match()')
      || pg_temp.as_player(pg_temp.uid(6), 'select public.find_match()');
  perform pg_temp.check(err = '' and (select state = 'lobby' from public.sessions where id = s),
    'three of four again: waiting', err);
  err := pg_temp.as_player(pg_temp.uid(7), 'select public.find_match()');
  select * into row from public.sessions where id = s;
  perform pg_temp.check(err = '' and row.state = 'running'
    and row.ends_at between now() + interval '299 seconds' and now() + interval '301 seconds',
    'the fourth player fills the lobby: it starts at once, on the configured clock', err);
  perform pg_temp.check((select bool_and(k = 2) from (select count(*) k from public.members
      where session_id = s group by team_id) x), 'a full match is dealt 2 v 2');

  err := pg_temp.as_player(pg_temp.uid(2), 'select public.find_match()');
  perform pg_temp.check(err = '' and pg_temp.match_of(2) = s,
    'a player in a running match is sent back to it', err);
  err := pg_temp.as_player(pg_temp.uid(8), 'select public.find_match()');
  s2 := pg_temp.match_of(8);
  perform pg_temp.check(err = '' and s2 <> s,
    'a running match takes nobody new: the next player gets a new lobby', err);

  -- Raising the team size is one setting.
  update public.match_config set team_size = 3;
  v := pg_temp.poll_as(pg_temp.uid(8), s2);
  perform pg_temp.check((v->>'needed')::int = 6, 'team_size 3: a lobby needs six', v::text);
  update public.match_config set team_size = 2;

  -- Leaving the queue.
  err := pg_temp.as_player(pg_temp.uid(9), 'select public.find_match()')
      || pg_temp.as_player(pg_temp.uid(9), format('select public.leave_match(%L)', s2));
  perform pg_temp.check(err = '' and pg_temp.match_of(9) is null and pg_temp.match_of(8) = s2,
    'leaving takes only that player out of the queue', err);
  err := pg_temp.as_player(pg_temp.uid(5), format('select public.leave_match(%L)', s));
  perform pg_temp.check(pg_temp.match_of(5) = s,
    'after Start, leaving does not erase a result', err);

  -- Movement: no teacher, so members publish their own snapshots.
  perform set_config('request.jwt.claim.sub', pg_temp.uid(6)::text, true);
  perform pg_temp.check(public.can_use_movement('numxventure:snap:' || s, true),
    'a match member may publish on the snapshot channel');
  perform set_config('request.jwt.claim.sub', pg_temp.uid(11)::text, true);
  perform pg_temp.check(not public.can_use_movement('numxventure:snap:' || s, true)
    and not public.can_use_movement('numxventure:snap:' || s, false),
    'a non-member can neither publish nor read a match''s movement');

  -- Done with a match: the next Find Match is a new one.
  update public.members set finished = true where session_id = s and profile_id = pg_temp.uid(6);
  err := pg_temp.as_player(pg_temp.uid(6), 'select public.find_match()');
  perform pg_temp.check(err = '' and pg_temp.match_of(6) <> s,
    'a finished player is queued for a new match', err);
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- MATCHMAKING SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;

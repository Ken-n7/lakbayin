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
       case when n = 1 then '{"username":"house","role":"admin"}'
            else ('{"username":"p'||n||'"}')::jsonb end
  from generate_series(1, 12) n;
insert into public.questions(owner,station,prompt,answer)
select pg_temp.uid(1), case when n<=8 then 1 when n<=11 then 2 else 3 end, 'House '||n, '2'
  from generate_series(1,14) n;

do $$
declare err text; s uuid; s2 uuid; t1 uuid; t2 uuid; row public.sessions;
begin
  err := pg_temp.as_player(pg_temp.uid(2), 'select public.find_match()');
  perform pg_temp.check(err like '%not set up%', 'no house account: matchmaking refuses', err);
  update public.match_config set house = pg_temp.uid(1), team_size = 2, lobby_s = 30, duration_s = 300;

  err := pg_temp.as_player(pg_temp.uid(2), 'select public.find_match()');
  s := pg_temp.match_of(2);
  select * into row from public.sessions where id = s;
  perform pg_temp.check(err = '' and row.matchmade and row.state = 'lobby' and row.admin_id = pg_temp.uid(1)
    and (select count(*) from public.teams where session_id = s) = 2 and row.starts_at is null,
    'the first player opens a lobby with two teams and no countdown', err);

  err := pg_temp.as_player(pg_temp.uid(3), 'select public.find_match()');
  select team_id into t1 from public.members where session_id = s and profile_id = pg_temp.uid(2);
  select team_id into t2 from public.members where session_id = s and profile_id = pg_temp.uid(3);
  perform pg_temp.check(err = '' and pg_temp.match_of(3) = s and t1 <> t2,
    'the second player joins the same lobby, on the other team', err);
  perform pg_temp.check((select starts_at > now() from public.sessions where id = s),
    'a second player starts the countdown');

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

  err := pg_temp.as_player(pg_temp.uid(2), format('select public.poll_match(%L)', s));
  perform pg_temp.check(err = '' and (select state = 'lobby' from public.sessions where id = s),
    'a check-in before the countdown ends leaves the lobby waiting', err);

  -- 2v1: uneven teams wait even after the countdown.
  err := pg_temp.as_player(pg_temp.uid(4), 'select public.find_match()');
  update public.sessions set starts_at = now() - interval '1 second' where id = s;
  err := err || pg_temp.as_player(pg_temp.uid(3), format('select public.poll_match(%L)', s));
  perform pg_temp.check(err = '' and pg_temp.match_of(4) = s and (select state = 'lobby' from public.sessions where id = s),
    'the countdown over but the teams 2 v 1: still waiting', err);

  -- A quiet phone is dropped; then 1 v 1 and due: it starts.
  update public.members set updated_at = now() - interval '1 minute' where session_id = s and profile_id = pg_temp.uid(4);
  err := pg_temp.as_player(pg_temp.uid(2), format('select public.poll_match(%L)', s));
  select * into row from public.sessions where id = s;
  perform pg_temp.check(err = '' and pg_temp.match_of(4) is null,
    'a phone that stopped checking in leaves the lobby', err);
  perform pg_temp.check(row.state = 'running' and row.ends_at between now() + interval '299 seconds' and now() + interval '301 seconds',
    'even teams and the countdown over: the match starts with no teacher, on the configured clock');
  perform pg_temp.check(jsonb_array_length(row.question_bank) = 14,
    'the match plays the house account''s question bank');

  err := pg_temp.as_player(pg_temp.uid(2), 'select public.find_match()');
  perform pg_temp.check(err = '' and pg_temp.match_of(2) = s,
    'a player in a running match is sent back to it', err);
  err := pg_temp.as_player(pg_temp.uid(5), 'select public.find_match()');
  perform pg_temp.check(err = '' and pg_temp.match_of(5) <> s,
    'a running match takes nobody new: the next player gets a new lobby', err);

  -- Full: 2 v 2 starts at once, no countdown needed.
  s2 := pg_temp.match_of(5);
  err := pg_temp.as_player(pg_temp.uid(6), 'select public.find_match()')
      || pg_temp.as_player(pg_temp.uid(7), 'select public.find_match()');
  perform pg_temp.check(err = '' and (select state = 'lobby' from public.sessions where id = s2),
    'three of four: waiting', err);
  err := pg_temp.as_player(pg_temp.uid(8), 'select public.find_match()');
  perform pg_temp.check(err = '' and (select state = 'running' from public.sessions where id = s2),
    'the fourth player fills the lobby and the match starts at once', err);
  perform pg_temp.check((select bool_and(k = 2) from (select count(*) k from public.members
      where session_id = s2 group by team_id) x), 'a full match is dealt 2 v 2');

  -- Leaving the queue.
  err := pg_temp.as_player(pg_temp.uid(9), 'select public.find_match()')
      || pg_temp.as_player(pg_temp.uid(10), 'select public.find_match()');
  s := pg_temp.match_of(9);
  err := err || pg_temp.as_player(pg_temp.uid(10), format('select public.leave_match(%L)', s));
  perform pg_temp.check(err = '' and pg_temp.match_of(10) is null
    and (select starts_at is null from public.sessions where id = s),
    'leaving takes the player out and a lone player''s countdown stops', err);
  err := pg_temp.as_player(pg_temp.uid(5), format('select public.leave_match(%L)', s2));
  perform pg_temp.check(pg_temp.match_of(5) = s2,
    'after Start, leaving does not erase a result', err);

  -- Movement: no teacher, so members publish their own snapshots.
  perform set_config('request.jwt.claim.sub', pg_temp.uid(6)::text, true);
  perform pg_temp.check(public.can_use_movement('numxventure:snap:' || s2, true),
    'a match member may publish on the snapshot channel');
  perform set_config('request.jwt.claim.sub', pg_temp.uid(11)::text, true);
  perform pg_temp.check(not public.can_use_movement('numxventure:snap:' || s2, true)
    and not public.can_use_movement('numxventure:snap:' || s2, false),
    'a non-member can neither publish nor read a match''s movement');

  -- Done with a match: the next Find Match is a new one.
  update public.members set finished = true where session_id = s2 and profile_id = pg_temp.uid(6);
  err := pg_temp.as_player(pg_temp.uid(6), 'select public.find_match()');
  perform pg_temp.check(err = '' and pg_temp.match_of(6) <> s2,
    'a finished player is queued for a new match', err);
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- MATCHMAKING SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;

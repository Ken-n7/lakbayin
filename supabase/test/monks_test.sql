-- Monks and the Monastery (schema 4e): answering in Baybayin, both spellings,
-- lockouts, carrying, depositing, finishing, and the standings.
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
select pg_temp.uid(n), 'p'||n||'@t.dev',
       ('{"username":"p'||n||'"}')::jsonb
  from generate_series(1, 6) n;
update public.match_config set team_size = 2, monk_count = 3, duration_s = 300;

do $$
declare s uuid; t2 uuid; t3 uuid; w public.words; got text; i int;
begin
  for i in 2..5 loop perform pg_temp.as_player(pg_temp.uid(i), 'select (public.find_match()).id::text'); end loop;
  select m.session_id into s from public.members m where m.profile_id = pg_temp.uid(2);
  perform pg_temp.check((select state = 'running' from public.sessions where id = s), 'setup: a full 2 v 2 match is running');
  perform pg_temp.check((select count(*) = 3 from public.session_words where session_id = s),
    'Start draws monk_count words for the match');
  select team_id into t2 from public.members where session_id = s and profile_id = pg_temp.uid(2);
  -- A rival of player 2, and a teammate.
  select profile_id::text into got from public.members where session_id = s and team_id <> t2 limit 1;
  t3 := got::uuid;

  select wd.* into w from public.session_words sw join public.words wd on wd.id = sw.word_id
   where sw.session_id = s and sw.monk = 0;
  got := pg_temp.as_player(pg_temp.uid(2), format('select public.answer_monk(%L, 0, %L)', s, 'ᜀ'));
  perform pg_temp.check(got = 'wrong', 'a wrong spelling is wrong', got);
  got := pg_temp.as_player(pg_temp.uid(2), format('select public.answer_monk(%L, 0, %L)', s, w.modern));
  perform pg_temp.check(got = 'locked', 'and locks that player out of that monk, even with the right answer', got);
  update numxventure_private.monk_tries set wrong_at = now() - interval '11 seconds';
  got := pg_temp.as_player(pg_temp.uid(2), format('select public.answer_monk(%L, 0, %L)', s, w.modern));
  perform pg_temp.check(got = 'correct', 'after 10 s the modern spelling is correct', got);
  perform pg_temp.check((select deposited_at is null from public.monk_answers where session_id = s and monk = 0 and team_id = t2),
    'a correct answer is carried, not yet deposited');

  got := pg_temp.as_player(pg_temp.uid(2), format('select public.answer_monk(%L, 0, %L)', s, w.modern));
  perform pg_temp.check(got = 'taken', 'the same team cannot answer a monk twice', got);
  got := pg_temp.as_player(t3, format('select public.answer_monk(%L, 0, %L)', s, w.traditional));
  perform pg_temp.check(got = 'correct', 'the rival team answers the same monk, in the traditional spelling', got);

  select wd.* into w from public.session_words sw join public.words wd on wd.id = sw.word_id
   where sw.session_id = s and sw.monk = 1;
  got := pg_temp.as_player(pg_temp.uid(2), format('select public.answer_monk(%L, 1, %L)', s,
    replace(w.modern, U&'\1714', U&'\1715') || ' '));
  perform pg_temp.check(got = 'correct', 'the pamudpod and a stray space are accepted', got);

  got := pg_temp.as_player(pg_temp.uid(6), format('select public.answer_monk(%L, 1, %L)', s, w.modern));
  perform pg_temp.check(got like 'ERROR%not in this match%', 'a non-member cannot answer', got);

  got := pg_temp.as_player(pg_temp.uid(2), format('select public.deposit(%L)::text', s));
  perform pg_temp.check(got = '2', 'depositing banks everything carried', got);
  perform pg_temp.check((select deposited = 2 from public.team_standings where team_id = t2)
    and (select deposited = 2 from public.player_standings where session_id = s and profile_id = pg_temp.uid(2)),
    'the standings count the deposits for the team and the player');
  perform pg_temp.check((select state = 'running' from public.sessions where id = s), 'two of three: still running');

  -- The last word: a teammate answers it; carried, it does not finish the team.
  select profile_id::text into got from public.members
   where session_id = s and team_id = t2 and profile_id <> pg_temp.uid(2);
  select wd.* into w from public.session_words sw join public.words wd on wd.id = sw.word_id
   where sw.session_id = s and sw.monk = 2;
  perform pg_temp.check(pg_temp.as_player(got::uuid, format('select public.answer_monk(%L, 2, %L)', s, w.modern)) = 'correct',
    'a teammate answers the last monk');
  perform pg_temp.check((select state = 'running' from public.sessions where id = s),
    'every word answered but one still carried: not finished');
  perform pg_temp.as_player(got::uuid, format('select public.deposit(%L)::text', s));
  perform pg_temp.check((select state = 'ended' and winner_team = t2 from public.sessions where id = s),
    'the last deposit finishes the team: it wins and the match ends');
  perform pg_temp.check((select finished from public.team_standings where team_id = t2)
    and not (select finished from public.team_standings where session_id = s and team_id <> t2),
    'the standings mark the finished team');

  got := pg_temp.as_player(t3, format('select public.deposit(%L)::text', s));
  perform pg_temp.check(got like 'ERROR%not running%', 'after the end nothing more is deposited', got);
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- MONKS SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;

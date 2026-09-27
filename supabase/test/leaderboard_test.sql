-- The all-time board (public.team_results), on plain Postgres (see run.sh).
-- Four games: A ended, B out of time but still marked running, C running with
-- time left, D still in the lobby. Only A and B are finished.

create temp table results (n serial, ok boolean, name text, detail text);
create or replace function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$
  insert into results (ok, name, detail) values (coalesce(ok, false), name, detail)
$$;

insert into auth.users (id, email, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000000' || lpad(i::text, 2, '0'))::uuid,
       'p' || i || '@t.dev', jsonb_build_object('username', 'player' || i)
  from generate_series(1, 9) i;
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000aa', 'teacher@t.dev', '{"username":"teacher","role":"admin"}');

insert into public.sessions (id, admin_id, created_at) values
  ('a0000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000aa', now() - interval '3 days'),
  ('b0000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000aa', now() - interval '2 days'),
  ('c0000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000aa', now() - interval '1 day'),
  ('d0000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000aa', now());
insert into public.teams (id, session_id, name) values
  ('a1000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000000', 'Kidlat'),
  ('a2000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000000', 'Bagani'),
  ('a3000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000000', 'Nobody'),
  ('b1000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-000000000000', 'Alon'),
  ('b2000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-000000000000', 'Kidlat'),
  ('c1000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000000', 'Tala'),
  ('d1000000-0000-0000-0000-000000000000', 'd0000000-0000-0000-0000-000000000000', 'Sibol');
-- Members join while each game is still in the lobby.
insert into public.members (session_id, team_id, profile_id) values
  ('a0000000-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001'),
  ('a0000000-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000002'),
  ('a0000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000003'),
  ('b0000000-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000004'),
  ('b0000000-0000-0000-0000-000000000000', 'b2000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000005'),
  ('c0000000-0000-0000-0000-000000000000', 'c1000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000006'),
  ('d0000000-0000-0000-0000-000000000000', 'd1000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000007');

-- Game A played out: Kidlat 60 + 40, neither through all 14 items; Bagani out.
update public.sessions set state = 'running', ends_at = now() + interval '1 hour'
 where id = 'a0000000-0000-0000-0000-000000000000';
update public.members set gems = 60, items_done = 12 where profile_id = '00000000-0000-0000-0000-000000000001';
update public.members set gems = 40, items_done = 14 where profile_id = '00000000-0000-0000-0000-000000000002';
update public.members set gems = 0,  items_done = 6  where profile_id = '00000000-0000-0000-0000-000000000003';
update public.sessions set state = 'ended' where id = 'a0000000-0000-0000-0000-000000000000';
-- Game B: out of time, never marked ended. Alon finished everything.
update public.sessions set state = 'running', ends_at = now() - interval '5 minutes'
 where id = 'b0000000-0000-0000-0000-000000000000';
update public.members set gems = 90, items_done = 14 where profile_id = '00000000-0000-0000-0000-000000000004';
update public.members set gems = 55, items_done = 14 where profile_id = '00000000-0000-0000-0000-000000000005';
-- Game C: still being played.
update public.sessions set state = 'running', ends_at = now() + interval '1 hour'
 where id = 'c0000000-0000-0000-0000-000000000000';
update public.members set gems = 500 where profile_id = '00000000-0000-0000-0000-000000000006';

do $$
declare
  n int;
  names text;
  r record;
begin
  select count(*) into n from public.team_results;
  perform pg_temp.check(n = 4, 'finished games only: 2 teams from A, 2 from B', n::text);
  perform pg_temp.check(not exists (select 1 from public.team_results where name in ('Tala', 'Sibol')),
    'a game still running, or still in the lobby, is not on the board');
  perform pg_temp.check(not exists (select 1 from public.team_results where name = 'Nobody'),
    'a team nobody played for is left out');

  select string_agg(name || ':' || gems, ' ' order by gems desc) into names from public.team_results;
  -- Kidlat: 60 + 40, and -25 for the one of them short of 14 items. Bagani:
  -- 0, -50 for going out, -25 for not finishing.
  perform pg_temp.check(names = 'Alon:90 Kidlat:75 Kidlat:55 Bagani:-75',
    'best first, penalties in: Kidlat 60+40-25, Bagani 0-50-25', names);

  select * into r from public.team_results where team_id = 'a1000000-0000-0000-0000-000000000000';
  perform pg_temp.check(r.game_no = 1 and r.members = 2, 'game A is Game 1, 2 players', r.game_no || ' ' || r.members);
  select * into r from public.team_results where team_id = 'b1000000-0000-0000-0000-000000000000';
  perform pg_temp.check(r.game_no = 2, 'game B, out of time, is Game 2', r.game_no::text);
  perform pg_temp.check(r.player_ids = array['00000000-0000-0000-0000-000000000004'::uuid],
    'each team lists who played for it', r.player_ids::text);
  perform pg_temp.check((select count(distinct game_no) from public.team_results
      where name = 'Kidlat') = 2, 'the same team name in two games stays two entries');

  -- Game C runs out of time: it joins the board, as Game 3.
  update public.sessions set ends_at = now() - interval '1 second'
   where id = 'c0000000-0000-0000-0000-000000000000';
  select * into r from public.team_results where name = 'Tala';
  perform pg_temp.check(r.game_no = 3 and r.gems = 475, 'a game joins when it finishes, numbered next',
    coalesce(r.game_no::text, 'missing') || ' ' || coalesce(r.gems::text, ''));
end $$;

-- A signed-in player can read it (RLS on the tables under the view).
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000009', false);
set role authenticated;
select count(*) as seen from public.team_results \gset
reset role;
select pg_temp.check(:seen = 5, 'any signed-in player can read the board', :'seen');

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail <> '' then '   <' || detail || '>' else '' end
  from results order by n;
select format('---- LEADERBOARD SQL %s ---- %s checks, %s failures',
              case when bool_and(ok) then 'PASS' else 'FAIL' end, count(*), count(*) filter (where not ok))
  from results;

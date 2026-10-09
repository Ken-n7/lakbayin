-- Teachers never reach into each other's sessions (client, 2026-10-09; SPECS
-- §11 Q12), against the real schema on plain Postgres (see run.sh). Two
-- teachers, A and B, each with a class; every call is made as the
-- `authenticated` role with auth.uid() set, the way the app makes it.

create temp table results (n serial, ok boolean, name text, detail text);

create or replace function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$
  insert into results (ok, name, detail) values (coalesce(ok, false), name, detail)
$$;

-- `who` runs `query`; its first value as text ('' for none), or 'error: ...'.
create or replace function pg_temp.val(who uuid, query text)
returns text language plpgsql as $$
declare
  v text;
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  perform set_config('role', 'authenticated', true);
  execute query into v;
  perform set_config('role', 'postgres', true);
  return coalesce(v, '');
exception when others then
  perform set_config('role', 'postgres', true);
  return 'error: ' || sqlerrm;
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@t.dev', '{"username":"teacher_a","role":"admin"}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@t.dev', '{"username":"teacher_b","role":"admin"}'),
  ('00000000-0000-0000-0000-0000000000a1', 'p@t.dev', '{"username":"pia"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'q@t.dev', '{"username":"quin"}');
insert into public.sessions (id, admin_id, state) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-00000000000a', 'lobby'),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-00000000000b', 'lobby');
insert into public.teams (id, session_id, name) values
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'Red'),
  ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333', 'Blue');
insert into public.members (session_id, team_id, profile_id) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
   '00000000-0000-0000-0000-0000000000a1'),
  ('33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444',
   '00000000-0000-0000-0000-0000000000b1');
insert into public.questions (station, prompt, answer, active, owner) values
  (1, 'A on',  '1', true,  '00000000-0000-0000-0000-00000000000a'),
  (1, 'A off', '2', false, '00000000-0000-0000-0000-00000000000a'),
  (1, 'B on',  '3', true,  '00000000-0000-0000-0000-00000000000b');

do $$
declare
  a    constant uuid := '00000000-0000-0000-0000-00000000000a';
  b    constant uuid := '00000000-0000-0000-0000-00000000000b';
  pia  constant uuid := '00000000-0000-0000-0000-0000000000a1';
  sa   constant text := '''11111111-1111-1111-1111-111111111111''';
  ta   constant text := '''22222222-2222-2222-2222-222222222222''';
  code text := (select code from public.sessions where id = '11111111-1111-1111-1111-111111111111');
  got  text;
begin
  -- Teacher B, against A's class.
  got := pg_temp.val(b, 'select count(*) from public.sessions where id = ' || sa)
      || pg_temp.val(b, 'select count(*) from public.teams where session_id = ' || sa)
      || pg_temp.val(b, 'select count(*) from public.members where session_id = ' || sa);
  perform pg_temp.check(got = '000', 'B sees none of A''s session, teams or players', got);
  got := pg_temp.val(b, 'with u as (update public.sessions set state = ''ended'' where id = '
                        || sa || ' returning 1) select count(*) from u');
  perform pg_temp.check(got = '0' and (select state from public.sessions
    where id = '11111111-1111-1111-1111-111111111111') = 'lobby', 'B cannot end A''s session', got);
  got := pg_temp.val(b, 'with u as (update public.teams set name = ''Mine'' where session_id = '
                        || sa || ' returning 1) select count(*) from u')
      || pg_temp.val(b, 'with d as (delete from public.teams where session_id = '
                        || sa || ' returning 1) select count(*) from d');
  perform pg_temp.check(got = '00' and (select name from public.teams
    where id = '22222222-2222-2222-2222-222222222222') = 'Red', 'B cannot rename or delete A''s teams', got);
  got := pg_temp.val(b, 'with u as (update public.members set team_id = null where session_id = '
                        || sa || ' returning 1) select count(*) from u');
  perform pg_temp.check(got = '0' and (select team_id from public.members where profile_id = pia)
    is not null, 'B cannot move A''s players', got);
  got := pg_temp.val(b, 'insert into public.teams (session_id, name) values (' || sa || ', ''Spy'') returning 1');
  perform pg_temp.check(got like 'error:%row-level security%', 'B cannot add a team to A''s session', got);
  got := pg_temp.val(b, 'select public.shuffle_teams(' || sa || ')');
  perform pg_temp.check(got like 'error:%only the teacher%', 'B cannot shuffle A''s teams', got);
  got := pg_temp.val(b, 'insert into public.sessions (admin_id) values (''' || a || ''') returning 1');
  perform pg_temp.check(got like 'error:%row-level security%', 'B cannot make a session in A''s name', got);
  got := pg_temp.val(b, 'select count(*) from public.questions where owner = ''' || a || '''')
      || pg_temp.val(b, 'with u as (update public.questions set answer = ''9'' where owner = '''
                        || a || ''' returning 1) select count(*) from u');
  perform pg_temp.check(got = '00', 'B cannot read or change A''s questions', got);
  got := pg_temp.val(b, 'insert into public.questions (station, prompt, answer) values (2, ''B new'', ''4'') returning 1');
  perform pg_temp.check(got = '1' and (select owner from public.questions where prompt = 'B new') = b,
    'a question B writes is B''s own', got);

  -- Teacher A, in their own class.
  got := pg_temp.val(a, 'select count(*) from public.sessions where id = ' || sa)
      || pg_temp.val(a, 'select count(*) from public.teams where session_id = ' || sa)
      || pg_temp.val(a, 'select count(*) from public.members where session_id = ' || sa);
  perform pg_temp.check(got = '111', 'A sees their own session, teams and players', got);
  got := pg_temp.val(a, 'with u as (update public.members set team_id = ' || ta || ' where session_id = '
                        || sa || ' returning 1) select count(*) from u')
      || pg_temp.val(a, 'select public.shuffle_teams(' || sa || ')');
  perform pg_temp.check(got = '1', 'A moves and shuffles their own players', got);
  got := pg_temp.val(a, 'select string_agg(prompt, '','' order by prompt) from public.questions');
  perform pg_temp.check(got = 'A off,A on', 'A reads their whole bank and nothing of B''s', got);

  -- A player of A's.
  got := pg_temp.val(pia, 'select count(*) from public.sessions where code = ''' || code || '''');
  perform pg_temp.check(got = '1', 'a player finds A''s session by its code', got);
  got := pg_temp.val(pia, 'select string_agg(prompt, '','') from public.questions where owner = ''' || a || '''');
  perform pg_temp.check(got = 'A on', 'a player reads A''s active questions only', got);

  -- Both classes over: players' all-time board spans every teacher's games.
  got := pg_temp.val(a, 'with u as (update public.sessions set state = ''ended'' where id = '
                        || sa || ' returning 1) select count(*) from u');
  perform pg_temp.check(got = '1', 'A ends their own session', got);
  update public.sessions set state = 'ended' where id = '33333333-3333-3333-3333-333333333333';
  got := pg_temp.val(pia, 'select count(*) from public.team_results');
  perform pg_temp.check(got = '2', 'players still see every teacher''s finished games', got);
  got := pg_temp.val(a, 'select count(*) from public.team_results');
  perform pg_temp.check(got = '1', 'a teacher''s results are their own', got);
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail <> '' then '   <' || detail || '>' else '' end
  from results order by n;
select format('---- ISOLATION SQL %s ---- %s checks, %s failures',
              case when bool_and(ok) then 'PASS' else 'FAIL' end, count(*), count(*) filter (where not ok))
  from results;

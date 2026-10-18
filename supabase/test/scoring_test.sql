-- What a phone may not do to its own score, against the real schema on plain
-- Postgres (see run.sh). Every call is made as the `authenticated` role with
-- auth.uid() set, the way the app makes it.

create temp table results (n serial, ok boolean, name text, detail text);

create or replace function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$
  insert into results (ok, name, detail) values (coalesce(ok, false), name, detail)
$$;

-- `who` runs `stmt`; '' on success, or the error the server raised.
create or replace function pg_temp.as_player(who uuid, stmt text)
returns text language plpgsql as $$
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

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'teacher@t.dev', '{"username":"teacher","role":"admin"}'),
  ('00000000-0000-0000-0000-0000000000a1', 'ana@t.dev', '{"username":"ana"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@t.dev', '{"username":"ben"}');
insert into public.sessions (id, admin_id, state) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-00000000000a', 'lobby');
insert into public.teams (id, session_id, name) values
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'Red');

do $$
declare
  s    constant text := '''11111111-1111-1111-1111-111111111111''';
  ana  constant uuid := '00000000-0000-0000-0000-0000000000a1';
  ben  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  got  text;
  m    public.members;
begin
  -- Joining: who and which team, and the server's starting gems.
  got := pg_temp.as_player(ben, 'insert into public.members (session_id, team_id, profile_id, gems, finished)
    values (' || s || ', ''22222222-2222-2222-2222-222222222222'', ''' || ben || ''', 99999, true)');
  perform pg_temp.check(got like '%permission denied%'
    and not exists (select 1 from public.members where profile_id = ben),
    'a join cannot set its own gems or finish', got);
  got := pg_temp.as_player(ana, 'insert into public.members (session_id, team_id, profile_id)
    values (' || s || ', ''22222222-2222-2222-2222-222222222222'', ''' || ana || ''')');
  select * into m from public.members where profile_id = ana;
  perform pg_temp.check(got = '' and m.gems = 50, 'a join as the app makes it goes in, at 50 gems',
    got || ' gems ' || coalesce(m.gems::text, 'none'));

  -- Answers: 14 circles, and that is all.
  update public.sessions set state = 'running', ends_at = now() + interval '10 minutes';
  for i in 1..14 loop
    got := pg_temp.as_player(ana, 'select public.apply_answer(' || s || ', true)');
  end loop;
  select * into m from public.members where profile_id = ana;
  perform pg_temp.check(got = '' and m.items_done = 14 and m.gems = 220, 'all 14 answers and three atomic station bonuses count',
    got || ' items ' || m.items_done || ' gems ' || m.gems);
  got := pg_temp.as_player(ana, 'select public.apply_answer(' || s || ', true)');
  select * into m from public.members where profile_id = ana;
  perform pg_temp.check(got = 'every circle is already answered' and m.items_done = 14 and m.gems = 220,
    'a 15th answer is refused', got || ' items ' || m.items_done || ' gems ' || m.gems);
  got := pg_temp.as_player(ana, 'select public.skip_item(' || s || ')');
  select * into m from public.members where profile_id = ana;
  perform pg_temp.check(m.items_done = 14 and m.gems = 220, 'nor can a skip go past the last circle',
    'items ' || m.items_done || ' gems ' || m.gems);
  got := pg_temp.as_player(ben, 'select public.apply_answer(' || s || ', true)');
  perform pg_temp.check(got = 'you are not in this adventure', 'an outsider is told so', got);
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail <> '' then '   <' || detail || '>' else '' end
  from results order by n;
select format('---- SCORING SQL %s ---- %s checks, %s failures',
              case when bool_and(ok) then 'PASS' else 'FAIL' end, count(*), count(*) filter (where not ok))
  from results;

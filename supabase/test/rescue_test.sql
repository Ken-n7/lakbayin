-- Rescue, against the real schema on plain Postgres (see run.sh). Every call
-- goes through public.rescue() as the `authenticated` role with auth.uid() set,
-- the way the app makes it; the checks read the rows back as they are stored.

create temp table results (n serial, ok boolean, name text, detail text);

-- `who` calls rescue(p_session, p_to, p_amount) as a signed-in player.
-- Returns '' on success, or the error the server raised.
create or replace function pg_temp.rescue_as(who uuid, sess uuid, target uuid, amount int)
returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.rescue(sess, target, amount);
  perform set_config('role', 'postgres', true);
  return '';
exception when others then
  perform set_config('role', 'postgres', true);
  return sqlerrm;
end $$;

create or replace function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$
  insert into results (ok, name, detail) values (coalesce(ok, false), name, detail)
$$;

create or replace function pg_temp.gems(sess uuid, who uuid) returns int language sql as $$
  select gems from public.members where session_id = sess and profile_id = who
$$;

-- --- A class: a teacher, two teams ---------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'teacher@t.dev', '{"username":"teacher","role":"admin"}'),
  ('00000000-0000-0000-0000-0000000000a1', 'ana@t.dev',  '{"username":"ana"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@t.dev',  '{"username":"ben"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@t.dev',  '{"username":"dee"}'),
  ('00000000-0000-0000-0000-0000000000e1', 'eli@t.dev',  '{"username":"eli"}'),
  ('00000000-0000-0000-0000-0000000000f1', 'fay@t.dev',  '{"username":"fay"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@t.dev',  '{"username":"cal"}');

insert into public.sessions (id, admin_id) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-00000000000a');
insert into public.teams (id, session_id, name) values
  ('22222222-2222-2222-2222-22222222222a', '11111111-1111-1111-1111-111111111111', 'Reds'),
  ('22222222-2222-2222-2222-22222222222b', '11111111-1111-1111-1111-111111111111', 'Blues');
-- Reds: ana, ben, dee, eli, fay. Blues: cal.
insert into public.members (session_id, team_id, profile_id)
select '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-22222222222a', id
  from auth.users where email in ('ana@t.dev','ben@t.dev','dee@t.dev','eli@t.dev','fay@t.dev');
insert into public.members (session_id, team_id, profile_id) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-22222222222b',
   '00000000-0000-0000-0000-0000000000c1');
update public.sessions set state = 'running', ends_at = now() + interval '10 minutes'
 where id = '11111111-1111-1111-1111-111111111111';

do $$
declare
  s    uuid := '11111111-1111-1111-1111-111111111111';
  ana  uuid := '00000000-0000-0000-0000-0000000000a1';
  ben  uuid := '00000000-0000-0000-0000-0000000000b1';
  dee  uuid := '00000000-0000-0000-0000-0000000000d1';
  eli  uuid := '00000000-0000-0000-0000-0000000000e1';
  fay  uuid := '00000000-0000-0000-0000-0000000000f1';
  cal  uuid := '00000000-0000-0000-0000-0000000000c1';
  err  text;
  team_before int;
  team_after int;
begin
  -- The old fixed-10 signature is gone; the app calls the new one.
  perform pg_temp.check(not exists (select 1 from pg_proc where proname = 'rescue'
      and pg_get_function_identity_arguments(oid) = 'p_session uuid, p_to uuid'),
    'the old rescue(session, to) is dropped');
  perform pg_temp.check(has_function_privilege('authenticated',
      'public.rescue(uuid, uuid, int)', 'execute'),
    'signed-in players may call rescue(session, to, amount)');

  -- The rescuer picks the amount: ana gives ben 15.
  select sum(gems) into team_before from public.members where team_id = '22222222-2222-2222-2222-22222222222a';
  err := pg_temp.rescue_as(ana, s, ben, 15);
  perform pg_temp.check(err = '', 'a teammate can be rescued with a chosen amount', err);
  perform pg_temp.check(pg_temp.gems(s, ana) = 35, 'the rescuer loses what they gave', pg_temp.gems(s, ana)::text);
  perform pg_temp.check(pg_temp.gems(s, ben) = 65, 'the teammate gains it', pg_temp.gems(s, ben)::text);
  select sum(gems) into team_after from public.members where team_id = '22222222-2222-2222-2222-22222222222a';
  perform pg_temp.check(team_before = team_after, 'no gems are made or lost', team_before || ' -> ' || team_after);
  perform pg_temp.check((select rescued_at is not null from public.members where session_id = s and profile_id = ana),
    'the rescue is recorded against the rescuer');

  -- ONE chance per player.
  err := pg_temp.rescue_as(ana, s, dee, 1);
  perform pg_temp.check(err like '%already used your rescue%', 'a second rescue by the same player is refused', err);
  perform pg_temp.check(pg_temp.gems(s, ana) = 35 and pg_temp.gems(s, dee) = 50, '...and moves nothing');

  -- Being rescued does not use up your own chance; being rescued twice is fine.
  err := pg_temp.rescue_as(dee, s, ben, 5);
  perform pg_temp.check(err = '', 'a player can be rescued by more than one teammate', err);
  perform pg_temp.check(pg_temp.gems(s, ben) = 70, '...and gets both', pg_temp.gems(s, ben)::text);

  -- Amounts: at least 1, at most all but 1.
  err := pg_temp.rescue_as(eli, s, ben, 0);
  perform pg_temp.check(err like '%at least 1 gem%', 'giving 0 is refused', err);
  err := pg_temp.rescue_as(eli, s, ben, -5);
  perform pg_temp.check(err like '%at least 1 gem%', 'a negative amount is refused (no taking gems)', err);
  err := pg_temp.rescue_as(eli, s, ben, null);
  perform pg_temp.check(err like '%at least 1 gem%', 'no amount is refused', err);
  err := pg_temp.rescue_as(eli, s, ben, 50);
  perform pg_temp.check(err like '%at most 49 gems%', 'giving every gem is refused, and the limit is named', err);
  perform pg_temp.check(pg_temp.gems(s, eli) = 50 and (select rescued_at is null from public.members
      where session_id = s and profile_id = eli), 'a refused rescue uses nothing up');
  err := pg_temp.rescue_as(eli, s, ben, 49);
  perform pg_temp.check(err = '', 'giving all but 1 is allowed', err);
  perform pg_temp.check(pg_temp.gems(s, eli) = 1 and not (select eliminated from public.members
      where session_id = s and profile_id = eli), '...and the rescuer is left on 1, still in');

  -- Who can be rescued.
  err := pg_temp.rescue_as(fay, s, fay, 5);
  perform pg_temp.check(err like '%cannot rescue yourself%', 'you cannot rescue yourself', err);
  err := pg_temp.rescue_as(fay, s, cal, 5);
  perform pg_temp.check(err like '%not on your team%', 'you cannot rescue another team''s player', err);
  err := pg_temp.rescue_as(cal, s, fay, 5);
  perform pg_temp.check(err like '%not on your team%', '...from either side', err);
  err := pg_temp.rescue_as(fay, s, '99999999-9999-9999-9999-999999999999', 5);
  perform pg_temp.check(err like '%not on your team%', 'a player not in the adventure cannot be rescued', err);

  update public.members set gems = 0 where session_id = s and profile_id = dee;   -- trigger latches eliminated
  err := pg_temp.rescue_as(fay, s, dee, 5);
  perform pg_temp.check(err like '%already out%', 'an eliminated teammate cannot be rescued', err);
  err := pg_temp.rescue_as(dee, s, fay, 5);
  perform pg_temp.check(err like '%already used%' or err like '%out of the adventure%',
    'an eliminated player cannot rescue', err);

  update public.members set finished = true where session_id = s and profile_id = ben;
  err := pg_temp.rescue_as(fay, s, ben, 5);
  perform pg_temp.check(err like '%already finished%', 'a teammate through the Victory Gate cannot be rescued', err);
  perform pg_temp.check(pg_temp.gems(s, fay) = 50, 'fay still has her rescue and her gems');

  -- Only while the adventure runs.
  update public.sessions set state = 'paused' where id = s;
  err := pg_temp.rescue_as(fay, s, ana, 5);
  perform pg_temp.check(err like '%not running%', 'no rescue while the Quest Keeper has paused', err);
  update public.sessions set state = 'running' where id = s;
  err := pg_temp.rescue_as(fay, s, ana, 5);
  perform pg_temp.check(err = '', 'rescue works again once resumed', err);

  -- Not signed in.
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.rescue(s, ana, 5);
    err := '';
  exception when others then err := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  perform pg_temp.check(err like '%not in this adventure%', 'a caller with no account is refused', err);
  perform set_config('role', 'anon', true);
  begin
    perform public.rescue(s, ana, 5);
    err := '';
  exception when others then err := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  -- Functions are callable by every API role here, as all of this schema's are;
  -- an anonymous caller has no auth.uid(), so it is refused all the same.
  perform pg_temp.check(err like '%permission denied%' or err like '%not in this adventure%',
    'an anonymous caller moves nothing', err);
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail <> '' then '   <' || detail || '>' else '' end
  from results order by n;
select format('---- RESCUE SQL %s ---- %s checks, %s failures',
              case when bool_and(ok) then 'PASS' else 'FAIL' end, count(*), count(*) filter (where not ok))
  from results;

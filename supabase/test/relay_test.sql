-- The movement relay's row (schema.sql 7b), on plain Postgres (see run.sh):
-- one relay holds it at a time, a stale one can be replaced, a live one never
-- is. Every call goes through claim_relay / release_relay as the
-- `authenticated` role with auth.uid() set, the way the relay and Game
-- Controls make it.

create temp table results (n serial, ok boolean, name text, detail text);

-- `who` claims the row for relay `owner`; 'true', 'false' or the error.
create or replace function pg_temp.claim_as(who uuid, owner text, url text)
returns text language plpgsql as $$
declare got boolean;
begin
  perform set_config('request.jwt.claim.sub', coalesce(who::text, ''), true);
  perform set_config('role', case when who is null then 'anon' else 'authenticated' end, true);
  got := public.claim_relay(owner, url, 20);
  perform set_config('role', 'postgres', true);
  return got::text;
exception when others then
  perform set_config('role', 'postgres', true);
  return sqlerrm;
end $$;

create or replace function pg_temp.release_as(who uuid, owner text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.release_relay(owner);
  perform set_config('role', 'postgres', true);
end $$;

create or replace function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$
  insert into results (ok, name, detail) values (coalesce(ok, false), name, detail)
$$;

create or replace function pg_temp.row() returns text language sql as $$
  select coalesce(owner, '-') || ' ' || coalesce(url, '-') from public.relay where id = 1
$$;

-- Two admins (the home laptop's account, the teacher's) and a student.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a0', 'home@t.dev',    '{"username":"home","role":"admin"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'teacher@t.dev', '{"username":"teacher","role":"admin"}'),
  ('00000000-0000-0000-0000-0000000000c0', 'kid@t.dev',     '{"username":"kid"}');

do $$
declare
  home    uuid := '00000000-0000-0000-0000-0000000000a0';
  teacher uuid := '00000000-0000-0000-0000-0000000000b0';
  kid     uuid := '00000000-0000-0000-0000-0000000000c0';
  got text;
begin
  perform pg_temp.check(pg_temp.row() = '- -', 'the row exists, free, on a fresh project', pg_temp.row());

  got := pg_temp.claim_as(home, 'home', 'wss://a');
  perform pg_temp.check(got = 'true' and pg_temp.row() = 'home wss://a', 'a free row is taken', got || ' ' || pg_temp.row());

  got := pg_temp.claim_as(teacher, 'backup', 'wss://b');
  perform pg_temp.check(got = 'false' and pg_temp.row() = 'home wss://a',
    'a live relay''s row is not taken', got || ' ' || pg_temp.row());

  got := pg_temp.claim_as(home, 'home', 'wss://a2');
  perform pg_temp.check(got = 'true' and pg_temp.row() = 'home wss://a2',
    'its owner refreshes it, new address and all', got || ' ' || pg_temp.row());

  update public.relay set updated_at = now() - interval '181 seconds';
  got := pg_temp.claim_as(teacher, 'backup', 'wss://b');
  perform pg_temp.check(got = 'true' and pg_temp.row() = 'backup wss://b',
    'a row not refreshed for 180s is taken over', got || ' ' || pg_temp.row());

  got := pg_temp.claim_as(home, 'home', 'wss://a3');
  perform pg_temp.check(got = 'false' and pg_temp.row() = 'backup wss://b',
    'the old owner, back, does not take it back', got || ' ' || pg_temp.row());

  perform pg_temp.release_as(home, 'home');
  perform pg_temp.check(pg_temp.row() = 'backup wss://b', 'only the owner lets it go', pg_temp.row());

  perform pg_temp.release_as(teacher, 'backup');
  perform pg_temp.check(pg_temp.row() = 'backup -', 'its owner lets it go', pg_temp.row());
  got := pg_temp.claim_as(home, 'home', 'wss://a4');
  perform pg_temp.check(got = 'true' and pg_temp.row() = 'home wss://a4',
    '...and the next relay takes it at once', got || ' ' || pg_temp.row());

  update public.relay set owner = null, url = 'wss://old', updated_at = now();
  got := pg_temp.claim_as(teacher, 'backup', 'wss://b2');
  perform pg_temp.check(got = 'true' and pg_temp.row() = 'backup wss://b2',
    'a row written before owners is taken', got || ' ' || pg_temp.row());

  update public.relay set url = null;
  got := pg_temp.claim_as(kid, 'kid', 'wss://evil');
  perform pg_temp.check(got <> 'true' and pg_temp.row() = 'backup -', 'a student cannot take it',
    got || ' ' || pg_temp.row());
  got := pg_temp.claim_as(null, 'anon', 'wss://evil');
  perform pg_temp.check(got <> 'true' and pg_temp.row() = 'backup -', 'an anonymous caller cannot take it',
    got || ' ' || pg_temp.row());
end $$;

-- Tickets (schema.sql 7c): the phone's hello carries one instead of its
-- sign-in token. `who` runs `query`; its first value as text, or 'error: ...'.
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

insert into public.sessions (id, admin_id) values
  ('55555555-5555-5555-5555-555555555555', '00000000-0000-0000-0000-0000000000b0'),
  ('66666666-6666-6666-6666-666666666666', '00000000-0000-0000-0000-0000000000a0');
insert into public.members (session_id, profile_id) values
  ('55555555-5555-5555-5555-555555555555', '00000000-0000-0000-0000-0000000000c0');

do $$
declare
  home    uuid := '00000000-0000-0000-0000-0000000000a0';
  teacher uuid := '00000000-0000-0000-0000-0000000000b0';
  kid     uuid := '00000000-0000-0000-0000-0000000000c0';
  s       uuid := '55555555-5555-5555-5555-555555555555';
  other   uuid := '66666666-6666-6666-6666-666666666666';
  t       text;
  got     text;
  ask     constant text := 'select public.relay_ticket(%L, %L)';
  redeem  constant text := 'select public.relay_redeem(%L, %L, %L)';
begin
  t := pg_temp.val(kid, format(ask, s, 'player'));
  perform pg_temp.check(t ~ '^[0-9a-f-]{36}$', 'a player in the session gets a ticket', t);
  got := pg_temp.val(kid, format(ask, other, 'player'));
  perform pg_temp.check(got like 'error:%not in this adventure', '...not for a session they are not in', got);
  got := pg_temp.val(kid, format(ask, s, 'teacher'));
  perform pg_temp.check(got like 'error:%not your session', 'a student gets no teacher ticket', got);
  got := pg_temp.val(home, format(ask, s, 'teacher'));
  perform pg_temp.check(got like 'error:%not your session', '...nor another teacher, for this session', got);
  got := pg_temp.val(teacher, format(ask, s, 'teacher'));
  perform pg_temp.check(got ~ '^[0-9a-f-]{36}$', 'the session''s teacher gets one', got);

  got := pg_temp.val(home, format(redeem, t, s, 'player'));
  perform pg_temp.check(got = kid::text, 'a relay redeems it: whose it is', got);
  got := pg_temp.val(home, format(redeem, t, other, 'player')) || pg_temp.val(home, format(redeem, t, s, 'teacher'));
  perform pg_temp.check(got = '', '...only for its own session and role', got);
  got := pg_temp.val(kid, format(redeem, t, s, 'player'));
  perform pg_temp.check(got = '', 'a student cannot redeem one', got);
  got := pg_temp.val(kid, 'select count(*) from public.relay_tickets');
  perform pg_temp.check(got = '0' or got like 'error:%', 'nobody reads the tickets directly', got);
  update public.relay_tickets set made_at = now() - interval '61 minutes' where ticket = t::uuid;
  got := pg_temp.val(home, format(redeem, t, s, 'player'));
  perform pg_temp.check(got = '', 'an hour-old ticket opens nothing', got);
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail <> '' then '   <' || detail || '>' else '' end
  from results order by n;
select format('---- RELAY SQL %s ---- %s checks, %s failures',
              case when bool_and(ok) then 'PASS' else 'FAIL' end, count(*), count(*) filter (where not ok))
  from results;

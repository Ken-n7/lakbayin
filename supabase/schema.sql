-- NumXventure — Supabase schema.
-- Paste into the SQL Editor of your project, or `supabase db push`.
-- Auth is Supabase's own: email + password, username as the display name.
--
-- SAFE TO RE-RUN. Every statement is idempotent, so pasting the whole file
-- again after an edit is the normal way to apply a change. The one thing it
-- cannot do is alter a table that already exists -- `create table if not
-- exists` skips it silently. Changing a column means an `alter table` by hand,
-- or dropping the table first (see the reset block at the bottom).

-- 1. Profiles ---------------------------------------------------------------
-- auth.users holds the credentials and the email. This is everything the game
-- shows: the display name, the role, the chosen hero.
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  username   text unique not null check (username ~ '^[A-Za-z0-9_-]{3,20}$'),
  role       text not null default 'player' check (role in ('player','admin')),
  hero       int  not null default 0,
  created_at timestamptz not null default now()
);

-- A row appears the moment someone signs up; the client never inserts it.
--
-- Everything here is defensive because a raise in this function fails the
-- whole signup with an opaque 500. The dashboard's "Add user" form sends no
-- metadata at all, which is how the NOT NULL on username was found.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  uname text := nullif(trim(new.raw_user_meta_data->>'username'), '');
  urole text := new.raw_user_meta_data->>'role';
begin
  -- No username given: derive one from the email's local part, scrubbed to
  -- the allowed charset and padded to the 3-character floor.
  if uname is null then
    uname := regexp_replace(split_part(new.email, '@', 1), '[^A-Za-z0-9_-]', '', 'g');
    uname := coalesce(nullif(uname, ''), 'player');
  end if;
  uname := left(uname, 20);
  -- Pad only when short. `rpad` also TRUNCATES anything longer than its
  -- length argument, which quietly cut every derived name to three letters.
  if length(uname) < 3 then
    uname := rpad(uname, 3, '0');
  end if;

  -- Taken: suffix it rather than fail the signup. The player renames later.
  if exists (select 1 from public.profiles where username = uname) then
    uname := left(uname, 14) || '-' || left(replace(new.id::text, '-', ''), 5);
  end if;

  insert into public.profiles (id, username, role)
  values (new.id, uname, case when urole in ('player','admin') then urole else 'player' end);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin')
$$;

-- Sign in takes an email or a username (client, 2026-09-23). GoTrue only
-- knows emails, so a username has to be resolved to one first, and the email
-- lives in auth.users where no client may read it.
--
-- The tradeoff, stated plainly: anyone who can reach this project can map a
-- username to an email address. For a classroom roster that is acceptable; if
-- it ever is not, the fix is to drop username sign-in, not to obscure this.
create or replace function public.email_for_username(uname text) returns text
language sql stable security definer set search_path = '' as $$
  select u.email
  from   auth.users u
  join   public.profiles p on p.id = u.id
  where  lower(p.username) = lower(trim(uname))
$$;

grant execute on function public.email_for_username(text) to anon, authenticated;

-- 2. Sessions ---------------------------------------------------------------
-- One live adventure. The clock lives here so every phone reads the same one:
-- `ends_at` while running, `remaining_s` while paused.
create table if not exists public.sessions (
  id          uuid primary key default gen_random_uuid(),
  admin_id    uuid not null references public.profiles on delete cascade,
  duration_s  int  not null default 600 check (duration_s between 60 and 7200),
  state       text not null default 'lobby'
              check (state in ('lobby','running','paused','ended')),
  ends_at     timestamptz,
  remaining_s int,
  created_at  timestamptz not null default now()
);

-- The join code a teacher reads out: four characters, none of the pairs that
-- read alike off a board (0/O, 1/I/L). Unique among sessions still in play --
-- not for ever, which four characters could not promise -- so the lookup is
-- always "the newest open session with this code".
create or replace function public.session_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  -- No O/0, I/1, L, nor one of each pair the game's pixel font draws alike
  -- (Z/2, S/5, B/8, V/U, G/6): the game maps a typed twin onto these.
  abc text := 'ACDEFHJKMNPQRTUWXY23456789';
  c   text;
begin
  loop
    c := '';
    for i in 1..4 loop
      c := c || substr(abc, 1 + floor(random() * length(abc))::int, 1);
    end loop;
    exit when not exists (select 1 from public.sessions
                          where code = c and state <> 'ended'
                            and created_at > now() - interval '3 hours');
  end loop;
  return c;
end $$;

alter table public.sessions add column if not exists
  code text not null default public.session_code();

-- When it ended, stamped by the server (not the phone): the Quest Keeper's
-- History tells "Ended early" (End pressed with time left) from "Time's up".
-- Sessions from before this column have none and read as plain "Ended".
alter table public.sessions add column if not exists ended_at timestamptz;

create or replace function public.stamp_ended() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.state = 'ended' and old.state is distinct from 'ended' then
    new.ended_at := now();
  end if;
  return new;
end $$;

drop trigger if exists sessions_stamp_ended on public.sessions;
create trigger sessions_stamp_ended before update on public.sessions
  for each row execute function public.stamp_ended();

-- 3. Teams and members ------------------------------------------------------
-- The team name IS the join code, so it is unique within its session.
create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions on delete cascade,
  name       text not null,
  unique (session_id, name)
);

-- A player joins the SESSION (by its code) and then picks a team, so
-- `team_id` is empty until they do -- and empty again if the teacher removes
-- their team, which sends them back to pick rather than out of the adventure.
create table if not exists public.members (
  session_id uuid not null references public.sessions on delete cascade,
  team_id    uuid          references public.teams    on delete set null,
  profile_id uuid not null references public.profiles on delete cascade,
  gems       int  not null default 50,
  correct    int  not null default 0,
  items_done int  not null default 0,
  eliminated boolean not null default false,
  finished   boolean not null default false,
  primary key (session_id, profile_id)   -- one membership per player per adventure
);

-- Projects made before the join code: the key was (team_id, profile_id), which
-- cannot hold an empty team, and removing a team deleted its players.
do $$
begin
  if exists (select 1 from pg_constraint c
             join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
             where c.conname = 'members_pkey' and a.attname = 'team_id') then
    alter table public.members drop constraint members_pkey;
    alter table public.members add primary key (session_id, profile_id);
  end if;
end $$;
alter table public.members alter column team_id drop not null;
alter table public.members drop constraint if exists members_team_id_fkey;
alter table public.members add constraint members_team_id_fkey
  foreign key (team_id) references public.teams on delete set null;

-- 4. Question bank ----------------------------------------------------------
-- Empty is fine: QuestionGen still fills any station short of active items.
create table if not exists public.questions (
  id         uuid primary key default gen_random_uuid(),
  station    int  not null check (station between 1 and 3),
  prompt     text not null,
  answer     text not null,
  hint       text not null default '',
  feedback   text not null default '' check (char_length(feedback) <= 300),
  active     boolean not null default true,
  -- Authoring order IS play order: the teacher's first question for a station
  -- is its first circle. Ordering by `id` looked deterministic and was not --
  -- a uuid sorts arbitrarily, so the class met the questions shuffled.
  created_at timestamptz not null default now()
);

-- `create table if not exists` skips an existing table, so this is how the
-- column reaches a project made before it existed.
alter table public.questions add column if not exists
  created_at timestamptz not null default now();

-- Each teacher their own bank (client, 2026-10-09): a question belongs to
-- whoever wrote it, and a class plays its own teacher's. Rows from before this
-- have no owner until they are given one (supabase/README.md, step 6).
alter table public.questions add column if not exists
  owner uuid references public.profiles on delete cascade default auth.uid();

-- Freeze the authored bank at Start; a returning phone gets the same questions.
alter table public.sessions add column if not exists question_bank jsonb;
create or replace function public.snapshot_questions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.state = 'running' and old.state = 'lobby' then
    select coalesce(jsonb_agg(to_jsonb(q) order by q.station, q.created_at, q.id), '[]'::jsonb)
      into new.question_bank
      from public.questions q where q.owner = new.admin_id and q.active;
  end if;
  return new;
end $$;
drop trigger if exists sessions_snapshot_questions on public.sessions;
create trigger sessions_snapshot_questions before update on public.sessions
  for each row execute function public.snapshot_questions();

-- Existing running/paused sessions predate snapshots. Freeze their current
-- authored bank once so updated phones can still rejoin them after upgrade.
update public.sessions s set question_bank = (
  select coalesce(jsonb_agg(to_jsonb(q) order by q.station, q.created_at, q.id), '[]'::jsonb)
    from public.questions q where q.owner = s.admin_id and q.active)
 where s.question_bank is null and s.state in ('running', 'paused');

-- 4b. Scoring, server side ---------------------------------------------------
-- The client may not write its own score (SPECS §10 Phase 4). Every gem change
-- goes through one of these, which run as the owner and therefore past RLS.
--
-- Each one checks three things the client cannot be trusted with: that the
-- caller is in that session, that the session is actually running, and what
-- the arithmetic comes to. The values live in one place here and in
-- `Game.GEM_*`; they are the client's rules restated where they cannot be
-- edited by a phone.

alter table public.members add column if not exists
  updated_at timestamptz not null default now();

-- Session first, then member rows: every scoring RPC uses this order. It
-- serializes final-player checks with other scores and the teacher's pause/end.
create schema if not exists numxventure_private;
revoke all on schema numxventure_private from public, anon, authenticated;
create or replace function numxventure_private.lock_session(p_session uuid)
returns public.sessions language plpgsql security definer set search_path = '' as $$
declare s public.sessions;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into s from public.sessions where id = p_session for no key update;
  if s is null then raise exception 'the adventure no longer exists'; end if;
  return s;
end $$;
create or replace function numxventure_private.running_session(p_session uuid)
returns public.sessions language plpgsql security definer set search_path = '' as $$
declare s public.sessions;
begin
  s := numxventure_private.lock_session(p_session);
  if s.state <> 'running' or s.ends_at is null or s.ends_at <= clock_timestamp()
     or s.created_at <= clock_timestamp() - interval '3 hours' then
    raise exception 'the adventure is not running';
  end if;
  return s;
end $$;

alter table public.members add column if not exists wrong int not null default 0;
alter table public.members add column if not exists skipped int not null default 0;
alter table public.members add column if not exists hints_used int not null default 0;
alter table public.members add column if not exists station_flawed boolean not null default false;
alter table public.members add column if not exists station_used_hint boolean not null default false;
alter table public.members add column if not exists item_used_hint boolean not null default false;
alter table public.members add column if not exists perfect_stations boolean[] not null default array[false,false,false];
alter table public.members add column if not exists stations_done int not null default 0;
-- Correct answers in a row with no hint (Level Up rules): each one is worth
-- 2 more than the last, from 10 up to 20. A miss, a skip or a hint resets it.
alter table public.members add column if not exists streak int not null default 0;

-- Replies and change-feed events can arrive in different orders. A device
-- must never restore an older row over a later answer or rescue.
alter table public.members add column if not exists revision bigint not null default 0;
create or replace function public.bump_member_revision() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.revision := old.revision + 1;
  return new;
end $$;
drop trigger if exists members_revision on public.members;
create trigger members_revision before update on public.members
  for each row execute function public.bump_member_revision();

-- Finalize the boundary in the SAME transaction as its answer/skip. A phone
-- can die before Continue without leaving a station's completion unsaved.
create or replace function numxventure_private.complete_station(p_session uuid)
returns public.members language plpgsql security definer set search_path = '' as $$
declare m public.members; n int;
begin
  select * into m from public.members where session_id = p_session and profile_id = auth.uid();
  n := case m.items_done when 8 then 1 when 11 then 2 when 14 then 3 else 0 end;
  if n > m.stations_done then
    update public.members
       set gems = gems + case when not station_flawed and not station_used_hint then 10 else 0 end,
           perfect_stations[n] = not station_flawed and not station_used_hint,
           stations_done = n, station_flawed = false, station_used_hint = false,
           item_used_hint = false, updated_at = now()
     where session_id = p_session and profile_id = auth.uid() returning * into m;
  end if;
  return m;
end $$;

-- Recover boundaries from older clients. Their gems are already historical;
-- do not invent an unknown perfect bonus while repairing the completion flag.
update public.members set stations_done = case when items_done >= 14 then 3
    when items_done >= 11 then 2 when items_done >= 8 then 1 else 0 end
 where stations_done < case when items_done >= 14 then 3
    when items_done >= 11 then 2 when items_done >= 8 then 1 else 0 end;

create or replace function public.apply_answer(p_session uuid, p_correct boolean)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare row public.members;
begin
  perform numxventure_private.running_session(p_session);
  update public.members
     set gems = gems + case when not p_correct then -5
                            when item_used_hint then 10
                            else 10 + 2 * least(streak, 5) end,
         streak = case when p_correct and not item_used_hint then streak + 1 else 0 end,
         correct = correct + case when p_correct then 1 else 0 end,
         wrong = wrong + case when p_correct then 0 else 1 end,
         station_flawed = station_flawed or not p_correct,
         item_used_hint = false, items_done = items_done + 1, updated_at = now()
   where session_id = p_session and profile_id = auth.uid() and items_done < 14
     and not eliminated and not finished
  returning * into row;
  if row is null then
    raise exception '%', case when exists (select 1 from public.members
        where session_id = p_session and profile_id = auth.uid())
      then 'every circle is already answered' else 'you are not in this adventure' end;
  end if;
  return numxventure_private.complete_station(p_session);
end $$;

create or replace function public.spend_hint(p_session uuid)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare row public.members;
begin
  perform numxventure_private.running_session(p_session);
  update public.members
     set gems = gems - 5, streak = 0, hints_used = hints_used + 1, item_used_hint = true,
         station_used_hint = true, updated_at = now()
   where session_id = p_session and profile_id = auth.uid() and items_done < 14
     and not item_used_hint and not eliminated and not finished
  returning * into row;
  if row is null then raise exception 'that hint is not available'; end if;
  return row;
end $$;

create or replace function public.skip_item(p_session uuid)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare row public.members;
begin
  perform numxventure_private.running_session(p_session);
  update public.members
     set gems = gems - 15, streak = 0, items_done = items_done + 1, skipped = skipped + 1,
         station_flawed = true, item_used_hint = false, updated_at = now()
   where session_id = p_session and profile_id = auth.uid() and items_done < 14
     and not eliminated and not finished
  returning * into row;
  if row is null then raise exception 'that circle is not available'; end if;
  return numxventure_private.complete_station(p_session);
end $$;

-- Gems no longer clamp at zero, so a player can reach it and be eliminated
-- (SPECS §4, and the research paper's "Eliminated Member (reaching 0 gems):
-- -50 gems"). They keep answering afterwards -- the -50 has already been taken
-- and a student benched for the rest of a proctored class is the worse
-- outcome -- but they cannot fall further: `eliminated` latches once, so the
-- team is charged exactly one -50 however the run goes from there.
--
-- Q2 is still open on whether an eliminated player should stop entirely. If
-- the client says stop, it is this flag the map would read.

-- Older clients still send a separate station call. Completion and its bonus
-- now belong to the final answer/skip transaction above; this call only reads.

create or replace function public.finish_station(p_session uuid, p_perfect boolean)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare row public.members;
begin
  -- Compatibility for older clients: the last answer already paid the bonus.
  -- A supplied perfect flag can never award another one.
  perform numxventure_private.lock_session(p_session);
  select * into row from public.members
   where session_id = p_session and profile_id = auth.uid() and stations_done > 0;
  if row is null then raise exception 'that station is not finished'; end if;
  return row;
end $$;

-- Elimination latches the first time a player's gems reach zero, so the team
-- is charged -50 exactly once no matter what happens afterwards.
create or replace function public.mark_eliminated() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.gems <= 0 and not old.eliminated then
    new.eliminated := true;
  end if;
  return new;
end $$;

drop trigger if exists members_eliminated on public.members;
create trigger members_eliminated before update on public.members
  for each row execute function public.mark_eliminated();

-- Rescue (client, 2026-09-27): a player gives a teammate who is running out of
-- gems as many of their own as they choose, both halves in one statement so a
-- failure cannot create or destroy gems. Replaces the fixed 10 of the paper's
-- "transfer 10 gems to assist one member only".
--
-- ONE rescue per player per adventure -- sent, not received: a player can be
-- rescued by several teammates -- enforced by `rescued_at`, never trusted to
-- the client. The rescuer keeps at least 1 gem: giving the last one away would
-- eliminate them and cost the team the -50 the rescue was meant to prevent.
-- You cannot rescue yourself, someone on another team, someone already out
-- (the -50 has been taken; refunding it would make elimination negotiable), or
-- someone already through the Victory Gate.
--
-- Both rows are locked together, in one order, before anything is read: two
-- teammates rescuing each other at the same moment wait for each other rather
-- than deadlock, and an answer scored mid-rescue cannot take the giver under 1.
-- Returns the GIVER's row, which is the one the rescuer's phone keeps.
alter table public.members add column if not exists rescued_at timestamptz;

drop function if exists public.rescue(uuid, uuid);

create or replace function public.rescue(p_session uuid, p_to uuid, p_amount int)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare
  giver public.members;
  taker public.members;
begin
  perform numxventure_private.running_session(p_session);
  perform 1 from public.members
   where session_id = p_session and profile_id in (auth.uid(), p_to)
   order by profile_id
   for update;
  select * into giver from public.members
   where session_id = p_session and profile_id = auth.uid();
  if giver is null then
    raise exception 'you are not in this adventure';
  end if;
  if giver.rescued_at is not null then
    raise exception 'you have already used your rescue';
  end if;
  if giver.eliminated then
    raise exception 'you are out of the adventure';
  end if;
  if giver.profile_id = p_to then
    raise exception 'you cannot rescue yourself';
  end if;
  if p_amount is null or p_amount < 1 then
    raise exception 'give at least 1 gem';
  end if;
  if p_amount > giver.gems - 1 then
    raise exception 'you can give at most % gems -- keep at least 1', greatest(giver.gems - 1, 0);
  end if;

  select * into taker from public.members
   where session_id = p_session and profile_id = p_to;
  if taker is null or giver.team_id is null
     or taker.team_id is distinct from giver.team_id then
    raise exception 'that player is not on your team';
  end if;
  if taker.eliminated then
    raise exception 'that player is already out';
  end if;
  if taker.finished then
    raise exception 'that player has already finished';
  end if;

  update public.members set gems = gems + p_amount, updated_at = now()
   where session_id = p_session and profile_id = p_to;
  update public.members set gems = gems - p_amount, rescued_at = now(), updated_at = now()
   where session_id = p_session and profile_id = auth.uid()
  returning * into giver;
  return giver;
end $$;

grant execute on function public.rescue(uuid, uuid, int) to authenticated;

-- A player's own time for the adventure: the game clock when they walk into
-- the Victory Gate -- pauses are not theirs, so they do not count (the clock's
-- deadline moves on resume). Set once, and only for a player who finished all
-- three stations; the leaderboard's Time column reads it.
alter table public.members add column if not exists finish_s int;

create or replace function public.finish_run(p_session uuid)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare
  s   public.sessions;
  row public.members;
begin
  s := numxventure_private.running_session(p_session);
  -- The race to the Gate (Level Up rules): first through +20, second +15,
  -- third +10, everyone after +5 -- once. The session lock above puts finishers
  -- in order, so two at the same moment cannot both be first.
  update public.members
     set gems = gems + case when finished then 0 else
           case (select count(*) from public.members f where f.session_id = p_session and f.finished)
             when 0 then 20 when 1 then 15 when 2 then 10 else 5 end end,
         finished = true,
         finish_s = coalesce(finish_s, greatest(0, s.duration_s
                      - greatest(0, ceil(extract(epoch from (s.ends_at - now())))::int))),
         updated_at = now()
   where session_id = p_session and profile_id = auth.uid() and stations_done >= 3 and not eliminated
  returning * into row;
  if row is null then
    raise exception 'the adventure is not finished';
  end if;
  return row;
end $$;

grant execute on function public.finish_run(uuid) to authenticated;

-- Everyone done -- through the Gate or eliminated -- ends the session by itself,
-- as End would (client): every phone goes to the results together, instead of
-- the early finishers each on their own. One who left is neither, so the
-- session waits for the clock or the Quest Keeper, and they are DNF.
create or replace function public.end_when_all_done() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if ((new.finished and not old.finished) or (new.eliminated and not old.eliminated))
     and not exists (select 1 from public.members
                     where session_id = new.session_id
                       and not finished and not eliminated) then
    update public.sessions set state = 'ended'
     where id = new.session_id and state in ('running', 'paused');
  end if;
  return new;
end $$;

-- AFTER, and on any update: `eliminated` is set by the BEFORE trigger above,
-- never named in the UPDATE itself.
drop trigger if exists members_all_done on public.members;
create trigger members_all_done after update on public.members
  for each row execute function public.end_when_all_done();

grant execute on function public.apply_answer(uuid, boolean) to authenticated;
grant execute on function public.spend_hint(uuid) to authenticated;
grant execute on function public.skip_item(uuid) to authenticated;
grant execute on function public.finish_station(uuid, boolean) to authenticated;

-- A request ID is retained for the session's lifetime. Replaying a request
-- after a lost reply returns the current row, even after End, without charging
-- again. The ledger is outside the API schema and is never client-writable.
create table if not exists numxventure_private.score_events (
  session_id uuid not null references public.sessions on delete cascade,
  profile_id uuid not null references public.profiles on delete cascade,
  event_id uuid not null,
  payload jsonb not null,
  primary key (session_id, profile_id, event_id)
);
alter table numxventure_private.score_events enable row level security;
create or replace function public.score_event(p_session uuid, p_event uuid,
  p_kind text, p_flag boolean, p_item int, p_station int)
returns public.members language plpgsql security definer set search_path = '' as $$
declare m public.members; saved jsonb;
  payload jsonb := jsonb_build_object('kind', p_kind, 'flag', p_flag, 'item', p_item, 'station', p_station);
begin
  perform numxventure_private.lock_session(p_session);
  select * into m from public.members where session_id = p_session and profile_id = auth.uid();
  if m is null then raise exception 'you are not in this adventure'; end if;
  if p_event is null then raise exception 'a score needs a request ID'; end if;
  select e.payload into saved from numxventure_private.score_events e
   where e.session_id = p_session and e.profile_id = auth.uid() and e.event_id = p_event;
  if found then
    if saved <> payload then raise exception 'that request ID was already used'; end if;
    return m;
  end if;
  if p_kind in ('answer', 'skip', 'hint') and (p_item is null or p_item <> m.items_done) then
    raise exception 'that circle is no longer current';
  end if;
  case p_kind
    when 'answer' then m := public.apply_answer(p_session, p_flag);
    when 'skip' then m := public.skip_item(p_session);
    when 'hint' then m := public.spend_hint(p_session);
    when 'station' then
      if p_station is null or p_station < 0 or p_station >= m.stations_done then
        raise exception 'that station is not finished';
      end if;
    when 'finish' then m := public.finish_run(p_session);
    else raise exception 'unknown score';
  end case;
  insert into numxventure_private.score_events values (p_session, auth.uid(), p_event, payload);
  return m;
end $$;
revoke all on function public.score_event(uuid, uuid, text, boolean, int, int) from public, anon;
grant execute on function public.score_event(uuid, uuid, text, boolean, int, int) to authenticated;

-- 4c. Picking a team ---------------------------------------------------------
-- Students pick their own team in the lobby and may switch until the teacher
-- presses Start; from then on teams are locked, or a player could carry their
-- gems over to whichever side is winning. The one exception is somebody with
-- no team -- never picked, or theirs was removed -- who may always pick one.
-- The same rule binds the teacher's Move and Shuffle.
create or replace function public.team_rules() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s public.sessions; closed boolean;
begin
  select * into s from public.sessions where id = new.session_id;
  closed := s.state = 'ended' or s.created_at <= clock_timestamp() - interval '3 hours'
    or (s.state = 'running' and s.ends_at <= clock_timestamp());
  if new.team_id is not null and not exists (
       select 1 from public.teams where id = new.team_id and session_id = new.session_id) then
    raise exception 'that team is not in this adventure';
  end if;
  if tg_op = 'INSERT' and s.state <> 'lobby' then
    raise exception 'the adventure has already started';
  end if;
  if tg_op = 'UPDATE' and new.team_id is distinct from old.team_id
     and (s.state <> 'lobby' or closed) then
    -- Only an actual deleted team may clear its old membership. A student
    -- cannot clear their own team to unlock a second choice (or old results).
    if new.team_id is null and not exists (select 1 from public.teams where id = old.team_id) then
      return new;
    end if;
    if old.team_id is not null or new.team_id is null or closed then
      raise exception 'teams are locked once the adventure starts';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists members_team_rules on public.members;
create trigger members_team_rules before insert or update on public.members
  for each row execute function public.team_rules();

-- Shuffle: everyone in the session dealt round the teams in a random order,
-- for when picking freely has put all the friends on one side. One statement,
-- so nobody is ever seen half-shuffled.
create or replace function public.shuffle_teams(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.owns_session(p_session) then
    raise exception 'only the teacher can shuffle teams';
  end if;
  if not exists (select 1 from public.sessions
                 where id = p_session and state = 'lobby') then
    raise exception 'teams are locked once the adventure starts';
  end if;
  with t as (select id, row_number() over (order by name) - 1 as k,
                    count(*) over () as n
               from public.teams where session_id = p_session),
       m as (select profile_id, row_number() over (order by random()) - 1 as r
               from public.members where session_id = p_session)
  update public.members mem
     set team_id = t.id
    from m, t
   where mem.session_id = p_session and mem.profile_id = m.profile_id
     and t.k = m.r % t.n;
end $$;

grant execute on function public.shuffle_teams(uuid) to authenticated;

-- 4d. Match finder (Level Up fork) ------------------------------------------
-- No teacher: a player presses Find Match and the server puts them in the
-- oldest open lobby, or opens one with two teams. Joiners are dealt onto the
-- smaller team and cannot switch. A match starts only when it is full
-- (team_size a side, so the teams are always even). A player still waiting
-- after `search_s` drops out of the queue ("no match found") and searches
-- again by hand. The clock is the session's as before, and a match ends by
-- itself: everyone done (`end_when_all_done`) or time up.
--
-- Nothing runs on the server by itself: lobby phones check in every few
-- seconds (`poll_match`), and that check-in is what starts a full match and
-- drops whoever stopped checking in -- a closed app, a dead phone -- or has
-- waited too long.
alter table public.sessions add column if not exists matchmade boolean not null default false;
alter table public.members add column if not exists queued_at timestamptz not null default now();

-- The knobs, one row, set in the dashboard. Nothing has to be set: the
-- defaults run a match.
create table if not exists public.match_config (
  id         int primary key default 1 check (id = 1),
  -- Players a side. Allow 1 v 1 for playtests; the default is still 3 v 3.
  team_size  int not null default 3 check (team_size between 1 and 5),
  -- How long one player waits for a full lobby before "no match found".
  search_s   int not null default 90 check (search_s between 15 and 600),
  duration_s int not null default 360 check (duration_s between 60 and 7200),
  -- Monks (words) per match; both teams play the same ones.
  monk_count int not null default 10 check (monk_count between 1 and 40)
);
-- Existing projects keep the old check when CREATE TABLE is skipped.
alter table public.match_config drop constraint if exists match_config_team_size_check;
alter table public.match_config add constraint match_config_team_size_check
  check (team_size between 1 and 5);
-- A project made before the search limit: `create table if not exists` skipped it.
alter table public.match_config add column if not exists
  search_s int not null default 90 check (search_s between 15 and 600);
alter table public.match_config add column if not exists
  monk_count int not null default 10 check (monk_count between 1 and 40);
insert into public.match_config (id) values (1) on conflict (id) do nothing;
-- Matches once belonged to a "house" admin account, for its question bank;
-- the words are the `words` table's now, and whoever opens a lobby owns it.
alter table public.match_config drop column if exists house;
alter table public.match_config enable row level security;
drop policy if exists read_match_config on public.match_config;
create policy read_match_config on public.match_config for select to authenticated using (true);

create or replace function public.is_matchmade(p_session uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select matchmade from public.sessions where id = p_session), false)
$$;

-- Out of the queue: a phone silent for 15s (gone), or a player who has
-- waited longer than search_s. Full: the match starts.
create or replace function numxventure_private.start_if_due(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.sessions; c public.match_config;
begin
  select * into s from public.sessions where id = p_session for update;
  if s is null or not s.matchmade or s.state <> 'lobby' then return; end if;
  select * into c from public.match_config where id = 1;
  delete from public.members
   where session_id = p_session
     and (updated_at < now() - interval '15 seconds'
          or queued_at < now() - make_interval(secs => c.search_s));
  if (select count(*) from public.members where session_id = p_session) >= 2 * c.team_size then
    update public.sessions
       set state = 'running', ends_at = now() + make_interval(secs => s.duration_s)
     where id = p_session;
  end if;
end $$;

create or replace function public.find_match() returns public.sessions
language plpgsql security definer set search_path = '' as $$
declare c public.match_config; s public.sessions; t uuid;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into c from public.match_config where id = 1;
  -- ponytail: one matchmaker at a time across the project, so two phones never
  -- open two half-empty lobbies. Per-lobby locks if a crowd ever queues at once.
  perform pg_advisory_xact_lock(hashtext('numxventure.find_match'));
  -- Already in a match still going (the app reopened, a second tap): that one.
  select s2.* into s from public.sessions s2
    join public.members m on m.session_id = s2.id and m.profile_id = auth.uid()
   where s2.matchmade and not m.finished and not m.eliminated
     and s2.created_at > now() - interval '3 hours'
     and (s2.state = 'lobby' or (s2.state = 'running' and s2.ends_at > now()))
   order by s2.created_at desc limit 1;
  if s.id is not null then return s; end if;

  select s2.* into s from public.sessions s2
   where s2.matchmade and s2.state = 'lobby' and s2.created_at > now() - interval '30 minutes'
     and (select count(*) from public.members m where m.session_id = s2.id) < 2 * c.team_size
   order by s2.created_at limit 1
   for update;
  if s.id is null then
    insert into public.sessions (admin_id, matchmade, duration_s)
    values (auth.uid(), true, c.duration_s) returning * into s;
    insert into public.teams (session_id, name) values (s.id, 'Blue'), (s.id, 'Red');
  end if;
  select t2.id into t from public.teams t2
    left join public.members m on m.team_id = t2.id
   where t2.session_id = s.id
   group by t2.id order by count(m.profile_id), random() limit 1;
  insert into public.members (session_id, team_id, profile_id) values (s.id, t, auth.uid());
  perform numxventure_private.start_if_due(s.id);
  select * into s from public.sessions where id = s.id;
  return s;
end $$;

-- A lobby phone's check-in, every few seconds: keeps its place (a write at
-- most every 5s, so a lobby is not a stream of row changes), and starts the
-- match if it is due. Session lock first, as every scoring call takes it.
-- Returns {session, queued, waited_s, search_s, players, needed}: `queued`
-- false means this player timed out (or went silent) and is out of the queue.
-- A status, not an error: raising would roll the removal back.
drop function if exists public.poll_match(uuid);
create or replace function public.poll_match(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.sessions; c public.match_config; m public.members;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  perform 1 from public.sessions where id = p_session for update;
  update public.members set updated_at = now()
   where session_id = p_session and profile_id = auth.uid()
     and updated_at < now() - interval '5 seconds';
  perform numxventure_private.start_if_due(p_session);
  select * into s from public.sessions where id = p_session;
  select * into c from public.match_config where id = 1;
  select * into m from public.members where session_id = p_session and profile_id = auth.uid();
  return jsonb_build_object(
    'session', to_jsonb(s) - 'question_bank',
    'queued', m.profile_id is not null,
    'waited_s', coalesce(extract(epoch from now() - m.queued_at)::int, 0),
    'search_s', c.search_s,
    'players', (select count(*) from public.members where session_id = p_session),
    'needed', 2 * c.team_size);
end $$;

-- Out of the queue before the match starts. After Start the row stays: the
-- result counts, as a teacher's class does.
create or replace function public.leave_match(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  perform 1 from public.sessions where id = p_session for update;
  delete from public.members m using public.sessions s
   where m.session_id = p_session and m.profile_id = auth.uid()
     and s.id = p_session and s.matchmade and s.state = 'lobby';
  perform numxventure_private.start_if_due(p_session);
end $$;

revoke all on function public.find_match() from public, anon;
revoke all on function public.poll_match(uuid) from public, anon;
revoke all on function public.leave_match(uuid) from public, anon;
grant execute on function public.find_match() to authenticated;
grant execute on function public.poll_match(uuid) to authenticated;
grant execute on function public.leave_match(uuid) to authenticated;

-- 4f. Custom rooms -----------------------------------------------------------
-- A player hosts a room for friends: the server makes it, with its code and
-- the two teams, the host on Blue. Friends join by the code and pick a side
-- themselves (join_team / own_member; team_rules locks sides at Start). Any
-- number a side, uneven too: the host starts it once both sides have
-- somebody. A room is not matchmade, so Find Match never fills one and the
-- global board leaves it out.
alter table public.sessions add column if not exists custom boolean not null default false;

create or replace function public.create_room() returns public.sessions
language plpgsql security definer set search_path = '' as $$
declare s public.sessions; d int;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select duration_s into d from public.match_config where id = 1;
  insert into public.sessions (admin_id, custom, duration_s)
  values (auth.uid(), true, coalesce(d, 360)) returning * into s;
  insert into public.teams (session_id, name) values (s.id, 'Blue'), (s.id, 'Red');
  insert into public.members (session_id, team_id, profile_id)
  select s.id, t.id, auth.uid() from public.teams t where t.session_id = s.id and t.name = 'Blue';
  return s;
end $$;

-- Definer implementations stay outside the Data API. The public wrappers
-- are invokers; every implementation authenticates and authorizes its caller.
create schema if not exists lakbayin_private;
revoke all on schema lakbayin_private from public, anon;
grant usage on schema lakbayin_private to authenticated;

-- Room lobby check-ins are authoritative. Take the session lock before
-- touching members, matching Start/Move/Shuffle's lock order.
create or replace function numxventure_private.clean_room(p_session uuid)
returns public.sessions language plpgsql security definer set search_path = '' as $$
declare s public.sessions; next_host uuid;
begin
  select * into s from public.sessions where id = p_session for update;
  if s.id is null or not s.custom or s.state <> 'lobby' then return s; end if;
  delete from public.members where session_id = p_session
    and updated_at < clock_timestamp() - interval '30 seconds';
  if not exists (select 1 from public.members where session_id = p_session and profile_id = s.admin_id) then
    select profile_id into next_host from public.members where session_id = p_session
      order by queued_at, profile_id limit 1;
    if next_host is null then
      update public.sessions set state = 'ended' where id = p_session returning * into s;
    else
      update public.sessions set admin_id = next_host where id = p_session returning * into s;
    end if;
  end if;
  return s;
end $$;
revoke all on function numxventure_private.clean_room(uuid) from public, anon, authenticated;

create or replace function lakbayin_private.poll_room(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.sessions; present boolean;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into s from public.sessions where id = p_session for update;
  if s.id is null or not s.custom then raise exception 'that room does not exist'; end if;
  select exists (select 1 from public.members where session_id = p_session and profile_id = auth.uid()) into present;
  if not present then return jsonb_build_object('member', false); end if;
  if s.state = 'lobby' then
    update public.members set updated_at = clock_timestamp()
      where session_id = p_session and profile_id = auth.uid()
      and updated_at < clock_timestamp() - interval '5 seconds';
    s := numxventure_private.clean_room(p_session);
  end if;
  return jsonb_build_object('member', true, 'session', to_jsonb(s) - 'question_bank',
    'roster', (select coalesce(jsonb_agg(jsonb_build_object('profile_id', m.profile_id,
      'team_id', m.team_id, 'username', p.username) order by m.queued_at, m.profile_id), '[]'::jsonb)
      from public.members m join public.profiles p on p.id = m.profile_id where m.session_id = p_session));
end $$;

create or replace function lakbayin_private.move_room_member(p_session uuid, p_profile uuid, p_team uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.sessions;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into s from public.sessions where id = p_session for update;
  if s.id is null or not s.custom or s.admin_id <> auth.uid() or not exists
    (select 1 from public.members where session_id=p_session and profile_id=auth.uid())
    then raise exception 'only the host can move players'; end if;
  if s.state <> 'lobby' then raise exception 'teams are locked once the adventure starts'; end if;
  if not exists (select 1 from public.teams where id = p_team and session_id = p_session) then
    raise exception 'that team is not in this room';
  end if;
  update public.members set team_id = p_team where session_id = p_session and profile_id = p_profile;
  if not found then raise exception 'that player is not in this room'; end if;
end $$;

create or replace function lakbayin_private.shuffle_room(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.sessions;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into s from public.sessions where id = p_session for update;
  if s.id is null or not s.custom or s.admin_id <> auth.uid() or not exists
    (select 1 from public.members where session_id=p_session and profile_id=auth.uid())
    then raise exception 'only the host can shuffle players'; end if;
  if s.state <> 'lobby' then raise exception 'teams are locked once the adventure starts'; end if;
  if (select count(*) from public.teams where session_id = p_session) <> 2 then raise exception 'the room needs two sides'; end if;
  with t as (select id, row_number() over (order by name) - 1 as k from public.teams where session_id = p_session),
       m as (select profile_id, row_number() over (order by random()) - 1 as k from public.members where session_id = p_session)
  update public.members mem set team_id = t.id from m,t
    where mem.session_id = p_session and mem.profile_id = m.profile_id and t.k = m.k % 2;
end $$;

create or replace function public.poll_room(p_session uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select lakbayin_private.poll_room(p_session) $$;
create or replace function public.move_room_member(p_session uuid, p_profile uuid, p_team uuid) returns void
language sql security invoker set search_path = '' as $$ select lakbayin_private.move_room_member(p_session,p_profile,p_team) $$;
create or replace function public.shuffle_room(p_session uuid) returns void
language sql security invoker set search_path = '' as $$ select lakbayin_private.shuffle_room(p_session) $$;

revoke all on function lakbayin_private.poll_room(uuid) from public, anon;
grant execute on function lakbayin_private.poll_room(uuid) to authenticated;
revoke all on function public.poll_room(uuid) from public, anon;
revoke all on function lakbayin_private.move_room_member(uuid,uuid,uuid) from public, anon;
grant execute on function lakbayin_private.move_room_member(uuid,uuid,uuid) to authenticated;
revoke all on function public.move_room_member(uuid,uuid,uuid) from public, anon;
revoke all on function lakbayin_private.shuffle_room(uuid) from public, anon;
grant execute on function lakbayin_private.shuffle_room(uuid) to authenticated;
revoke all on function public.shuffle_room(uuid) from public, anon;
grant execute on function public.poll_room(uuid) to authenticated;
grant execute on function public.move_room_member(uuid,uuid,uuid) to authenticated;
grant execute on function public.shuffle_room(uuid) to authenticated;

create or replace function public.start_room(p_session uuid) returns public.sessions
language plpgsql security definer set search_path = '' as $$
declare s public.sessions;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into s from public.sessions where id = p_session for update;
  if s.id is null or not s.custom then raise exception 'no such room'; end if;
  if s.admin_id <> auth.uid() then raise exception 'only the host can start the room'; end if;
  if s.state <> 'lobby' then raise exception 'the room has already started'; end if;
  update public.members set updated_at = clock_timestamp() where session_id = p_session and profile_id = auth.uid();
  s := numxventure_private.clean_room(p_session);
  if exists (select 1 from public.members where session_id = p_session and team_id is null) then
    raise exception 'everyone must pick a side first';
  end if;
  if (select count(distinct team_id) from public.members where session_id = p_session) < 2 then
    raise exception 'both sides need a player';
  end if;
  update public.sessions
     set state = 'running', ends_at = now() + make_interval(secs => s.duration_s)
   where id = p_session returning * into s;
  return s;
end $$;

-- Out of a room before Start. A host who leaves hands the room to whoever
-- joined first; the last one out closes it. After Start the row stays.
-- poll_room drops silent lobby phones and transfers hosting after 30 s.
create or replace function public.leave_room(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.sessions;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into s from public.sessions where id = p_session for update;
  if s.id is null or not s.custom or s.state <> 'lobby' then return; end if;
  delete from public.members where session_id = p_session and profile_id = auth.uid();
  if s.admin_id = auth.uid() then
    update public.sessions set admin_id = m.profile_id
      from (select profile_id from public.members where session_id = p_session
             order by queued_at, profile_id limit 1) m
     where id = p_session;
    if not found then
      update public.sessions set state = 'ended' where id = p_session;
    end if;
  end if;
end $$;

revoke all on function public.create_room() from public, anon;
revoke all on function public.start_room(uuid) from public, anon;
revoke all on function public.leave_room(uuid) from public, anon;
grant execute on function public.create_room() to authenticated;
grant execute on function public.start_room(uuid) to authenticated;
grant execute on function public.leave_room(uuid) to authenticated;

-- 4e. Monks and the Monastery (Lakbayin, DESIGN.md 3) -----------------------
-- Every monk holds a Filipino word; a player writes it in Baybayin. A correct
-- answer is carried, and counts only once deposited at the Monastery before
-- the clock runs out. Each monk is answered once per team; both teams get
-- the same words. The team that deposits every word first wins and ends the
-- match; otherwise the clock does, and the most deposits win.

-- The word list (supabase/words.sql, generated by game/tools/make_words.py).
-- Both spellings are accepted: `modern` writes a vowelless consonant with the
-- krus-kudlit, `traditional` leaves it out. Readable by every player: a
-- Baybayin spelling is a rule anyone can apply, so it is not a secret --
-- what the server guards is who answered what, and when.
create table if not exists public.words (
  id          serial primary key,
  word        text unique not null,
  meaning     text not null,
  syllables   int  not null,
  modern      text not null,
  traditional text not null
);
alter table public.words enable row level security;
drop policy if exists read_words on public.words;
create policy read_words on public.words for select to authenticated using (true);

-- Which word each monk holds in a match: drawn at Start, monks 0..n-1. Where
-- the monks stand comes from the session's seed, on every phone alike.
create table if not exists public.session_words (
  session_id uuid not null references public.sessions on delete cascade,
  monk       int  not null,
  word_id    int  not null references public.words,
  primary key (session_id, monk)
);
alter table public.session_words enable row level security;
drop policy if exists read_session_words on public.session_words;
create policy read_session_words on public.session_words for select to authenticated using (true);

-- A team's answer to a monk: who wrote it, when, and when it was deposited
-- (null while carried). One per team and monk.
create table if not exists public.monk_answers (
  session_id   uuid not null references public.sessions on delete cascade,
  team_id      uuid not null references public.teams on delete cascade,
  monk         int  not null,
  profile_id   uuid not null references public.profiles on delete cascade,
  answered_at  timestamptz not null default now(),
  deposited_at timestamptz,
  primary key (session_id, team_id, monk)
);
alter table public.monk_answers enable row level security;
drop policy if exists read_monk_answers on public.monk_answers;
create policy read_monk_answers on public.monk_answers for select to authenticated using (true);

-- A wrong answer locks that player out of that monk for 10s. Server only.
create table if not exists numxventure_private.monk_tries (
  session_id uuid not null references public.sessions on delete cascade,
  profile_id uuid not null references public.profiles on delete cascade,
  monk       int  not null,
  wrong_at   timestamptz not null,
  primary key (session_id, profile_id, monk)
);
alter table numxventure_private.monk_tries enable row level security;

alter table public.sessions add column if not exists winner_team uuid references public.teams on delete set null;

-- Start draws the words: monk_count of them, at random, the same for both teams.
create or replace function public.draw_words() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if new.state = 'running' and old.state = 'lobby' then
    select monk_count into n from public.match_config where id = 1;
    insert into public.session_words (session_id, monk, word_id)
    select new.id, (row_number() over ()) - 1, w.id
      from (select id from public.words order by random() limit coalesce(n, 10)) w
    on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists sessions_draw_words on public.sessions;
create trigger sessions_draw_words after update on public.sessions
  for each row execute function public.draw_words();

-- What a player typed, as the server compares it: no spaces, and the newer
-- pamudpod (U+1715) read as the krus-kudlit (U+1714) -- both cancel the vowel.
create or replace function public.baybayin_clean(p text) returns text
language sql immutable set search_path = '' as $$
  select replace(regexp_replace(coalesce(p, ''), '\s', '', 'g'), U&'\1715', U&'\1714')
$$;

-- Answer a monk: 'correct' (carried now), 'wrong' (locked out 10s), 'locked'
-- (still locked out), or 'taken' (your team already answered it). Running
-- matches only; the session lock serializes two teammates at one monk.
create or replace function public.answer_monk(p_session uuid, p_monk int, p_typed text)
returns text language plpgsql security definer set search_path = '' as $$
declare me public.members; w public.words; typed text := public.baybayin_clean(p_typed);
begin
  perform numxventure_private.running_session(p_session);
  select * into me from public.members where session_id = p_session and profile_id = auth.uid();
  if me is null or me.team_id is null then raise exception 'you are not in this match'; end if;
  select wd.* into w from public.session_words sw join public.words wd on wd.id = sw.word_id
   where sw.session_id = p_session and sw.monk = p_monk;
  if w is null then raise exception 'no such monk'; end if;
  if exists (select 1 from public.monk_answers
              where session_id = p_session and team_id = me.team_id and monk = p_monk) then
    return 'taken';
  end if;
  if exists (select 1 from numxventure_private.monk_tries
              where session_id = p_session and profile_id = auth.uid() and monk = p_monk
                and wrong_at > now() - interval '10 seconds') then
    return 'locked';
  end if;
  if typed in (w.modern, w.traditional) then
    insert into public.monk_answers (session_id, team_id, monk, profile_id)
    values (p_session, me.team_id, p_monk, auth.uid());
    return 'correct';
  end if;
  insert into numxventure_private.monk_tries values (p_session, auth.uid(), p_monk, now())
  on conflict (session_id, profile_id, monk) do update set wrong_at = excluded.wrong_at;
  return 'wrong';
end $$;

-- Deposit everything this player carries. Returns how many went in. When the
-- team has now deposited every monk, it has finished: it wins and the match
-- ends for everyone. After the clock, nothing is deposited (running_session).
create or replace function public.deposit(p_session uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare me public.members; n int; total int; done int;
begin
  perform numxventure_private.running_session(p_session);
  select * into me from public.members where session_id = p_session and profile_id = auth.uid();
  if me is null or me.team_id is null then raise exception 'you are not in this match'; end if;
  update public.monk_answers set deposited_at = now()
   where session_id = p_session and profile_id = auth.uid() and deposited_at is null;
  get diagnostics n = row_count;
  select count(*) into total from public.session_words where session_id = p_session;
  select count(*) into done from public.monk_answers
   where session_id = p_session and team_id = me.team_id and deposited_at is not null;
  if total > 0 and done >= total then
    update public.sessions set state = 'ended', winner_team = me.team_id
     where id = p_session and state = 'running';
  end if;
  return n;
end $$;

revoke all on function public.answer_monk(uuid, int, text) from public, anon;
revoke all on function public.deposit(uuid) from public, anon;
grant execute on function public.answer_monk(uuid, int, text) to authenticated;
grant execute on function public.deposit(uuid) to authenticated;

-- Standings (DESIGN.md 3.5): deposits first, then who reached that total
-- sooner -- the time of their last deposit. A finished team outranks all.
create or replace view public.team_standings with (security_invoker = on) as
  select t.session_id, t.id as team_id, t.name,
         count(a.deposited_at)::int as deposited,
         max(a.deposited_at)        as reached_at,
         (s.winner_team = t.id)     as finished
    from public.teams t
    join public.sessions s on s.id = t.session_id
    left join public.monk_answers a on a.team_id = t.id
   group by t.session_id, t.id, t.name, s.winner_team;

create or replace view public.player_standings with (security_invoker = on) as
  select m.session_id, m.profile_id, m.team_id,
         count(a.deposited_at)::int as deposited,
         max(a.deposited_at)        as reached_at
    from public.members m
    left join public.monk_answers a
      on a.session_id = m.session_id and a.profile_id = m.profile_id
   group by m.session_id, m.profile_id, m.team_id;
grant select on public.team_standings, public.player_standings to authenticated;

-- 5. Leaderboard ------------------------------------------------------------
-- The team's total is its members' gems less the two team penalties (SPECS
-- §4), which live here rather than in anybody's gems: -50 for each member who
-- was eliminated, and -25 for each member short of all 14 items once the
-- adventure is over (ended, or out of time while still marked running --
-- `Teams.expired()`'s rule). Summing gems alone charged neither.
create or replace view public.team_scores with (security_invoker = on) as
  select t.session_id, t.id as team_id, t.name,
         (coalesce(sum(m.gems), 0)
          - 50 * count(*) filter (where m.eliminated)
          - case when s.state = 'ended'
                      or (s.state = 'running' and s.ends_at <= now())
                 then 25 * count(*) filter (where m.items_done < 14)
                 else 0 end)::int      as gems,
         count(m.profile_id)::int      as members,
         -- The tiebreak: equal gems, the team whose first player finished sooner.
         min(m.finish_s)::int          as first_finish
  from public.teams t
  join public.sessions s on s.id = t.session_id
  left join public.members m on m.team_id = t.id
  group by t.session_id, t.id, t.name, s.state, s.ends_at;

-- The all-time board players see (client, 2026-09-27): every team of every
-- finished game, best first, the list growing as each game ends. A game is
-- finished once it is ended, or its clock has run out while still marked
-- running -- `Teams.expired()`'s rule, and the one `team_scores` charges the
-- -25 by, so every total here has its penalties in. Games are numbered in the
-- order they were played. Teams nobody played for are left out.
--
-- Every finished game counts for now. The client means to record only games
-- hosted by certain admins; that is a `where` on `s.admin_id` here, when it
-- comes.
create or replace view public.team_results with (security_invoker = on) as
  with done as (
    select s.id, s.created_at, coalesce(s.ended_at, s.ends_at) as ended_at,
           row_number() over (order by s.created_at, s.id) as game_no
      from public.sessions s
     where s.state = 'ended' or (s.state = 'running' and s.ends_at <= now())
  )
  select ts.team_id, ts.session_id, ts.name, ts.gems, ts.members,
         done.game_no::int as game_no, done.created_at as played_at,
         (select coalesce(array_agg(m.profile_id order by m.profile_id), '{}')
            from public.members m where m.team_id = ts.team_id) as player_ids
    from public.team_scores ts
    join done on done.id = ts.session_id
   where ts.members > 0;

-- Said outright, not left to Supabase's default privileges on `public`.
grant select on public.team_results to authenticated;

-- 6. Row level security -----------------------------------------------------
alter table public.profiles  enable row level security;
alter table public.sessions  enable row level security;
alter table public.teams     enable row level security;
alter table public.members   enable row level security;
alter table public.questions enable row level security;

-- Every policy is dropped first so this file can be pasted over itself.
drop policy if exists read_profiles  on public.profiles;
drop policy if exists read_sessions  on public.sessions;
drop policy if exists read_teams     on public.teams;
drop policy if exists read_members   on public.members;
drop policy if exists read_questions on public.questions;
drop policy if exists own_profile    on public.profiles;
drop policy if exists admin_sessions on public.sessions;
drop policy if exists admin_teams    on public.teams;
drop policy if exists admin_questions on public.questions;
drop policy if exists join_team      on public.members;
drop policy if exists own_member     on public.members;
drop policy if exists admin_members  on public.members;
drop policy if exists admin_remove_lobby_member on public.members;

-- One teacher per session, and teachers never reach into each other's (client,
-- 2026-10-09, SPECS §11 Q12): a teacher reads and changes only the sessions
-- they made, their teams and their players, and their own question bank.
-- Players still read every session -- a class finds its own by the code before
-- joining -- and every finished game, for the all-time board.
create or replace function public.owns_session(p_session uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_admin() and exists (select 1 from public.sessions
                                        where id = p_session and admin_id = auth.uid())
$$;

-- Everyone signed in can read; the leaderboard is the whole point.
create policy read_profiles  on public.profiles  for select to authenticated using (true);
create policy read_sessions  on public.sessions  for select to authenticated
  using (not public.is_admin() or admin_id = auth.uid());
create policy read_teams     on public.teams     for select to authenticated
  using (not public.is_admin() or public.owns_session(session_id));
create policy read_members   on public.members   for select to authenticated
  using (not public.is_admin() or public.owns_session(session_id));
create policy read_questions on public.questions for select to authenticated
  using ((active and not public.is_admin()) or owner = auth.uid());

-- A player owns their hero and display name, never their own role -- the
-- subquery pins `role` to whatever it already is, so a PATCH cannot promote.
create policy own_profile on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid()
              and role = (select role from public.profiles where id = auth.uid()));

-- The teacher owns the clock, the teams and the bank -- their own.
create policy admin_sessions  on public.sessions  for all to authenticated
  using (public.is_admin() and admin_id = auth.uid())
  with check (public.is_admin() and admin_id = auth.uid());
create policy admin_teams     on public.teams     for all to authenticated
  using (public.owns_session(session_id)) with check (public.owns_session(session_id));
create policy admin_questions on public.questions for all to authenticated
  using (public.is_admin() and owner = auth.uid())
  with check (public.is_admin() and owner = auth.uid());

-- Joining a team is the player's own act -- except in a match, where
-- `find_match` deals the teams and a direct insert or switch would unbalance them.
create policy join_team on public.members for insert to authenticated
  with check (profile_id = auth.uid() and not public.is_matchmade(session_id));

-- A player owns their own row, but NOT its score: RLS cannot restrict columns,
-- so the column privileges do it. Everything to do with gems is writable only
-- by the `security definer` functions above, which run as the owner.
create policy own_member on public.members for update to authenticated
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid() and not public.is_matchmade(session_id));

-- The teacher's Move: another player's team, and nothing else of their row.
create policy admin_members on public.members for update to authenticated
  using (public.owns_session(session_id)) with check (public.owns_session(session_id));

-- The teacher may remove a player only while teams are still being formed.
-- Once Start changes the session state, this policy filters every DELETE out,
-- even if an old confirmation dialog is still open on the teacher's screen.
-- Lock the session until the DELETE commits. Start updates that same row:
-- whichever request arrives second waits and rechecks the committed state.
create policy admin_remove_lobby_member on public.members for delete to authenticated
  using (public.owns_session(session_id)
         and exists (select 1 from public.sessions s
                      where s.id = members.session_id and s.state = 'lobby'
                      for update of s));

revoke update on public.members from authenticated;
grant update (team_id) on public.members to authenticated;
-- Joining writes who joined which team, nothing else: the column grant above
-- holds updates only, and a join that set its own gems or `finished` would
-- otherwise go straight in. Gems start at the column default.
revoke insert on public.members from authenticated;
grant insert (session_id, team_id, profile_id) on public.members to authenticated;
-- DELETE is row-limited by `admin_remove_lobby_member`: players and other
-- teachers receive no matching row, and the session owner loses it at Start.
revoke delete on public.members from anon, authenticated;
grant delete on public.members to authenticated;

-- 7. Realtime ---------------------------------------------------------------
-- Why Supabase and not plain REST: the pause and the live leaderboard arrive
-- without anyone polling. Adding a table twice is an error, hence the guard.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'sessions') then
    alter publication supabase_realtime add table public.sessions;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'members') then
    alter publication supabase_realtime add table public.members;
  end if;
  -- Game Controls watches teams so a rename or a removal shows at once; it
  -- was subscribed all along and never sent anything, since the table was
  -- not published.
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'teams') then
    alter publication supabase_realtime add table public.teams;
  end if;
  -- A teammate's answer greys that monk out on every phone of the team, and
  -- the scoreline moves with each deposit (AdventureScreen._on_row).
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'monk_answers') then
    alter publication supabase_realtime add table public.monk_answers;
  end if;
end $$;

-- 7b. Movement relay ---------------------------------------------------------
-- Where the movement relay is (game/scripts/relay/RelayServer.gd, started by
-- game/tools/relay/run.sh). One row: the relay writes its address on start
-- (a Cloudflare quick tunnel's changes on every restart), refreshes
-- `updated_at` every minute, and clears `url` when it stops. Phones read it
-- when they enter a session; no row, no url or a stale one means today's
-- path through the teacher. Safe to run again on a live project.
create table if not exists public.relay (
  id          int primary key default 1 check (id = 1),
  url         text,
  hz          int,
  updated_at  timestamptz not null default now()
);
alter table public.relay enable row level security;
drop policy if exists read_relay  on public.relay;
drop policy if exists admin_relay on public.relay;
create policy read_relay  on public.relay for select to authenticated using (true);
create policy admin_relay on public.relay for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Two machines can run a relay -- the home laptop, and the teacher's Game
-- Controls as its backup (game/scripts/relay/RelayHost.gd) -- but a class must
-- all be on one, or it splits into two halves that cannot see each other. So
-- the row has an owner. A relay takes it only when it is free (no url),
-- stale (not refreshed for 180s, the phones' RelayLink.STALE_S) or already
-- its own, and keeps it by refreshing it; nobody takes it back from a relay
-- that is still refreshing. Rows from before owners (owner null) are free.
-- Both run as the caller, so the admin-only policy above still decides.
alter table public.relay add column if not exists owner text;
insert into public.relay (id) values (1) on conflict (id) do nothing;

-- True if p_owner holds the row now (and it says p_url).
create or replace function public.claim_relay(p_owner text, p_url text, p_hz int)
returns boolean language sql as $$
  with taken as (
    update public.relay
       set owner = p_owner, url = p_url, hz = p_hz, updated_at = now()
     where id = 1
       and (owner is null or owner = p_owner or url is null
            or updated_at < now() - interval '180 seconds')
    returning 1)
  select exists (select 1 from taken)
$$;

-- Lets the row go, if it is p_owner's: the next relay to ask gets it at once.
create or replace function public.release_relay(p_owner text)
returns void language sql as $$
  update public.relay set url = null, hz = 0, updated_at = now()
   where id = 1 and owner = p_owner
$$;

-- 7c. Relay tickets ----------------------------------------------------------
-- A phone used to say hello to the relay with its sign-in token, and the relay
-- checked it with Supabase. Whoever ran a relay -- and any admin can publish
-- one, or host the backup -- then held every phone's token for an hour. Now
-- the phone asks for a ticket here, "this player may join this session", and
-- the relay redeems it with its own login. A ticket opens nothing but the
-- relay, so a relay that keeps one has nothing to use it on.
create table if not exists public.relay_tickets (
  ticket     uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles on delete cascade,
  session_id uuid not null references public.sessions on delete cascade,
  role       text not null check (role in ('player', 'teacher')),
  made_at    timestamptz not null default now()
);
alter table public.relay_tickets enable row level security;   -- no policies: the two functions only

-- A ticket for a member of the session (player) or its own teacher.
create or replace function public.relay_ticket(p_session uuid, p_role text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  t uuid;
begin
  if p_role = 'player' then
    if not exists (select 1 from public.members
                   where session_id = p_session and profile_id = auth.uid()) then
      raise exception 'you are not in this adventure';
    end if;
  elsif p_role = 'teacher' then
    if not public.owns_session(p_session) then
      raise exception 'not your session';
    end if;
  else
    raise exception 'no such role';
  end if;
  delete from public.relay_tickets where made_at < now() - interval '1 day';
  insert into public.relay_tickets (profile_id, session_id, role)
  values (auth.uid(), p_session, p_role)
  returning ticket into t;
  return t;
end $$;

-- Whose ticket, if it is for that session and role and under an hour old;
-- null otherwise. Relays sign in as admins (relayserver, or the teacher's
-- Game Controls), so only an admin may ask.
create or replace function public.relay_redeem(p_ticket uuid, p_session uuid, p_role text) returns uuid
language sql stable security definer set search_path = '' as $$
  select profile_id from public.relay_tickets
   where public.is_admin() and ticket = p_ticket and session_id = p_session
     and role = p_role and made_at > now() - interval '1 hour'
$$;

grant execute on function public.relay_ticket(uuid, text) to authenticated;
grant execute on function public.relay_redeem(uuid, uuid, text) to authenticated;

-- 7d. A relay per class -------------------------------------------------------
-- The teacher's Game Controls hosts the relay for its own class (client,
-- 2026-10-09): the home laptop cannot be counted on to be on, the teacher's is
-- there whenever a class is. Its address goes here, for that session only,
-- refreshed every 30s. A class with none, or a stale one, uses the shared row
-- above (the home relay, when it is on) and failing that the hub. Only the
-- session's own teacher can set it, so nobody points another class anywhere.
create table if not exists public.session_relays (
  session_id uuid primary key references public.sessions on delete cascade,
  url        text not null check (url ~ '^wss://'),
  hz         int  not null default 20,
  updated_at timestamptz not null default now()
);
alter table public.session_relays enable row level security;

drop policy if exists read_session_relay on public.session_relays;
drop policy if exists own_session_relay  on public.session_relays;
-- Its teacher and its own players read it; nobody else needs to.
create policy read_session_relay on public.session_relays for select to authenticated
  using (public.owns_session(session_id)
         or exists (select 1 from public.members m
                     where m.session_id = session_relays.session_id and m.profile_id = auth.uid()));
create policy own_session_relay on public.session_relays for all to authenticated
  using (public.owns_session(session_id)) with check (public.owns_session(session_id));

-- Security invoker, as the relay row's: the policies above decide. The time is
-- the server's, which is what the phones judge staleness by.
create or replace function public.host_relay(p_session uuid, p_url text, p_hz int)
returns void language sql as $$
  insert into public.session_relays (session_id, url, hz, updated_at)
  values (p_session, p_url, p_hz, now())
  on conflict (session_id) do update set url = excluded.url, hz = excluded.hz, updated_at = now()
$$;

create or replace function public.unhost_relay(p_session uuid)
returns void language sql as $$
  delete from public.session_relays where session_id = p_session
$$;

grant execute on function public.host_relay(uuid, text, int) to authenticated;
grant execute on function public.unhost_relay(uuid) to authenticated;

-- 7b. Read-only event spectators --------------------------------------------
-- A watcher has a short lease, never a members row. Only the authenticated
-- RPCs write it; movement authorization permits receiving snapshots only.
create table if not exists public.match_watchers (
  session_id uuid not null references public.sessions on delete cascade,
  profile_id uuid not null references public.profiles on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (session_id, profile_id)
);
alter table public.match_watchers enable row level security;
revoke all on public.match_watchers from anon, authenticated;
grant select on public.match_watchers to authenticated;
drop policy if exists own_watch on public.match_watchers;
create policy own_watch on public.match_watchers for select to authenticated
  using (profile_id = (select auth.uid()));

create or replace function lakbayin_private.watch_match(p_code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  if auth.uid() is null then raise exception 'sign in to watch'; end if;
  select id into sid from public.sessions
    where code = upper(trim(p_code)) and (custom or matchmade)
      and state in ('lobby','running') and created_at > now() - interval '3 hours'
      and (ends_at is null or ends_at > now())
    order by created_at desc limit 1;
  if sid is null then raise exception 'no live match with that code'; end if;
  if exists (select 1 from public.members where session_id = sid and profile_id = auth.uid())
    then raise exception 'players cannot watch their own match'; end if;
  insert into public.match_watchers(session_id,profile_id) values(sid,auth.uid())
    on conflict (session_id,profile_id) do update set seen_at = now();
  return sid;
end $$;

create or replace function lakbayin_private.watch_snapshot(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.sessions; n int;
begin
  if auth.uid() is null then raise exception 'sign in to watch'; end if;
  update public.match_watchers set seen_at = now()
    where session_id = p_session and profile_id = auth.uid()
      and seen_at > now() - interval '30 seconds';
  if not found then raise exception 'watch expired; enter the code again'; end if;
  if exists (select 1 from public.members where session_id = p_session and profile_id = auth.uid())
    then raise exception 'players cannot watch their own match'; end if;
  select * into s from public.sessions where id = p_session;
  select count(*) into n from public.session_words where session_id = p_session;
  if n = 0 then select monk_count into n from public.match_config where id = 1; end if;
  return jsonb_build_object(
    'session', jsonb_build_object('id',s.id,'code',s.code,'state',s.state,'ends_at',s.ends_at,
      'duration_s',s.duration_s,'winner_team',s.winner_team,'server_now',now()), 'monks', n,
    'teams', coalesce((select jsonb_agg(to_jsonb(t) order by t.name) from (
      select ts.team_id as id, ts.name, ts.deposited, ts.reached_at,
        (select count(*) from public.monk_answers a where a.team_id = ts.team_id and a.deposited_at is null) as carried
      from public.team_standings ts where ts.session_id = p_session) t),'[]'::jsonb),
    'players', coalesce((select jsonb_agg(to_jsonb(p) order by p.username) from (
      select m.profile_id, m.team_id, pr.username, pr.hero,
        count(a.answered_at) filter (where a.deposited_at is null)::int as carried,
        count(a.deposited_at)::int as deposited
      from public.members m join public.profiles pr on pr.id = m.profile_id
      left join public.monk_answers a on a.session_id = m.session_id and a.profile_id = m.profile_id
      where m.session_id = p_session group by m.profile_id,m.team_id,pr.username,pr.hero) p),'[]'::jsonb),
    'answers', coalesce((select jsonb_agg(jsonb_build_object('monk',monk,'team_id',team_id,
      'deposited',deposited_at is not null)) from public.monk_answers where session_id = p_session),'[]'::jsonb));
end $$;

create or replace function lakbayin_private.leave_watch(p_session uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.match_watchers where session_id = p_session and profile_id = auth.uid()
$$;
create or replace function public.watch_match(p_code text) returns uuid
language sql security invoker set search_path = '' as $$ select lakbayin_private.watch_match(p_code) $$;
create or replace function public.watch_snapshot(p_session uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select lakbayin_private.watch_snapshot(p_session) $$;
create or replace function public.leave_watch(p_session uuid) returns void
language sql security invoker set search_path = '' as $$ select lakbayin_private.leave_watch(p_session) $$;
revoke all on function public.watch_match(text), public.watch_snapshot(uuid), public.leave_watch(uuid),
  lakbayin_private.watch_match(text), lakbayin_private.watch_snapshot(uuid), lakbayin_private.leave_watch(uuid) from public, anon;
grant execute on function public.watch_match(text), public.watch_snapshot(uuid), public.leave_watch(uuid),
  lakbayin_private.watch_match(text), lakbayin_private.watch_snapshot(uuid), lakbayin_private.leave_watch(uuid) to authenticated;

-- Movement broadcasts use private channels. A player's input topic belongs
-- to that player; only the session's teacher may publish its snapshots.
create or replace function public.can_use_movement(p_topic text, p_send boolean)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare parts text[]; sid uuid; teacher boolean; member boolean;
begin
  if auth.uid() is null then return false; end if;
  parts := string_to_array(regexp_replace(p_topic, '^realtime:', ''), ':');
  if parts[1] <> 'numxventure' or parts[2] not in ('in', 'snap')
     or coalesce(parts[3], '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or array_length(parts, 1) <> (case when parts[2] = 'in' then 4 else 3 end) then
    return false;
  end if;
  sid := parts[3]::uuid;
  teacher := public.owns_session(sid);
  member := exists (select 1 from public.members where session_id = sid and profile_id = auth.uid());
  if parts[2] = 'snap' then
    -- A match has no teacher to gather positions: each member publishes its
    -- own on the snapshot channel instead (AdventureScreen, the direct path).
    return (not p_send and exists (select 1 from public.match_watchers
      where session_id = sid and profile_id = auth.uid() and seen_at > now() - interval '30 seconds'))
      or teacher or (member and (not p_send or public.is_matchmade(sid)
      or exists (select 1 from public.sessions where id = sid and custom)));
  end if;
  return (not p_send and teacher) or (member and parts[4] = auth.uid()::text);
end $$;
revoke all on function public.can_use_movement(text, boolean) from public, anon;
grant execute on function public.can_use_movement(text, boolean) to authenticated;

-- Supabase owns realtime.messages and already enables RLS. Only policies
-- belong here; ALTER TABLE would fail on hosted Supabase.
drop policy if exists movement_receive on realtime.messages;
drop policy if exists movement_send on realtime.messages;
create policy movement_receive on realtime.messages for select to authenticated
  using (extension = 'broadcast' and public.can_use_movement((select realtime.topic()), false));
create policy movement_send on realtime.messages for insert to authenticated
  with check (extension = 'broadcast' and public.can_use_movement((select realtime.topic()), true));

-- 8. Reset (commented out on purpose) ---------------------------------------
-- Uncomment, run, then run this file again for a clean slate. Deletes every
-- row. Accounts live in auth.users and survive -- delete those in the
-- dashboard first, or they come back with no profile and the trigger will not
-- fire for them again.
--
-- drop view  if exists public.team_scores;
-- drop table if exists public.members, public.teams, public.sessions,
--                      public.questions, public.profiles cascade;
-- drop function if exists public.handle_new_user() cascade;
-- drop function if exists public.is_admin();

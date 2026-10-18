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
     set gems = gems + case when p_correct then 10 else -5 end,
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
     set gems = gems - 5, hints_used = hints_used + 1, item_used_hint = true,
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
     set gems = gems - 15, items_done = items_done + 1, skipped = skipped + 1,
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
  update public.members
     set finished = true,
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
         count(m.profile_id)::int      as members
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

-- Joining a team is the player's own act.
create policy join_team on public.members for insert to authenticated
  with check (profile_id = auth.uid());

-- A player owns their own row, but NOT its score: RLS cannot restrict columns,
-- so the column privileges do it. Everything to do with gems is writable only
-- by the `security definer` functions above, which run as the owner.
create policy own_member on public.members for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- The teacher's Move: another player's team, and nothing else of their row.
create policy admin_members on public.members for update to authenticated
  using (public.owns_session(session_id)) with check (public.owns_session(session_id));

revoke update on public.members from authenticated;
grant update (team_id) on public.members to authenticated;
-- Joining writes who joined which team, nothing else: the column grant above
-- holds updates only, and a join that set its own gems or `finished` would
-- otherwise go straight in. Gems start at the column default.
revoke insert on public.members from authenticated;
grant insert (session_id, team_id, profile_id) on public.members to authenticated;

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
    return teacher or (not p_send and member);
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

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

create or replace function public.apply_answer(p_session uuid, p_correct boolean)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare
  row public.members;
begin
  if not exists (select 1 from public.sessions
                 where id = p_session and state = 'running') then
    raise exception 'the adventure is not running';
  end if;
  update public.members
     set gems       = gems + case when p_correct then 10 else -5 end,
         correct    = correct + case when p_correct then 1 else 0 end,
         items_done = items_done + 1,
         updated_at = now()
   where session_id = p_session and profile_id = auth.uid()
  returning * into row;
  if row is null then
    raise exception 'you are not in this adventure';
  end if;
  return row;
end $$;

create or replace function public.spend_hint(p_session uuid)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare
  row public.members;
begin
  if not exists (select 1 from public.sessions
                 where id = p_session and state = 'running') then
    raise exception 'the adventure is not running';
  end if;
  update public.members
     set gems = gems - 5, updated_at = now()
   where session_id = p_session and profile_id = auth.uid()
  returning * into row;
  return row;
end $$;

create or replace function public.skip_item(p_session uuid)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare
  row public.members;
begin
  if not exists (select 1 from public.sessions
                 where id = p_session and state = 'running') then
    raise exception 'the adventure is not running';
  end if;
  update public.members
     set gems = gems - 15, items_done = items_done + 1,
         updated_at = now()
   where session_id = p_session and profile_id = auth.uid()
  returning * into row;
  return row;
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

-- Once per station, and only once its circles are done. Without the counter a
-- client could call this with p_perfect = true as often as it liked, +10 each
-- time. `stations_done` indexes the cumulative item counts (8/3/3 ->
-- 8, 11, 14; `Game.ITEMS_PER_STATION`), so station n pays out only when
-- items_done has reached its last circle. Not gated on `running`: the bonus
-- is earned by the answers, which already were.
alter table public.members add column if not exists
  stations_done int not null default 0;

create or replace function public.finish_station(p_session uuid, p_perfect boolean)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare
  row public.members;
begin
  update public.members
     set gems = gems + case when p_perfect then 10 else 0 end,
         stations_done = stations_done + 1,
         updated_at = now()
   where session_id = p_session and profile_id = auth.uid()
     and items_done >= (array[8, 11, 14])[stations_done + 1]
  returning * into row;
  if row is null then
    raise exception 'that station is not finished';
  end if;
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

-- Rescue: -10 from the sender, +10 to the receiver, both in one statement so a
-- failure cannot create or destroy gems (SPECS §4, and the paper's "A teammate
-- will be allowed to transfer 10 gems to assist one member only").
--
-- One assist per sender per adventure, which is what "one member only" means,
-- enforced by `rescued_at` rather than trusted to the client. You cannot
-- rescue yourself, someone on another team, or someone already eliminated --
-- the -50 has been taken and refunding it would make elimination negotiable.
alter table public.members add column if not exists rescued_at timestamptz;

create or replace function public.rescue(p_session uuid, p_to uuid)
returns public.members
language plpgsql security definer set search_path = '' as $$
declare
  giver public.members;
  taker public.members;
begin
  if not exists (select 1 from public.sessions
                 where id = p_session and state = 'running') then
    raise exception 'the adventure is not running';
  end if;
  select * into giver from public.members
   where session_id = p_session and profile_id = auth.uid();
  if giver is null then
    raise exception 'you are not in this adventure';
  end if;
  if giver.rescued_at is not null then
    raise exception 'you have already sent a rescue';
  end if;
  if giver.profile_id = p_to then
    raise exception 'you cannot rescue yourself';
  end if;
  if giver.gems < 10 then
    raise exception 'you need 10 gems to send a rescue';
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

  update public.members set gems = gems - 10, rescued_at = now(), updated_at = now()
   where session_id = p_session and profile_id = auth.uid();
  update public.members set gems = gems + 10, updated_at = now()
   where session_id = p_session and profile_id = p_to
  returning * into taker;
  return taker;
end $$;

grant execute on function public.rescue(uuid, uuid) to authenticated;

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
  select * into s from public.sessions where id = p_session;
  if s is null or s.state <> 'running' then
    raise exception 'the adventure is not running';
  end if;
  update public.members
     set finished = true,
         finish_s = coalesce(finish_s, greatest(0, s.duration_s
                      - greatest(0, ceil(extract(epoch from (s.ends_at - now())))::int))),
         updated_at = now()
   where session_id = p_session and profile_id = auth.uid() and stations_done >= 3
  returning * into row;
  if row is null then
    raise exception 'the adventure is not finished';
  end if;
  return row;
end $$;

grant execute on function public.finish_run(uuid) to authenticated;

grant execute on function public.apply_answer(uuid, boolean) to authenticated;
grant execute on function public.spend_hint(uuid) to authenticated;
grant execute on function public.skip_item(uuid) to authenticated;
grant execute on function public.finish_station(uuid, boolean) to authenticated;

-- 4c. Picking a team ---------------------------------------------------------
-- Students pick their own team in the lobby and may switch until the teacher
-- presses Start; from then on teams are locked, or a player could carry their
-- gems over to whichever side is winning. The one exception is somebody with
-- no team -- never picked, or theirs was removed -- who may always pick one.
-- The same rule binds the teacher's Move and Shuffle.
create or replace function public.team_rules() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.team_id is not null and not exists (
       select 1 from public.teams where id = new.team_id and session_id = new.session_id) then
    raise exception 'that team is not in this adventure';
  end if;
  -- Nobody new once it has started, the way a match that has begun takes no
  -- one from the queue. A rejoin is an existing row, never an insert.
  if tg_op = 'INSERT' and exists (select 1 from public.sessions
                                  where id = new.session_id and state <> 'lobby') then
    raise exception 'the adventure has already started';
  end if;
  if tg_op = 'UPDATE' and new.team_id is distinct from old.team_id
     and old.team_id is not null and new.team_id is not null
     and exists (select 1 from public.sessions
                 where id = new.session_id and state <> 'lobby') then
    raise exception 'teams are locked once the adventure starts';
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
  if not public.is_admin() then
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

-- Everyone signed in can read; the leaderboard is the whole point.
create policy read_profiles  on public.profiles  for select to authenticated using (true);
create policy read_sessions  on public.sessions  for select to authenticated using (true);
create policy read_teams     on public.teams     for select to authenticated using (true);
create policy read_members   on public.members   for select to authenticated using (true);
create policy read_questions on public.questions for select to authenticated
  using (active or public.is_admin());

-- A player owns their hero and display name, never their own role -- the
-- subquery pins `role` to whatever it already is, so a PATCH cannot promote.
create policy own_profile on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid()
              and role = (select role from public.profiles where id = auth.uid()));

-- The teacher owns the clock, the teams and the bank.
create policy admin_sessions  on public.sessions  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy admin_teams     on public.teams     for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy admin_questions on public.questions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

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
  using (public.is_admin()) with check (public.is_admin());

revoke update on public.members from authenticated;
grant update (team_id) on public.members to authenticated;

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

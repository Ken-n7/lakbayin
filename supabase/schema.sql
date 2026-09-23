-- NumXventure — Supabase schema.
-- Paste into the SQL Editor of a fresh project, or `supabase db push`.
-- Auth is Supabase's own: usernames are shimmed onto emails (see README).

-- 1. Profiles ---------------------------------------------------------------
-- auth.users holds the credentials. This is everything the game shows.
create table public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  username   text unique not null check (username ~ '^[A-Za-z0-9_-]{3,20}$'),
  role       text not null default 'player' check (role in ('player','admin')),
  hero       int  not null default 0,
  created_at timestamptz not null default now()
);

-- A row appears the moment someone signs up; the client never inserts it.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username, role)
  values (new.id,
          new.raw_user_meta_data->>'username',
          coalesce(new.raw_user_meta_data->>'role', 'player'));
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin')
$$;

-- 2. Sessions ---------------------------------------------------------------
-- One live adventure. The clock lives here so every phone reads the same one:
-- `ends_at` while running, `remaining_s` while paused.
create table public.sessions (
  id          uuid primary key default gen_random_uuid(),
  admin_id    uuid not null references public.profiles on delete cascade,
  duration_s  int  not null default 600 check (duration_s between 60 and 7200),
  state       text not null default 'lobby'
              check (state in ('lobby','running','paused','ended')),
  ends_at     timestamptz,
  remaining_s int,
  created_at  timestamptz not null default now()
);

-- 3. Teams and members ------------------------------------------------------
-- The team name IS the join code, so it is unique within its session.
create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions on delete cascade,
  name       text not null,
  unique (session_id, name)
);

create table public.members (
  session_id uuid not null references public.sessions on delete cascade,
  team_id    uuid not null references public.teams    on delete cascade,
  profile_id uuid not null references public.profiles on delete cascade,
  gems       int  not null default 50,
  correct    int  not null default 0,
  items_done int  not null default 0,
  eliminated boolean not null default false,
  finished   boolean not null default false,
  primary key (team_id, profile_id),
  unique (session_id, profile_id)   -- one team per player per adventure
);

-- 4. Question bank ----------------------------------------------------------
-- Empty is fine: QuestionGen still fills any station short of active items.
create table public.questions (
  id       uuid primary key default gen_random_uuid(),
  station  int  not null check (station between 1 and 3),
  prompt   text not null,
  answer   text not null,
  hint     text not null default '',
  feedback text not null default '' check (char_length(feedback) <= 300),
  active   boolean not null default true
);

-- 5. Leaderboard ------------------------------------------------------------
create view public.team_scores with (security_invoker = on) as
  select t.session_id, t.id as team_id, t.name,
         coalesce(sum(m.gems), 0)::int as gems,
         count(m.profile_id)::int      as members
  from public.teams t
  left join public.members m on m.team_id = t.id
  group by t.session_id, t.id, t.name;

-- 6. Row level security -----------------------------------------------------
alter table public.profiles  enable row level security;
alter table public.sessions  enable row level security;
alter table public.teams     enable row level security;
alter table public.members   enable row level security;
alter table public.questions enable row level security;

-- Everyone signed in can read; the leaderboard is the whole point.
create policy read_profiles  on public.profiles  for select to authenticated using (true);
create policy read_sessions  on public.sessions  for select to authenticated using (true);
create policy read_teams     on public.teams     for select to authenticated using (true);
create policy read_members   on public.members   for select to authenticated using (true);
create policy read_questions on public.questions for select to authenticated
  using (active or public.is_admin());

create policy own_profile on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid() and role = (select role from public.profiles where id = auth.uid()));

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

-- ponytail: a player can still write their own gems, which trusts the client's
-- arithmetic -- the one thing SPECS §10 Phase 4 says not to do. The fix is a
-- `security definer` rpc (apply_answer / spend_hint / skip_item) that does the
-- sum in Postgres, after which this policy drops to `finished` and `hero` only.
create policy own_member on public.members for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- 7. Realtime ---------------------------------------------------------------
-- Why Supabase and not plain REST: the pause and the live leaderboard arrive
-- without anyone polling.
alter publication supabase_realtime add table public.sessions, public.members;

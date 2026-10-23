-- Server-derived history and matchmade-only player board.
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
select pg_temp.uid(n),'r'||n||'@t.dev',jsonb_build_object('username','record'||n) from generate_series(1,4) n;
update public.match_config set monk_count=3;
create function pg_temp.side(s uuid,n text) returns uuid language sql as $$ select id from public.teams where session_id=s and name=n $$;
create function pg_temp.game(is_custom boolean, mode text default 'ended') returns uuid language plpgsql as $$
declare s uuid;
begin
 s:=pg_temp.as_player(pg_temp.uid(1),'select (public.create_room()).id::text')::uuid;
 perform pg_temp.as_player(pg_temp.uid(2),format('insert into public.members(session_id,profile_id,team_id) values(%L,%L,%L) returning 1',s,pg_temp.uid(2),pg_temp.side(s,'Red')));
 perform pg_temp.as_player(pg_temp.uid(3),format('insert into public.members(session_id,profile_id,team_id) values(%L,%L,%L) returning 1',s,pg_temp.uid(3),pg_temp.side(s,'Blue')));
 if mode<>'lobby' then
  perform pg_temp.as_player(pg_temp.uid(1),format('select public.start_room(%L)',s));
  if mode='ended' then update public.sessions set state='ended' where id=s;
  elsif mode='expired' then update public.sessions set ends_at=now()-interval '1 second' where id=s; end if;
 end if;
 update public.sessions set custom=is_custom,matchmade=not is_custom where id=s;
 return s;
end $$;
create function pg_temp.answer(s uuid,person int,monk int,at_time timestamptz) returns void language sql as $$
 insert into public.monk_answers(session_id,team_id,monk,profile_id,deposited_at)
 select s,team_id,monk,profile_id,at_time from public.members where session_id=s and profile_id=pg_temp.uid(person) $$;
do $$
declare s uuid;c uuid;l uuid;d uuid;t uuid;f uuid;g jsonb;b jsonb;v text;i int;
begin
 l:=pg_temp.game(false,'lobby'); perform pg_temp.game(false,'running');
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches()')::jsonb;
 perform pg_temp.check(g='[]','lobbies and active games stay out of history');
 update public.sessions set state='ended' where id=l;
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches()')::jsonb;
 perform pg_temp.check(g='[]','abandoned lobbies are not completed games');
 s:=pg_temp.game(false);
 perform pg_temp.answer(s,1,0,now()-interval '8 seconds'); perform pg_temp.answer(s,1,1,now()-interval '7 seconds');
 perform pg_temp.answer(s,1,2,null); perform pg_temp.answer(s,2,0,now()-interval '2 seconds');
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches()')::jsonb;
 perform pg_temp.check(jsonb_array_length(g)=1 and g->0->>'result'='win','history derives the team win from deposited totals');
 perform pg_temp.check(g->0->>'deposited'='2' and g->0->>'place'='1','own contribution rank excludes carried answers');
 g:=pg_temp.as_player(pg_temp.uid(2),'select public.my_matches()')::jsonb;
 perform pg_temp.check(g->0->>'result'='loss' and g->0->>'place'='2','opponents get a loss and their contribution rank');
 g:=pg_temp.as_player(pg_temp.uid(4),'select public.my_matches()')::jsonb;
 perform pg_temp.check(g='[]','history belongs only to the signed-in player');
 g:=pg_temp.as_player(pg_temp.uid(3),'select public.my_matches()')::jsonb;
 perform pg_temp.check(g->0->>'result'='win' and g->0->>'deposited'='0','winning teammates receive the team win');
 b:=pg_temp.as_player(pg_temp.uid(4),'select public.player_board()')::jsonb;
 perform pg_temp.check(b->0->>'profile_id'=pg_temp.uid(1)::text and b->0->>'wins'='1' and b->0->>'deposited'='2','global board counts server-owned wins and deposits');
 perform pg_temp.check(b->1->>'profile_id'=pg_temp.uid(3)::text and b->2->>'profile_id'=pg_temp.uid(2)::text,'wins outrank a losing players higher deposit count');
 c:=pg_temp.game(true); for i in 0..2 loop perform pg_temp.answer(c,2,i,now()); end loop;
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches()')::jsonb;
 perform pg_temp.check(exists(select 1 from jsonb_array_elements(g) r where r->>'session_id'=c::text and r->>'custom'='true' and r->>'result'='loss'),'Custom games appear in history with a Custom flag');
 g:=pg_temp.as_player(pg_temp.uid(4),'select public.player_board()')::jsonb;
 perform pg_temp.check(g=b,'custom games cannot farm global wins or deposits');
 d:=pg_temp.game(false);
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches()')::jsonb;
 perform pg_temp.check(exists(select 1 from jsonb_array_elements(g) r where r->>'session_id'=d::text and r->>'result'='draw'),'zero scores and null timestamps are a draw');
 t:=pg_temp.game(false,'expired');
 perform pg_temp.answer(t,1,0,'2026-10-23 00:00:00.1+00'); perform pg_temp.answer(t,2,0,'2026-10-23 00:00:00.9+00');
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches()')::jsonb;
 perform pg_temp.check(exists(select 1 from jsonb_array_elements(g) r where r->>'session_id'=t::text and r->>'result'='win'),'expired running games count and fractional deposit times break ties');
 update public.monk_answers set deposited_at='2026-10-23 00:00:00.1+00' where session_id=t;
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches()')::jsonb;
 perform pg_temp.check(exists(select 1 from jsonb_array_elements(g) r where r->>'session_id'=t::text and r->>'result'='draw'),'equal totals and exact times award a draw');
 f:=pg_temp.game(false); perform pg_temp.answer(f,1,0,now()-interval '1 minute');
 for i in 0..2 loop perform pg_temp.answer(f,2,i,now()); end loop;
 update public.sessions set winner_team=pg_temp.side(f,'Red') where id=f;
 g:=pg_temp.as_player(pg_temp.uid(2),'select public.my_matches()')::jsonb;
 perform pg_temp.check(exists(select 1 from jsonb_array_elements(g) r where r->>'session_id'=f::text and r->>'result'='win'),'a team finishing every word wins');
 b:=pg_temp.as_player(pg_temp.uid(4),'select public.player_board()')::jsonb;
 perform pg_temp.check((select (r->>'wins')::int=1 and (r->>'played')::int=4 from jsonb_array_elements(b) r where r->>'profile_id'=pg_temp.uid(1)::text),'draws count as played without adding wins');
 perform pg_temp.check(not(b::text like '%@t.dev%') and not(b::text like '%password%'),'records contain no email or authentication data');
 v:=pg_temp.as_player(pg_temp.uid(4),'select * from lakbayin_private.match_results limit 1');
 perform pg_temp.check(v like 'ERROR%permission denied%','clients cannot read the private aggregation view',v);
 for i in 1..23 loop perform pg_temp.game(true); end loop;
 g:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches(0)')::jsonb;
 b:=pg_temp.as_player(pg_temp.uid(1),'select public.my_matches(20)')::jsonb;
 perform pg_temp.check(jsonb_array_length(g)=21 and jsonb_array_length(b)=8,'history pages include a next-page sentinel');
 perform pg_temp.check(g->20->>'session_id'=b->0->>'session_id','pagination has stable boundaries');
 perform pg_temp.check(pg_temp.as_player(pg_temp.uid(1),'select public.my_matches(-20)')::jsonb=g,'negative offsets are clamped');
 perform pg_temp.check(pg_temp.as_player(pg_temp.uid(1),'select public.my_matches(100000)')::jsonb='[]','pages beyond the end are empty');
end $$;
select pg_temp.check(not has_function_privilege('anon','public.my_matches(int)','EXECUTE') and not has_function_privilege('anon','public.player_board(int)','EXECUTE'),'record APIs require authentication');
select pg_temp.check((select not prosecdef from pg_proc where oid='public.my_matches(int)'::regprocedure) and (select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid='lakbayin_private.my_matches(int)'::regprocedure),'record APIs use private fixed-path implementations');
select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- RECORDS SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;

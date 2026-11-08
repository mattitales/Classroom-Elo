-- Classroom Elo v0.1. Run once in a new Supabase project's SQL Editor.
-- Private tables have RLS enabled and no browser grants. ALL writes are server-side RPCs.
create extension if not exists pgcrypto;
create schema if not exists private;

create table public.classes (
 id uuid primary key default gen_random_uuid(), name text not null unique,
 active boolean not null default true, created_at timestamptz not null default now()
);
create table public.players (
 id uuid primary key default gen_random_uuid(), real_name text not null,
 nickname text not null, class_id uuid not null references public.classes(id),
 status text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
 created_at timestamptz not null default now()
);
create table public.games (
 id uuid primary key default gen_random_uuid(), name text not null unique, icon text not null default '🎲',
 allow_draws boolean not null default true, active boolean not null default true,
 created_at timestamptz not null default now()
);
create table public.seasons (
 id uuid primary key default gen_random_uuid(), name text not null,
 active boolean not null default false, started_at timestamptz not null default now(),
 ended_at timestamptz, reset_method text not null default 'reset' check (reset_method in ('reset','carry','soft'))
);
create unique index one_active_season on public.seasons(active) where active;
create table public.season_baselines (
 season_id uuid not null references public.seasons(id), game_id uuid not null references public.games(id),
 player_id uuid not null references public.players(id), rating integer not null,
 primary key(season_id,game_id,player_id)
);
create table public.ratings (
 season_id uuid not null references public.seasons(id), game_id uuid not null references public.games(id),
 player_id uuid not null references public.players(id), rating integer not null default 1000,
 played integer not null default 0, wins integer not null default 0, losses integer not null default 0, draws integer not null default 0,
 primary key(season_id,game_id,player_id)
);
create table public.matches (
 id uuid primary key default gen_random_uuid(), season_id uuid not null references public.seasons(id),
 game_id uuid not null references public.games(id), class_id uuid not null references public.classes(id),
 player1_id uuid not null references public.players(id), player2_id uuid not null references public.players(id),
 result text not null check(result in ('p1','p2','draw')),
 status text not null default 'active' check(status in ('active','held','deleted')),
 p1_before integer, p1_after integer, p2_before integer, p2_after integer,
 created_at timestamptz not null default now(),
 check(player1_id <> player2_id)
);
create index match_replay on public.matches(season_id,created_at,id) where status='active';
create index matches_recent_pair on public.matches(game_id,created_at);
create table public.admin_users (user_id uuid primary key references auth.users(id) on delete cascade);
create table public.app_settings (singleton boolean primary key default true check(singleton), station_code text not null);
insert into public.app_settings(singleton,station_code) values(true,'CHANGE-ME-2026');
create table public.audit_log (
 id bigint generated always as identity primary key, actor uuid, action text not null,
 target_id uuid, detail jsonb not null default '{}'::jsonb, happened_at timestamptz not null default now()
);

-- Do not permit direct reads/writes of any tables. Even admin reads use validated RPCs.
do $$ declare t text; begin
 for t in select tablename from pg_tables where schemaname='public' and tablename in
 ('classes','players','games','seasons','season_baselines','ratings','matches','admin_users','app_settings','audit_log') loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on table public.%I from anon, authenticated',t);
 end loop;
end $$;

create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.admin_users where user_id=auth.uid());
$$;
create or replace function private.valid_station(p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.app_settings where singleton and station_code=p_code and length(p_code)>=8);
$$;

-- Replay the immutable chronological order of active matches after every change.
-- Internal function; no browser role may invoke it directly.
create or replace function private.rebuild(p_season uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare m record; a integer; b integer; s numeric; expectation numeric; change_points integer;
begin
 perform pg_catalog.pg_advisory_xact_lock(427201); -- serializes edits and recalculations
 delete from public.ratings where season_id=p_season;
 insert into public.ratings(season_id,game_id,player_id,rating)
 select season_id,game_id,player_id,rating from public.season_baselines where season_id=p_season;
 update public.matches set p1_before=null,p1_after=null,p2_before=null,p2_after=null where season_id=p_season;
 for m in select * from public.matches where season_id=p_season and status='active' order by created_at,id loop
  insert into public.ratings(season_id,game_id,player_id,rating)
  values(p_season,m.game_id,m.player1_id,1000),(p_season,m.game_id,m.player2_id,1000)
  on conflict do nothing;
  select rating into a from public.ratings where season_id=p_season and game_id=m.game_id and player_id=m.player1_id;
  select rating into b from public.ratings where season_id=p_season and game_id=m.game_id and player_id=m.player2_id;
  s:=case m.result when 'p1' then 1 when 'p2' then 0 else 0.5 end;
  expectation:=1/(1+power(10::numeric,(b-a)::numeric/400));
  change_points:=round(32*(s-expectation));
  -- Matching integer changes preserve total rating points for the pair.
  update public.ratings set rating=a+change_points,played=played+1,
   wins=wins+case when m.result='p1' then 1 else 0 end,
   losses=losses+case when m.result='p2' then 1 else 0 end,
   draws=draws+case when m.result='draw' then 1 else 0 end
   where season_id=p_season and game_id=m.game_id and player_id=m.player1_id;
  update public.ratings set rating=b-change_points,played=played+1,
   wins=wins+case when m.result='p2' then 1 else 0 end,
   losses=losses+case when m.result='p1' then 1 else 0 end,
   draws=draws+case when m.result='draw' then 1 else 0 end
   where season_id=p_season and game_id=m.game_id and player_id=m.player2_id;
  update public.matches set p1_before=a,p1_after=a+change_points,p2_before=b,p2_after=b-change_points where id=m.id;
 end loop;
end;$$;

-- Exposes only approved nicknames, never real names or pending registrations.
create or replace function public.arcade_snapshot() returns jsonb
language sql stable security definer set search_path = '' as $$
 select pg_catalog.jsonb_build_object(
 'classes',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name) from public.classes c where active), '[]'::jsonb),
 'games',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'icon',g.icon,'allow_draws',g.allow_draws) order by g.name) from public.games g where active),'[]'::jsonb),
 'season',(select to_jsonb(s) from public.seasons s where active limit 1),
 'players',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nickname',p.nickname,'class_id',p.class_id) order by p.nickname) from public.players p where status='approved' and exists(select 1 from public.classes c where c.id=p.class_id and c.active)),'[]'::jsonb),
 'ratings',coalesce((select jsonb_agg(jsonb_build_object('game_id',r.game_id,'player_id',r.player_id,'rating',r.rating,'played',r.played,'wins',r.wins,'losses',r.losses,'draws',r.draws)) from public.ratings r join public.seasons s on s.id=r.season_id and s.active join public.players p on p.id=r.player_id and p.status='approved'),'[]'::jsonb),
 'matches',coalesce((select jsonb_agg(row_to_json(t)) from (select m.id,m.game_id,m.class_id,m.player1_id,m.player2_id,m.result,m.created_at,m.p1_before,m.p1_after,m.p2_before,m.p2_after from public.matches m join public.seasons s on s.id=m.season_id and s.active where m.status='active' order by m.created_at desc,m.id desc limit 80) t),'[]'::jsonb)
 );
$$;

create or replace function public.station_register(p_code text,p_real_name text,p_nickname text,p_class_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_name text:=pg_catalog.btrim(p_real_name); v_nick text:=pg_catalog.btrim(p_nickname);
begin
 if not private.valid_station(p_code) then raise exception 'Station not unlocked'; end if;
 if char_length(v_name) not between 2 and 80 or char_length(v_nick) not between 2 and 28 then raise exception 'Name or nickname length invalid';end if;
 if not exists(select 1 from public.classes where id=p_class_id and active) then raise exception 'Invalid class period';end if;
 if exists(select 1 from public.players where lower(real_name)=lower(v_name) and class_id=p_class_id and status in ('approved','pending')) then raise exception 'This student may already be registered; ask your teacher'; end if;
 if (select count(*) from public.players where status='pending' and created_at>now()-interval '1 hour')>=50 then raise exception 'Registration queue is temporarily full';end if;
 insert into public.players(real_name,nickname,class_id) values(v_name,v_nick,p_class_id) returning id into v_id;
 return jsonb_build_object('ok',true,'id',v_id);
end;$$;

create or replace function public.station_report(p_code text,p_game_id uuid,p_player1_id uuid,p_player2_id uuid,p_result text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p1 public.players%rowtype;v_p2 public.players%rowtype;v_game public.games%rowtype;v_season uuid;v_id uuid;
begin
 if not private.valid_station(p_code) then raise exception 'Station not unlocked';end if;
 perform pg_catalog.pg_advisory_xact_lock(427201);
 if p_player1_id=p_player2_id then raise exception 'Select two different players'; end if;
 select * into v_p1 from public.players where id=p_player1_id and status='approved';
 select * into v_p2 from public.players where id=p_player2_id and status='approved';
 if v_p1.id is null or v_p2.id is null then raise exception 'Both players must be approved';end if;
 if v_p1.class_id <> v_p2.class_id then raise exception 'Players must be in the same class period';end if;
 select * into v_game from public.games where id=p_game_id and active;
 if v_game.id is null then raise exception 'Game is not available';end if;
 if p_result not in ('p1','p2','draw') or (p_result='draw' and not v_game.allow_draws) then raise exception 'Invalid match result';end if;
 select id into v_season from public.seasons where active;
 if v_season is null then raise exception 'No active season';end if;
 if exists(select 1 from public.matches where status='active' and created_at>now()-interval '90 seconds' and game_id=p_game_id and season_id=v_season and ((player1_id=p_player1_id and player2_id=p_player2_id) or (player1_id=p_player2_id and player2_id=p_player1_id))) then
  raise exception 'A match with these players was just recorded. Ask the teacher if this is intentional';
 end if;
 if (select count(*) from public.matches where status='active' and game_id=p_game_id and created_at>now()-interval '1 hour' and ((player1_id=p_player1_id and player2_id=p_player2_id) or (player1_id=p_player2_id and player2_id=p_player1_id)))>=8 then
  raise exception 'Too many matches between these players this hour';
 end if;
 insert into public.matches(season_id,game_id,class_id,player1_id,player2_id,result)
 values(v_season,p_game_id,v_p1.class_id,p_player1_id,p_player2_id,p_result) returning id into v_id;
 perform private.rebuild(v_season);
 return jsonb_build_object('ok',true,'id',v_id);
end;$$;

create or replace function public.manager_snapshot() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if not private.is_admin() then raise exception 'Manager login required';end if;
 return jsonb_build_object(
  'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.players p),'[]'::jsonb),
  'matches',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at desc) from public.matches m),'[]'::jsonb),
  'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.name) from public.classes c),'[]'::jsonb),
  'games',coalesce((select jsonb_agg(to_jsonb(g) order by g.name) from public.games g),'[]'::jsonb),
  'seasons',coalesce((select jsonb_agg(to_jsonb(s) order by s.started_at desc) from public.seasons s),'[]'::jsonb),
  'station_code',(select station_code from public.app_settings where singleton),
  'audit',coalesce((select jsonb_agg(row_to_json(a)) from (select id,action,happened_at from public.audit_log order by id desc limit 40) a),'[]'::jsonb)
 );
end;$$;

-- Single audited manager endpoint, restricted to explicitly listed actions.
create or replace function public.manager_action(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_season uuid; v_class uuid; v_p1 public.players%rowtype;v_p2 public.players%rowtype;
 v_match public.matches%rowtype; v_game public.games%rowtype; v_new uuid; v_mode text; v_name text;
begin
 if not private.is_admin() then raise exception 'Manager login required';end if;
 perform pg_catalog.pg_advisory_xact_lock(427201);
 if p_action='approve_player' then
  update public.players set status='approved' where id=(p_data->>'id')::uuid and status='pending' returning id into v_id;
 elsif p_action='reject_player' then
  update public.players set status='rejected' where id=(p_data->>'id')::uuid returning id into v_id;
 elsif p_action='update_player' then
  update public.players set real_name=left(trim(coalesce(p_data->>'real_name',real_name)),80),nickname=left(trim(coalesce(p_data->>'nickname',nickname)),28),
   class_id=coalesce((p_data->>'class_id')::uuid,class_id), status=coalesce(p_data->>'status',status)
   where id=(p_data->>'id')::uuid returning id into v_id;
  if exists(select 1 from public.players where id=v_id and (length(real_name)<2 or length(nickname)<2)) then raise exception 'Name is too short';end if;
  -- Historical match class remains fixed; new matches follow current class.
 elsif p_action='add_class' then
  v_name:=left(trim(p_data->>'name'),60); if length(v_name)<1 then raise exception 'Class name required';end if;
  insert into public.classes(name) values(v_name) returning id into v_id;
 elsif p_action='add_game' then
  v_name:=left(trim(p_data->>'name'),60); if length(v_name)<1 then raise exception 'Game name required';end if;
  insert into public.games(name,icon,allow_draws) values(v_name,left(coalesce(p_data->>'icon','🎲'),8),coalesce((p_data->>'allow_draws')::boolean,true)) returning id into v_id;
 elsif p_action='update_game' then
  update public.games set name=left(trim(coalesce(p_data->>'name',name)),60), icon=left(coalesce(p_data->>'icon',icon),8),active=coalesce((p_data->>'active')::boolean,active)
  where id=(p_data->>'id')::uuid returning id into v_id;
 elsif p_action in ('bulk_delete_matches','bulk_hold_matches','bulk_restore_matches') then
  if jsonb_typeof(p_data->'ids')<>'array' or jsonb_array_length(p_data->'ids') not between 1 and 100 then raise exception 'Choose 1 to 100 matches';end if;
  -- One update and one replay for each affected season (not for each match).
  for v_season in select distinct m.season_id from public.matches m where m.id in (select jsonb_array_elements_text(p_data->'ids')::uuid) loop
   update public.matches set status=case p_action when 'bulk_delete_matches' then 'deleted' when 'bulk_hold_matches' then 'held' else 'active' end
    where season_id=v_season and id in (select jsonb_array_elements_text(p_data->'ids')::uuid);
   perform private.rebuild(v_season);
  end loop;
 elsif p_action in ('hold_match','delete_match','restore_match','edit_match') then
  select * into v_match from public.matches where id=(p_data->>'id')::uuid;
  if v_match.id is null then raise exception 'Match not found';end if;
  v_id:=v_match.id;
  if p_action='hold_match' then update public.matches set status='held' where id=v_id;
  elsif p_action='delete_match' then update public.matches set status='deleted' where id=v_id;
  elsif p_action='restore_match' then update public.matches set status='active' where id=v_id;
  else
   select * into v_p1 from public.players where id=coalesce((p_data->>'player1_id')::uuid,v_match.player1_id);
   select * into v_p2 from public.players where id=coalesce((p_data->>'player2_id')::uuid,v_match.player2_id);
   if v_p1.id is null or v_p2.id is null or v_p1.id=v_p2.id or v_p1.class_id<>v_p2.class_id then raise exception 'Players must be different and in the same class';end if;
   select * into v_game from public.games where id=coalesce((p_data->>'game_id')::uuid,v_match.game_id);
   if v_game.id is null then raise exception 'Unknown game';end if;
   if coalesce(p_data->>'result',v_match.result) not in ('p1','p2','draw') or (coalesce(p_data->>'result',v_match.result)='draw' and not v_game.allow_draws) then raise exception 'Invalid result';end if;
   update public.matches set player1_id=v_p1.id,player2_id=v_p2.id,class_id=v_p1.class_id,game_id=v_game.id,result=coalesce(p_data->>'result',v_match.result) where id=v_id;
  end if;
  perform private.rebuild(v_match.season_id);
 elsif p_action='set_station_code' then
  if length(coalesce(p_data->>'code',''))<8 then raise exception 'Station code must be at least 8 characters';end if;
  update public.app_settings set station_code=p_data->>'code' where singleton;
 elsif p_action='new_season' then
  v_name:=left(trim(p_data->>'name'),80);v_mode:=p_data->>'mode';
  if length(v_name)<1 or v_mode not in ('reset','carry','soft') then raise exception 'Provide a name and reset mode';end if;
  select id into v_season from public.seasons where active;
  if v_season is not null then update public.seasons set active=false,ended_at=now() where id=v_season;end if;
  insert into public.seasons(name,active,reset_method) values(v_name,true,v_mode) returning id into v_new;
  if v_season is not null and v_mode<>'reset' then
   insert into public.season_baselines(season_id,game_id,player_id,rating)
   select v_new,r.game_id,r.player_id,case when v_mode='carry' then r.rating else round(1000+(r.rating-1000)*0.5)::integer end
   from public.ratings r where r.season_id=v_season;
  end if;
  perform private.rebuild(v_new);v_id:=v_new;
 else raise exception 'Unknown manager action';
 end if;
 insert into public.audit_log(actor,action,target_id,detail) values(auth.uid(),p_action,v_id,
  case when p_action='set_station_code' then '{}'::jsonb else coalesce(p_data,'{}'::jsonb) end);
 return jsonb_build_object('ok',true,'id',v_id);
end;$$;

-- Prevent table exposure and restrict RPC execution to intended audiences.
revoke all on all functions in schema private from public,anon,authenticated;
revoke execute on all functions in schema public from public,anon,authenticated;
grant execute on function public.arcade_snapshot() to anon,authenticated;
grant execute on function public.station_register(text,text,text,uuid) to anon,authenticated;
grant execute on function public.station_report(text,uuid,uuid,uuid,text) to anon,authenticated;
grant execute on function public.manager_snapshot() to authenticated;
grant execute on function public.manager_action(text,jsonb) to authenticated;

insert into public.classes(name) values('Period 1'),('Period 3'),('Period 4');
insert into public.games(name,icon,allow_draws) values('Chess','♟️',true),('Checkers','🔴',true),('Connect Four','🟡',true);
insert into public.seasons(name,active) values('Season 1',true);

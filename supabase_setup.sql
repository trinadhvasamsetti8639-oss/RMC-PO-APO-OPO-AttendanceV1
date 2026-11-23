-- Run in Supabase > SQL Editor. Safe to re-run: existing users, attendance and datasets are kept.
create extension if not exists pgcrypto with schema extensions;
drop function if exists report(text,text); drop function if exists mark(text,text,text,text,int,int,text,text,double precision,double precision);
drop function if exists mark(text,text,int,int,text,text,double precision,double precision);
drop function if exists login(text,text); drop function if exists list_users(text,text); drop function if exists add_user(text,text,text,text,text,int[]);
drop function if exists add_user(text,text,text,text,text);
do $$ begin
  if exists(select 1 from information_schema.tables where table_name='attendance') and not exists(select 1 from information_schema.columns where table_name='attendance' and column_name='k') then
    drop table attendance cascade; end if; end $$;

create table if not exists app_users(username text primary key, pwd text not null, role text not null default 'user', groups int[]);
alter table app_users add column if not exists groups int[];
create table if not exists settings(id int primary key default 1 check(id=1), enabled boolean default false, lat double precision, lng double precision, radius int default 200);
-- k = 'T'+election id (team) or 'R'+serial no (reserve)
create table if not exists attendance(k text primary key, kind text, group_no int, idno int, role text, status text, lat double precision, lng double precision, marked_by text, marked_at timestamptz default now());
-- reserve staff (rid = reserve serial) assigned to a team slot
create table if not exists assignments(group_no int, role text, rid int unique, assigned_by text, assigned_at timestamptz default now(), primary key(group_no,role));
-- employee databases uploaded by admin: nm = 'team' or 'reserve'
create table if not exists datasets(nm text primary key, body jsonb, updated_at timestamptz default now());
insert into settings(id) values(1) on conflict do nothing;
insert into app_users(username,pwd,role) values('admin', extensions.crypt('admin123', extensions.gen_salt('bf')), 'admin') on conflict do nothing;
alter table app_users enable row level security; alter table settings enable row level security; alter table attendance enable row level security;
alter table assignments enable row level security; alter table datasets enable row level security;

create or replace function _auth(u text,p text) returns text language sql security definer set search_path=public,extensions as
$$ select role from app_users where username=u and pwd=crypt(p,pwd) $$;
revoke execute on function _auth(text,text) from public, anon;

create function login(u text,p text) returns json language sql security definer set search_path=public,extensions as
$$ select json_build_object('role',role,'groups',coalesce(groups,'{}')) from app_users where username=u and pwd=crypt(p,pwd) $$;

create or replace function get_settings() returns settings language sql security definer set search_path=public as $$ select * from settings where id=1 $$;

create or replace function save_settings(u text,p text,en boolean,la double precision,ln double precision,rad int) returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
  if _auth(u,p) is distinct from 'admin' then raise exception 'Admin access required'; end if;
  update settings set enabled=en, lat=la, lng=ln, radius=rad where id=1;
end $$;

create function mark(u text,p text,pk text,kd text,g int,i int,r text,s text,la double precision,ln double precision) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare st settings; d double precision; rl text;
begin
  rl := _auth(u,p);
  if rl is null or rl in ('ro','sec') then raise exception 'Not allowed to capture attendance'; end if;
  select * into st from settings where id=1;
  if st.enabled and st.lat is not null then
    if la is null or ln is null then raise exception 'Location is required'; end if;
    d := 6371000*2*asin(sqrt(power(sin(radians(la-st.lat)/2),2)+cos(radians(st.lat))*cos(radians(la))*power(sin(radians(ln-st.lng)/2),2)));
    if d > st.radius then raise exception 'Outside allowed area (% m away, limit % m)', round(d), st.radius; end if;
  end if;
  insert into attendance(k,kind,group_no,idno,role,status,lat,lng,marked_by,marked_at) values(pk,kd,g,i,r,s,la,ln,u,now())
  on conflict(k) do update set status=excluded.status, lat=excluded.lat, lng=excluded.lng, marked_by=excluded.marked_by, marked_at=now();
end $$;

-- ROs only receive rows for the stations assigned to them
create function report(u text,p text) returns setof attendance language plpgsql security definer set search_path=public,extensions as $$
declare rl text; gs int[];
begin
  select a.role,a.groups into rl,gs from app_users a where a.username=u and a.pwd=crypt(p,a.pwd);
  if rl is null then raise exception 'Invalid login'; end if;
  return query select t.* from attendance t where rl<>'ro' or t.group_no = any(coalesce(gs,'{}'));
end $$;

create or replace function list_asg(u text,p text) returns setof assignments language plpgsql security definer set search_path=public,extensions as $$
declare rl text; gs int[];
begin
  select a.role,a.groups into rl,gs from app_users a where a.username=u and a.pwd=crypt(p,a.pwd);
  if rl is null then raise exception 'Invalid login'; end if;
  return query select t.* from assignments t where rl<>'ro' or t.group_no = any(coalesce(gs,'{}'));
end $$;

-- Administrative Secretary (role 'sec') or admin: only PRESENT reserve staff can be assigned, only to slots not yet present
create or replace function assign(u text,p text,pg int,pr text,pid int) returns void language plpgsql security definer set search_path=public,extensions as $$
declare rl text; sa text; ra text;
begin
  rl := _auth(u,p);
  if rl is null or rl not in ('admin','sec') then raise exception 'Only the Administrative Secretary can assign reserve staff'; end if;
  select status into ra from attendance where k='R'||pid;
  if ra is distinct from 'Attended' then raise exception 'Reserve staff is not present - cannot be assigned'; end if;
  select status into sa from attendance where kind='T' and group_no=pg and role=pr;
  if sa='Attended' then raise exception 'That team member is already present'; end if;
  if exists(select 1 from assignments where rid=pid and not (group_no=pg and role=pr)) then raise exception 'Reserve staff is already assigned to another team'; end if;
  insert into assignments(group_no,role,rid,assigned_by,assigned_at) values(pg,pr,pid,u,now())
  on conflict(group_no,role) do update set rid=excluded.rid, assigned_by=u, assigned_at=now();
end $$;

create or replace function unassign(u text,p text,pg int,pr text) returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if _auth(u,p) not in ('admin','sec') then raise exception 'Not allowed'; end if;
  delete from assignments where group_no=pg and role=pr;
end $$;

-- Admin: fresh start. sc = 'all' | 'team' | 'reserve'. Assignments are always cleared.
create or replace function clear_attendance(u text,p text,sc text) returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if _auth(u,p) is distinct from 'admin' then raise exception 'Admin access required'; end if;
  delete from attendance where sc='all' or (sc='team' and kind='T') or (sc='reserve' and kind='R');
  delete from assignments;
end $$;

create or replace function get_dataset(u text,p text,nm text) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare b jsonb;
begin
  if _auth(u,p) is null then raise exception 'Invalid login'; end if;
  select d.body into b from datasets d where d.nm=get_dataset.nm; return b;
end $$;

create or replace function save_dataset(u text,p text,nm text,body jsonb,wipe boolean) returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if _auth(u,p) is distinct from 'admin' then raise exception 'Admin access required'; end if;
  insert into datasets(nm,body,updated_at) values(nm,body,now()) on conflict(nm) do update set body=excluded.body, updated_at=now();
  if wipe then delete from attendance; delete from assignments; end if;
end $$;

create function list_users(u text,p text) returns table(username text, role text, groups int[]) language plpgsql security definer set search_path=public,extensions as $$
begin
  if _auth(u,p) is distinct from 'admin' then raise exception 'Admin access required'; end if;
  return query select a.username, a.role, a.groups from app_users a order by 1;
end $$;

-- blank password on an existing user keeps the old password. Roles: user, ro, sec, admin
create function add_user(u text,p text,nu text,np text,nr text,gr int[]) returns void language plpgsql security definer set search_path=public,extensions as $$
declare rl text := case when nr in ('admin','ro','sec') then nr else 'user' end;
begin
  if _auth(u,p) is distinct from 'admin' then raise exception 'Admin access required'; end if;
  if coalesce(np,'')<>'' then
    insert into app_users(username,pwd,role,groups) values(nu, crypt(np,gen_salt('bf')), rl, gr)
    on conflict(username) do update set pwd=excluded.pwd, role=excluded.role, groups=excluded.groups;
  else
    update app_users set role=rl, groups=gr where username=nu;
    if not found then raise exception 'A new user needs a password'; end if;
  end if;
end $$;

create or replace function del_user(u text,p text,du text) returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if _auth(u,p) is distinct from 'admin' then raise exception 'Admin access required'; end if;
  if du=u then raise exception 'Cannot delete yourself'; end if;
  delete from app_users where username=du;
end $$;

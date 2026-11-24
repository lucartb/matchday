-- Matchday – Datenbank für „Runde“ und Admin-Übersicht
-- Einmal komplett im Supabase SQL-Editor ausführen.
-- Sicherheit: Alle Tabellen sind gesperrt (RLS ohne Regeln). Zugriff nur über die
-- Funktionen unten; jede Funktion prüft, wer anfragt (auth.uid()).

create extension if not exists pgcrypto;

create table if not exists md_groups (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null check (char_length(name) between 1 and 40),
  created_at timestamptz not null default now()
);

create table if not exists md_members (
  id uuid primary key,                       -- = auth.uid() des Geräts
  group_id uuid not null references md_groups(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 30),
  teams text[] not null default '{}' check (coalesce(array_length(teams,1),0) <= 40),
  device text check (char_length(device) <= 60),
  standalone boolean not null default false,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);

create table if not exists md_watch (
  member_id uuid not null references md_members(id) on delete cascade,
  group_id uuid not null references md_groups(id) on delete cascade,
  ev text not null check (char_length(ev) <= 200),
  created_at timestamptz not null default now(),
  primary key (member_id, ev)
);

create table if not exists md_admin (
  id int primary key default 1 check (id = 1),
  pin_hash text not null,
  fails int not null default 0,
  locked_until timestamptz
);

alter table md_groups enable row level security;
alter table md_members enable row level security;
alter table md_watch enable row level security;
alter table md_admin enable row level security;
revoke all on md_groups, md_members, md_watch, md_admin from anon, authenticated;

-- Zustand der eigenen Runde
create or replace function md_state() returns json
language plpgsql security definer set search_path = public as $$
declare g uuid; r json;
begin
  select group_id into g from md_members where id = auth.uid();
  if g is null then return null; end if;
  update md_members set last_seen = now() where id = auth.uid();
  select json_build_object(
    'code', (select code from md_groups where id = g),
    'name', (select name from md_groups where id = g),
    'me', auth.uid(),
    'members', (select coalesce(json_agg(json_build_object('id',id,'name',name,'teams',teams) order by created_at),'[]') from md_members where group_id = g),
    'watch', (select coalesce(json_agg(json_build_object('m',member_id,'ev',ev)),'[]') from md_watch where group_id = g)
  ) into r;
  return r;
end $$;

-- Neue Runde anlegen (Gerät wird erstes Mitglied)
create or replace function md_create(p_group text, p_name text, p_teams text[], p_device text, p_standalone boolean) returns json
language plpgsql security definer set search_path = public as $$
declare g uuid; c text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  loop
    c := upper(substr(translate(encode(gen_random_bytes(6),'base64'),'+/=0O1Il','XYZABCDE'),1,6));
    exit when not exists (select 1 from md_groups where code = c);
  end loop;
  insert into md_groups(code,name) values (c, left(trim(p_group),40)) returning id into g;
  insert into md_members(id,group_id,name,teams,device,standalone)
    values (auth.uid(), g, left(trim(p_name),30), coalesce(p_teams[1:40],'{}'), left(p_device,60), coalesce(p_standalone,false))
    on conflict (id) do update set group_id = excluded.group_id, name = excluded.name, teams = excluded.teams, device = excluded.device, standalone = excluded.standalone, last_seen = now();
  delete from md_watch where member_id = auth.uid() and group_id <> g;
  return md_state();
end $$;

-- Per Code beitreten
create or replace function md_join(p_code text, p_name text, p_teams text[], p_device text, p_standalone boolean) returns json
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select id into g from md_groups where code = upper(trim(p_code));
  if g is null then return json_build_object('error','code'); end if;
  if (select count(*) from md_members where group_id = g) >= 50 then return json_build_object('error','full'); end if;
  insert into md_members(id,group_id,name,teams,device,standalone)
    values (auth.uid(), g, left(trim(p_name),30), coalesce(p_teams[1:40],'{}'), left(p_device,60), coalesce(p_standalone,false))
    on conflict (id) do update set group_id = excluded.group_id, name = excluded.name, teams = excluded.teams, device = excluded.device, standalone = excluded.standalone, last_seen = now();
  delete from md_watch where member_id = auth.uid() and group_id <> g;
  return md_state();
end $$;

-- Name der Runde für die Einladung anzeigen (ohne Mitglieder)
create or replace function md_peek(p_code text) returns json
language sql security definer set search_path = public as $$
  select json_build_object('name', name, 'count', (select count(*) from md_members m where m.group_id = g.id))
  from md_groups g where code = upper(trim(p_code));
$$;

-- Lebenszeichen: Teams/Gerät aktualisieren
create or replace function md_ping(p_name text, p_teams text[], p_device text, p_standalone boolean) returns void
language sql security definer set search_path = public as $$
  update md_members set name = coalesce(nullif(left(trim(p_name),30),''), name), teams = coalesce(p_teams[1:40], teams),
    device = left(p_device,60), standalone = coalesce(p_standalone,false), last_seen = now()
  where id = auth.uid();
$$;

-- „Will ich schauen“ an/aus
create or replace function md_watch_set(p_ev text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select group_id into g from md_members where id = auth.uid();
  if g is null then return null; end if;
  if p_on then
    if (select count(*) from md_watch where member_id = auth.uid()) < 300 then
      insert into md_watch(member_id,group_id,ev) values (auth.uid(), g, left(p_ev,200)) on conflict do nothing;
    end if;
  else
    delete from md_watch where member_id = auth.uid() and ev = p_ev;
  end if;
  return md_state();
end $$;

-- Runde verlassen
create or replace function md_leave() returns void
language sql security definer set search_path = public as $$
  delete from md_members where id = auth.uid();
$$;

-- Admin-Übersicht (nur mit PIN; nach 5 Fehlversuchen 15 Min. gesperrt)
create or replace function md_admin_list(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a md_admin%rowtype;
begin
  select * into a from md_admin where id = 1;
  if a.id is null then return json_build_object('error','nopin'); end if;
  if a.locked_until is not null and a.locked_until > now() then return json_build_object('error','locked'); end if;
  if a.pin_hash = crypt('HIER-DEINE-PIN', a.pin_hash) then return json_build_object('error','default'); end if;
  if a.pin_hash <> crypt(p_pin, a.pin_hash) then
    update md_admin set fails = fails + 1, locked_until = case when fails + 1 >= 5 then now() + interval '15 minutes' else null end where id = 1;
    return json_build_object('error','pin');
  end if;
  update md_admin set fails = 0, locked_until = null where id = 1;
  return json_build_object('members', (select coalesce(json_agg(json_build_object(
      'name', m.name, 'group', g.name, 'code', g.code, 'device', m.device, 'standalone', m.standalone,
      'last_seen', m.last_seen, 'created_at', m.created_at, 'watch', (select count(*) from md_watch w where w.member_id = m.id)
    ) order by m.last_seen desc),'[]') from md_members m join md_groups g on g.id = m.group_id),
    'groups', (select count(*) from md_groups));
end $$;

-- Admin: Mitglied entfernen
create or replace function md_admin_remove(p_pin text, p_name text, p_code text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if (md_admin_list(p_pin)->>'error') is not null then return json_build_object('error','pin'); end if;
  delete from md_members m using md_groups g where g.id = m.group_id and g.code = p_code and m.name = p_name;
  return md_admin_list(p_pin);
end $$;

revoke all on function md_state, md_create, md_join, md_peek, md_ping, md_watch_set, md_leave, md_admin_list, md_admin_remove from public, anon;
grant execute on function md_state, md_create, md_join, md_peek, md_ping, md_watch_set, md_leave, md_admin_list, md_admin_remove to authenticated;

-- >>> HIER DEINE ADMIN-PIN EINTRAGEN (mind. 8 Zeichen) und dann ausführen <<<
insert into md_admin(id, pin_hash) values (1, crypt('HIER-DEINE-PIN', gen_salt('bf')))
  on conflict (id) do update set pin_hash = excluded.pin_hash, fails = 0, locked_until = null;

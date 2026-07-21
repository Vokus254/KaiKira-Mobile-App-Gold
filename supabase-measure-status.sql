-- people.role verwendet im bestehenden Projekt den Enum-Typ public.people_role.
-- Neue Enum-Werte muessen vor der eigentlichen Transaktion festgeschrieben sein,
-- damit sie anschliessend direkt in people-Zeilen verwendet werden koennen.
alter type public.people_role add value if not exists 'leiterRechnungswesen';
alter type public.people_role add value if not exists 'leiterSteuern';
alter type public.people_role add value if not exists 'leiterControlling';
alter type public.people_role add value if not exists 'kreditorenbuchhalter';
alter type public.people_role add value if not exists 'debitorenbuchhalter';
alter type public.people_role add value if not exists 'itAdministrator';
alter type public.people_role add value if not exists 'externerDienstleister';

begin;

-- KaiKira Gold: Rollen, Standardzuweisungen und abgesicherter Maßnahmenworkflow.
-- Voraussetzung: Die drei Auth-Nutzer wurden im Supabase-Dashboard angelegt.

-- 1) Bestehende people-Rollenliste erweitern.
do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select c.conname
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.people'::pg_catalog.regclass
      and c.contype = 'c'
      and pg_catalog.pg_get_constraintdef(c.oid) like '%role%'
  loop
    execute pg_catalog.format('alter table public.people drop constraint %I', constraint_name);
  end loop;
end;
$$;

alter table public.people
  add constraint people_role_check check (role in (
    'projektleitung',
    'erstellerBilanzbuchhaltung',
    'prueferInternReview',
    'freigebendeGeschaeftsfuehrung',
    'wirtschaftsprueferExtern',
    'adminRechteverwaltung',
    'leiterRechnungswesen',
    'leiterSteuern',
    'leiterControlling',
    'kreditorenbuchhalter',
    'debitorenbuchhalter',
    'itAdministrator',
    'externerDienstleister'
  ));

insert into public.people (id, email, role, name)
select id, email, 'erstellerBilanzbuchhaltung', 'Bernd Buha'
from auth.users
where pg_catalog.lower(email) = 'v.kusch@web.de'
on conflict (id) do update
set email = excluded.email,
    role = excluded.role,
    name = excluded.name;

insert into public.people (id, email, role, name)
select id, email, 'freigebendeGeschaeftsfuehrung', 'Sandra Vorstand'
from auth.users
where pg_catalog.lower(email) = 'v.kusch@email.de'
on conflict (id) do update
set email = excluded.email,
    role = excluded.role,
    name = excluded.name;

do $$
begin
  if not exists (select 1 from public.people where pg_catalog.lower(email) = 'v.kusch@web.de') then
    raise exception 'Auth-Nutzer für Bernd Buha fehlt';
  end if;
  if not exists (select 1 from public.people where pg_catalog.lower(email) = 'v.kusch@email.de') then
    raise exception 'Auth-Nutzer für Sandra Vorstand fehlt';
  end if;
end;
$$;

-- 2) Standardzuweisung je Maßnahme. KAI/KIRA sind bewusst Systemmarker ohne people-Zeile.
create table if not exists public.measure_default_assignment (
  nr text primary key references public.measure_status(nr) on delete cascade,
  bearbeiter_rolle text not null check (bearbeiter_rolle in (
    'projektleitung', 'erstellerBilanzbuchhaltung', 'prueferInternReview',
    'freigebendeGeschaeftsfuehrung', 'wirtschaftsprueferExtern',
    'adminRechteverwaltung', 'leiterRechnungswesen', 'leiterSteuern',
    'leiterControlling', 'kreditorenbuchhalter', 'debitorenbuchhalter',
    'itAdministrator', 'externerDienstleister', 'system_kai', 'system_kira'
  )),
  bearbeiter_person uuid references public.people(id) on delete restrict,
  freigeber_rolle text check (freigeber_rolle in (
    'projektleitung', 'erstellerBilanzbuchhaltung', 'prueferInternReview',
    'freigebendeGeschaeftsfuehrung', 'wirtschaftsprueferExtern',
    'adminRechteverwaltung', 'leiterRechnungswesen', 'leiterSteuern',
    'leiterControlling', 'kreditorenbuchhalter', 'debitorenbuchhalter',
    'itAdministrator', 'externerDienstleister'
  )),
  freigeber_person uuid references public.people(id) on delete restrict,
  bearbeiter_name_source text not null,
  bearbeiter_email_source text not null,
  freigeber_name_source text,
  freigeber_email_source text,
  constraint measure_assignment_bearbeiter_check check (
    (bearbeiter_rolle in ('system_kai', 'system_kira') and bearbeiter_person is null)
    or
    (bearbeiter_rolle not in ('system_kai', 'system_kira') and bearbeiter_person is not null)
  ),
  constraint measure_assignment_freigeber_check check (
    (freigeber_rolle is null and freigeber_person is null
      and freigeber_name_source is null and freigeber_email_source is null)
    or
    (freigeber_rolle is not null and freigeber_person is not null
      and freigeber_name_source is not null and freigeber_email_source is not null)
  ),
  constraint measure_assignment_separation_check check (
    bearbeiter_person is null or freigeber_person is null or bearbeiter_person <> freigeber_person
  )
);

alter table public.measure_default_assignment enable row level security;
revoke all on table public.measure_default_assignment from anon, authenticated;
grant select on table public.measure_default_assignment to authenticated;
grant insert, update, delete on table public.measure_default_assignment to authenticated;

drop policy if exists "measure_assignment_select_authenticated" on public.measure_default_assignment;
create policy "measure_assignment_select_authenticated"
on public.measure_default_assignment for select to authenticated using (true);

drop policy if exists "measure_assignment_admin_insert" on public.measure_default_assignment;
create policy "measure_assignment_admin_insert"
on public.measure_default_assignment for insert to authenticated
with check ((select private.is_people_admin()));

drop policy if exists "measure_assignment_admin_update" on public.measure_default_assignment;
create policy "measure_assignment_admin_update"
on public.measure_default_assignment for update to authenticated
using ((select private.is_people_admin()))
with check ((select private.is_people_admin()));

drop policy if exists "measure_assignment_admin_delete" on public.measure_default_assignment;
create policy "measure_assignment_admin_delete"
on public.measure_default_assignment for delete to authenticated
using ((select private.is_people_admin()));

-- 3) Statusdomain erweitern. 1.2 bleibt fachlich vom lokalen Rollenformular abgeleitet.
do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select c.conname
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.measure_status'::pg_catalog.regclass
      and c.contype = 'c'
      and pg_catalog.pg_get_constraintdef(c.oid) like '%status%'
  loop
    execute pg_catalog.format('alter table public.measure_status drop constraint %I', constraint_name);
  end loop;
end;
$$;

alter table public.measure_status
  add constraint measure_status_status_check check (status in (
    'offen', 'in_bearbeitung', 'erledigt', 'zur_freigabe', 'freigegeben'
  ));

-- 4) Rückgaben werden als Historie gespeichert, nicht in einem überschreibbaren Einzelfeld.
create table if not exists public.measure_status_comments (
  id bigint generated always as identity primary key,
  nr text not null references public.measure_status(nr) on delete cascade,
  from_status text not null,
  to_status text not null,
  kommentar text not null check (pg_catalog.btrim(kommentar) <> ''),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now()
);

alter table public.measure_status_comments enable row level security;
revoke all on table public.measure_status_comments from anon, authenticated;
grant select on table public.measure_status_comments to authenticated;

drop policy if exists "measure_comments_select_authenticated" on public.measure_status_comments;
create policy "measure_comments_select_authenticated"
on public.measure_status_comments for select to authenticated using (true);

-- Direkte Statusänderungen sperren; ausschließlich die RPC darf schreiben.
drop policy if exists "measure_status_update_authenticated" on public.measure_status;
revoke update on table public.measure_status from authenticated;

-- 5) Einzige Statuswechsel-Schnittstelle mit Rollen-, Personen- und Übergangsprüfung.
create or replace function public.change_measure_status(
  p_nr text,
  p_new_status text,
  p_kommentar text default null
)
returns public.measure_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  actor_is_admin boolean;
  current_row public.measure_status%rowtype;
  assignment_row public.measure_default_assignment%rowtype;
  has_approval boolean;
  previous_status text;
begin
  if actor_id is null then
    raise exception 'ANMELDUNG_ERFORDERLICH';
  end if;

  if p_nr = '1.2' then
    raise exception 'MASSNAHME_1_2_WIRD_AUS_ROLLEN_ABGELEITET';
  end if;

  select * into current_row
  from public.measure_status
  where nr = p_nr
  for update;

  if not found then
    raise exception 'MASSNAHME_NICHT_GEFUNDEN';
  end if;

  select * into assignment_row
  from public.measure_default_assignment
  where nr = p_nr;

  if not found then
    raise exception 'ZUWEISUNG_FEHLT';
  end if;

  actor_is_admin := private.is_people_admin();
  has_approval := assignment_row.freigeber_person is not null;

  if p_new_status not in ('offen', 'in_bearbeitung', 'erledigt', 'zur_freigabe', 'freigegeben') then
    raise exception 'UNGUELTIGER_STATUS';
  end if;

  if current_row.status = p_new_status then
    return current_row;
  end if;

  previous_status := current_row.status;

  -- Admin darf abgeschlossene Maßnahmen wiedereröffnen.
  if actor_is_admin
     and current_row.status in ('erledigt', 'freigegeben')
     and p_new_status = 'offen' then
    null;

  elsif not has_approval then
    if not (current_row.status = 'offen' and p_new_status = 'erledigt') then
      raise exception 'STATUSWECHSEL_NICHT_ERLAUBT';
    end if;
    if assignment_row.bearbeiter_person <> actor_id and not actor_is_admin then
      raise exception 'NUR_BEARBEITER_DARF_ERLEDIGEN';
    end if;

  else
    if current_row.status = 'offen' and p_new_status = 'in_bearbeitung' then
      if assignment_row.bearbeiter_person is distinct from actor_id and not actor_is_admin then
        raise exception 'NUR_BEARBEITER_DARF_STARTEN';
      end if;

    elsif current_row.status = 'in_bearbeitung' and p_new_status = 'zur_freigabe' then
      if assignment_row.bearbeiter_person is distinct from actor_id and not actor_is_admin then
        raise exception 'NUR_BEARBEITER_DARF_EINREICHEN';
      end if;

    elsif current_row.status = 'zur_freigabe' and p_new_status = 'freigegeben' then
      if assignment_row.bearbeiter_person = actor_id then
        raise exception 'SELBSTFREIGABE_NICHT_ERLAUBT';
      end if;
      if assignment_row.freigeber_person <> actor_id and not actor_is_admin then
        raise exception 'NUR_FREIGEBER_DARF_FREIGEBEN';
      end if;

    elsif current_row.status = 'zur_freigabe' and p_new_status = 'in_bearbeitung' then
      if assignment_row.freigeber_person <> actor_id and not actor_is_admin then
        raise exception 'NUR_FREIGEBER_DARF_ZURUECKGEBEN';
      end if;
      if p_kommentar is null or pg_catalog.btrim(p_kommentar) = '' then
        raise exception 'RUECKGABEKOMMENTAR_ERFORDERLICH';
      end if;

    else
      raise exception 'STATUSWECHSEL_NICHT_ERLAUBT';
    end if;
  end if;

  update public.measure_status
  set status = p_new_status
  where nr = p_nr
  returning * into current_row;

  if previous_status = 'zur_freigabe'
     and p_new_status = 'in_bearbeitung'
     and assignment_row.freigeber_person is not null
     and pg_catalog.btrim(p_kommentar) <> '' then
    insert into public.measure_status_comments
      (nr, from_status, to_status, kommentar, created_by)
    values
      (p_nr, 'zur_freigabe', 'in_bearbeitung', pg_catalog.btrim(p_kommentar), actor_id);
  end if;

  return current_row;
end;
$$;

revoke all on function public.change_measure_status(text, text, text) from public, anon;
grant execute on function public.change_measure_status(text, text, text) to authenticated;

-- 6) Alle 94 Standardzuweisungen aus der bestätigten Tabelle.
with source_assignments as (
  select nr, 'projektleitung'::text as bearbeiter_rolle,
         'Volker Kusch'::text as bearbeiter_name, 'info@volkerkusch.de'::text as bearbeiter_email
  from pg_catalog.unnest(array[
    '1.1','1.2','1.3','1.4','1.5','1.6',
    '2.1','2.2','2.3','2.4','2.5','6.12',
    '7.1','7.2','7.3','7.8','7.9','7.10','7.11','7.12',
    '8.1','8.2','8.3','8.4','8.5','8.6','8.7','8.8','8.9','8.10',
    '9.1','9.2','9.3','9.4','9.5','9.6','9.7',
    '10.1','10.2','10.3','10.4','10.5'
  ]) nr
  union all
  select nr, 'erstellerBilanzbuchhaltung', 'Bernd Buha', 'v.kusch@web.de'
  from pg_catalog.unnest(array[
    '3.1','3.2','3.3','3.4','3.5','3.6','3.7','3.8','3.9','3.10','3.11','3.12','3.13','3.14',
    '5.3','5.4','5.5'
  ]) nr
  union all
  select nr, 'system_kai', 'KAI', 'intern'
  from pg_catalog.unnest(array[
    '5.1','5.2','5.6','6.1','6.2','6.3','6.4','6.5','6.6','6.7','6.8'
  ]) nr
  union all
  select nr, 'system_kira', 'KIRA', 'intern'
  from pg_catalog.unnest(array[
    '2.6','2.7','4.1','4.2','4.3','4.4','4.5','4.6','4.7','4.8',
    '5.7','5.8','6.9','6.10','6.11','6.13','6.13A','6.14','6.14A','6.15',
    '7.4','7.5','7.6','7.7'
  ]) nr
), resolved as (
  select
    s.nr,
    s.bearbeiter_rolle,
    case when s.bearbeiter_rolle like 'system_%' then null else p.id end as bearbeiter_person,
    case
      when s.nr in ('6.13','6.14','6.15') then 'projektleitung'
      when s.nr = '8.6' then 'freigebendeGeschaeftsfuehrung'
      else null
    end as freigeber_rolle,
    case
      when s.nr in ('6.13','6.14','6.15') then
        (select id from public.people where pg_catalog.lower(email) = 'info@volkerkusch.de')
      when s.nr = '8.6' then
        (select id from public.people where pg_catalog.lower(email) = 'v.kusch@email.de')
      else null
    end as freigeber_person,
    s.bearbeiter_name,
    s.bearbeiter_email,
    case
      when s.nr in ('6.13','6.14','6.15') then 'Volker Kusch'
      when s.nr = '8.6' then 'Sandra Vorstand'
      else null
    end as freigeber_name,
    case
      when s.nr in ('6.13','6.14','6.15') then 'info@volkerkusch.de'
      when s.nr = '8.6' then 'v.kusch@email.de'
      else null
    end as freigeber_email
  from source_assignments s
  left join public.people p on pg_catalog.lower(p.email) = pg_catalog.lower(s.bearbeiter_email)
)
insert into public.measure_default_assignment (
  nr, bearbeiter_rolle, bearbeiter_person, freigeber_rolle, freigeber_person,
  bearbeiter_name_source, bearbeiter_email_source,
  freigeber_name_source, freigeber_email_source
)
select
  nr, bearbeiter_rolle, bearbeiter_person, freigeber_rolle, freigeber_person,
  bearbeiter_name, bearbeiter_email, freigeber_name, freigeber_email
from resolved
on conflict (nr) do update set
  bearbeiter_rolle = excluded.bearbeiter_rolle,
  bearbeiter_person = excluded.bearbeiter_person,
  freigeber_rolle = excluded.freigeber_rolle,
  freigeber_person = excluded.freigeber_person,
  bearbeiter_name_source = excluded.bearbeiter_name_source,
  bearbeiter_email_source = excluded.bearbeiter_email_source,
  freigeber_name_source = excluded.freigeber_name_source,
  freigeber_email_source = excluded.freigeber_email_source;

do $$
begin
  if (select pg_catalog.count(*) from public.measure_default_assignment) <> 94 then
    raise exception 'Es wurden nicht genau 94 Zuweisungen angelegt';
  end if;
  if (select pg_catalog.count(*) from public.measure_default_assignment where freigeber_person is not null) <> 4 then
    raise exception 'Es wurden nicht genau vier Freigabemaßnahmen angelegt';
  end if;
end;
$$;

commit;

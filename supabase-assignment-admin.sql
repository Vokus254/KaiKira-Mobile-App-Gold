-- KaiKira Gold: bestehende Maßnahmenzuweisung für rollenweite Bearbeitung öffnen.
-- Die vorhandenen RLS-Policies bleiben unverändert; nur Admins dürfen weiterhin schreiben.

begin;

alter table public.measure_default_assignment
  drop constraint if exists measure_assignment_bearbeiter_check,
  drop constraint if exists measure_assignment_freigeber_check;

alter table public.measure_default_assignment
  add constraint measure_assignment_bearbeiter_check check (
    bearbeiter_rolle not in ('system_kai', 'system_kira')
    or bearbeiter_person is null
  ),
  add constraint measure_assignment_freigeber_check check (
    (freigeber_rolle is null and freigeber_person is null
      and freigeber_name_source is null and freigeber_email_source is null)
    or
    (freigeber_rolle is not null
      and freigeber_name_source is not null and freigeber_email_source is not null)
  );

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
  actor_role text;
  actor_is_admin boolean;
  actor_is_bearer boolean;
  actor_is_approver boolean;
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

  select p.role::text into actor_role
  from public.people p
  where p.id = actor_id;

  if actor_role is null then
    raise exception 'PERSON_OHNE_ROLLE';
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
  actor_is_bearer := coalesce(assignment_row.bearbeiter_person = actor_id, false)
    or (assignment_row.bearbeiter_person is null
      and assignment_row.bearbeiter_rolle = actor_role);
  actor_is_approver := coalesce(assignment_row.freigeber_person = actor_id, false)
    or (assignment_row.freigeber_person is null
      and assignment_row.freigeber_rolle = actor_role);
  has_approval := assignment_row.freigeber_rolle is not null;

  if p_new_status not in ('offen', 'in_bearbeitung', 'erledigt', 'zur_freigabe', 'freigegeben') then
    raise exception 'UNGUELTIGER_STATUS';
  end if;

  if current_row.status = p_new_status then
    return current_row;
  end if;

  previous_status := current_row.status;

  if actor_is_admin
     and current_row.status in ('erledigt', 'freigegeben')
     and p_new_status = 'offen' then
    null;

  elsif not has_approval then
    if not (current_row.status = 'offen' and p_new_status = 'erledigt') then
      raise exception 'STATUSWECHSEL_NICHT_ERLAUBT';
    end if;
    if not actor_is_bearer and not actor_is_admin then
      raise exception 'NUR_BEARBEITER_DARF_ERLEDIGEN';
    end if;

  else
    if current_row.status = 'offen' and p_new_status = 'in_bearbeitung' then
      if not actor_is_bearer and not actor_is_admin then
        raise exception 'NUR_BEARBEITER_DARF_STARTEN';
      end if;

    elsif current_row.status = 'in_bearbeitung' and p_new_status = 'zur_freigabe' then
      if not actor_is_bearer and not actor_is_admin then
        raise exception 'NUR_BEARBEITER_DARF_EINREICHEN';
      end if;

    elsif current_row.status = 'zur_freigabe' and p_new_status = 'freigegeben' then
      if coalesce(assignment_row.bearbeiter_person = actor_id, false)
         or coalesce(current_row.updated_by = actor_id, false) then
        raise exception 'SELBSTFREIGABE_NICHT_ERLAUBT';
      end if;
      if not actor_is_approver and not actor_is_admin then
        raise exception 'NUR_FREIGEBER_DARF_FREIGEBEN';
      end if;

    elsif current_row.status = 'zur_freigabe' and p_new_status = 'in_bearbeitung' then
      if not actor_is_approver and not actor_is_admin then
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
     and assignment_row.freigeber_rolle is not null
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

commit;

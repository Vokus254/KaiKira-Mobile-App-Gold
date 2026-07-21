begin;

create schema if not exists private;

create table public.measure_status (
  nr text primary key
    check (nr ~ '^(10|[1-9])[.][0-9]+[A-Z]?$'),
  status text not null default 'offen'
    check (status in ('offen', 'erledigt')),
  updated_by uuid
    references auth.users(id)
    on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.measure_status enable row level security;

create or replace function private.stamp_measure_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    new.updated_by := auth.uid();
    new.updated_at := pg_catalog.now();
  end if;

  return new;
end;
$$;

revoke all on function private.stamp_measure_status() from public;

create trigger measure_status_stamp_update
before update on public.measure_status
for each row
execute function private.stamp_measure_status();

revoke all on table public.measure_status from anon, authenticated;
grant select on table public.measure_status to authenticated;
grant update (status) on table public.measure_status to authenticated;

create policy "measure_status_select_authenticated"
on public.measure_status
for select
to authenticated
using (true);

create policy "measure_status_update_authenticated"
on public.measure_status
for update
to authenticated
using (true)
with check (true);

insert into public.measure_status (nr, status)
values
  ('1.1', 'offen'),
  ('1.2', 'offen'),
  ('1.3', 'offen'),
  ('1.4', 'offen'),
  ('1.5', 'offen'),
  ('1.6', 'offen'),
  ('2.1', 'offen'),
  ('2.2', 'offen'),
  ('2.3', 'offen'),
  ('2.4', 'offen'),
  ('2.5', 'offen'),
  ('2.6', 'offen'),
  ('2.7', 'offen'),
  ('3.1', 'offen'),
  ('3.2', 'offen'),
  ('3.3', 'offen'),
  ('3.4', 'offen'),
  ('3.5', 'offen'),
  ('3.6', 'offen'),
  ('3.7', 'offen'),
  ('3.8', 'offen'),
  ('3.9', 'offen'),
  ('3.10', 'offen'),
  ('3.11', 'offen'),
  ('3.12', 'offen'),
  ('3.13', 'offen'),
  ('3.14', 'offen'),
  ('4.1', 'offen'),
  ('4.2', 'offen'),
  ('4.3', 'offen'),
  ('4.4', 'offen'),
  ('4.5', 'offen'),
  ('4.6', 'offen'),
  ('4.7', 'offen'),
  ('4.8', 'offen'),
  ('5.1', 'offen'),
  ('5.2', 'offen'),
  ('5.3', 'offen'),
  ('5.4', 'offen'),
  ('5.5', 'offen'),
  ('5.6', 'offen'),
  ('5.7', 'offen'),
  ('5.8', 'offen'),
  ('6.1', 'offen'),
  ('6.2', 'offen'),
  ('6.3', 'offen'),
  ('6.4', 'offen'),
  ('6.5', 'offen'),
  ('6.6', 'offen'),
  ('6.7', 'offen'),
  ('6.8', 'offen'),
  ('6.9', 'offen'),
  ('6.10', 'offen'),
  ('6.11', 'offen'),
  ('6.12', 'offen'),
  ('6.13', 'offen'),
  ('6.13A', 'offen'),
  ('6.14', 'offen'),
  ('6.14A', 'offen'),
  ('6.15', 'offen'),
  ('7.1', 'offen'),
  ('7.2', 'offen'),
  ('7.3', 'offen'),
  ('7.4', 'offen'),
  ('7.5', 'offen'),
  ('7.6', 'offen'),
  ('7.7', 'offen'),
  ('7.8', 'offen'),
  ('7.9', 'offen'),
  ('7.10', 'offen'),
  ('7.11', 'offen'),
  ('7.12', 'offen'),
  ('8.1', 'offen'),
  ('8.2', 'offen'),
  ('8.3', 'offen'),
  ('8.4', 'offen'),
  ('8.5', 'offen'),
  ('8.6', 'offen'),
  ('8.7', 'offen'),
  ('8.8', 'offen'),
  ('8.9', 'offen'),
  ('8.10', 'offen'),
  ('9.1', 'offen'),
  ('9.2', 'offen'),
  ('9.3', 'offen'),
  ('9.4', 'offen'),
  ('9.5', 'offen'),
  ('9.6', 'offen'),
  ('9.7', 'offen'),
  ('10.1', 'offen'),
  ('10.2', 'offen'),
  ('10.3', 'offen'),
  ('10.4', 'offen'),
  ('10.5', 'offen');

commit;

-- KaiKira Gold: auditierbarer System-Check für 2.6, 6.1 und 6.2.
-- Das vollständige Core-JSON wird verarbeitet, aber niemals dauerhaft gespeichert.

begin;

do $$
declare constraint_name text;
begin
  for constraint_name in
    select c.conname from pg_catalog.pg_constraint c
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
    'offen', 'in_bearbeitung', 'erledigt', 'zur_freigabe', 'freigegeben', 'nicht_pruefbar'
  ));

create table if not exists public.system_check_runs (
  id bigint generated always as identity primary key,
  exported_at timestamptz,
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  json_format text,
  json_version integer,
  rule_version text not null,
  source_metrics jsonb not null,
  input_checks jsonb not null,
  imported_by uuid not null references auth.users(id) on delete restrict,
  confirmed_at timestamptz not null default pg_catalog.now()
);

create table if not exists public.system_check_results (
  id bigint generated always as identity primary key,
  run_id bigint not null references public.system_check_runs(id) on delete cascade,
  nr text not null check (nr in ('2.6', '6.1', '6.2')),
  previous_status text not null,
  proposed_status text not null check (proposed_status in ('offen', 'erledigt', 'nicht_pruefbar')),
  proof jsonb not null,
  unique (run_id, nr)
);

create table if not exists public.financial_kpi_snapshots (
  run_id bigint primary key references public.system_check_runs(id) on delete cascade,
  balance_bj numeric not null,
  balance_vj numeric not null,
  revenue_bj numeric not null,
  revenue_vj numeric not null,
  ebt_bj numeric not null,
  ebt_vj numeric not null,
  after_tax_bj numeric not null,
  after_tax_vj numeric not null,
  created_at timestamptz not null default pg_catalog.now()
);

alter table public.measure_status add column if not exists system_check_run_id bigint;
do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.measure_status'::pg_catalog.regclass
      and conname = 'measure_status_system_check_run_fk'
  ) then
    alter table public.measure_status
      add constraint measure_status_system_check_run_fk
      foreign key (system_check_run_id) references public.system_check_runs(id) on delete set null;
  end if;
end;
$$;

alter table public.system_check_runs enable row level security;
alter table public.system_check_results enable row level security;
alter table public.financial_kpi_snapshots enable row level security;
revoke all on public.system_check_runs, public.system_check_results, public.financial_kpi_snapshots from anon, authenticated;
grant select on public.system_check_runs, public.system_check_results, public.financial_kpi_snapshots to authenticated;

drop policy if exists "system_check_runs_read_authenticated" on public.system_check_runs;
create policy "system_check_runs_read_authenticated" on public.system_check_runs
  for select to authenticated using (true);
drop policy if exists "system_check_results_read_authenticated" on public.system_check_results;
create policy "system_check_results_read_authenticated" on public.system_check_results
  for select to authenticated using (true);
drop policy if exists "financial_kpi_snapshots_read_authenticated" on public.financial_kpi_snapshots;
create policy "financial_kpi_snapshots_read_authenticated" on public.financial_kpi_snapshots
  for select to authenticated using (true);

create or replace function private.normalize_system_target(p_value text)
returns text language sql immutable set search_path = ''
as $$ select pg_catalog.regexp_replace(pg_catalog.upper(pg_catalog.btrim(coalesce(p_value, ''))), '\s+', '_', 'g') $$;

create or replace function private.system_jsonb_object_count(p_value jsonb)
returns integer language sql immutable set search_path = ''
as $$ select pg_catalog.count(*)::integer from pg_catalog.jsonb_object_keys(coalesce(p_value, '{}'::jsonb)) $$;

create or replace function private.evaluate_system_check(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_susa jsonb := case when pg_catalog.jsonb_typeof(p_payload #> '{core,susa}') = 'array' then p_payload #> '{core,susa}' else '[]'::jsonb end;
  v_mapping jsonb := case when pg_catalog.jsonb_typeof(p_payload #> '{core,mapping}') = 'array' then p_payload #> '{core,mapping}' else '[]'::jsonb end;
  v_structure jsonb := case when pg_catalog.jsonb_typeof(p_payload #> '{core,structure}') = 'array' then p_payload #> '{core,structure}' else '[]'::jsonb end;
  v_snapshot jsonb := case when pg_catalog.jsonb_typeof(p_payload #> '{financialSnapshot,targetAggregates}') = 'object' then p_payload #> '{financialSnapshot,targetAggregates}' else '{}'::jsonb end;
  v_snapshot_normalized jsonb := '{}'::jsonb;
  v_susa_by_account jsonb := '{}'::jsonb;
  v_susa_seen jsonb := '{}'::jsonb;
  v_mapping_seen jsonb := '{}'::jsonb;
  v_structure_targets jsonb := '{}'::jsonb;
  v_asset_targets jsonb := '{}'::jsonb;
  v_liability_targets jsonb := '{}'::jsonb;
  v_income_targets jsonb := '{}'::jsonb;
  v_aggregates jsonb := '{}'::jsonb;
  v_checks jsonb := '[]'::jsonb;
  v_results jsonb;
  v_source_metrics jsonb;
  v_row jsonb;
  v_source jsonb;
  v_levels text;
  v_account text;
  v_target text;
  v_bj numeric;
  v_vj numeric;
  v_count integer;
  v_susa_count integer := pg_catalog.jsonb_array_length(v_susa);
  v_mapping_count integer := pg_catalog.jsonb_array_length(v_mapping);
  v_structure_count integer := pg_catalog.jsonb_array_length(v_structure);
  v_aggregate_count integer := 0;
  v_missing integer := 0;
  v_extra integer := 0;
  v_empty_targets integer := 0;
  v_unknown_targets integer := 0;
  v_snapshot_mismatches integer := 0;
  v_format_ok boolean;
  v_lists_ok boolean;
  v_unique_susa boolean := true;
  v_one_to_one boolean := true;
  v_targets_ok boolean;
  v_structure_ok boolean;
  v_snapshot_ok boolean;
  v_counts_ok boolean;
  v_input_ok boolean;
  v_assets_bj numeric := 0;
  v_assets_vj numeric := 0;
  v_liabilities_bj numeric := 0;
  v_liabilities_vj numeric := 0;
  v_guv_bj numeric := 0;
  v_guv_vj numeric := 0;
  v_annual_bj numeric;
  v_annual_vj numeric;
  v_identity_bj boolean;
  v_identity_vj boolean;
  v_balance_complete boolean := true;
  v_income_complete boolean := true;
  v_no_deviations boolean;
  v_revenue_bj numeric;
  v_revenue_vj numeric;
  v_inventory_bj numeric;
  v_own_bj numeric;
  v_other_income_bj numeric;
  v_material_bj numeric;
  v_personnel_bj numeric;
  v_depreciation_bj numeric;
  v_other_expense_bj numeric;
  v_interest_income_bj numeric;
  v_interest_expense_bj numeric;
  v_income_tax_bj numeric;
  v_other_taxes_bj numeric;
  v_operating_bj numeric;
  v_ebt_bj numeric;
  v_after_tax_bj numeric;
  v_formula_annual_bj numeric;
  v_inventory_vj numeric;
  v_own_vj numeric;
  v_other_income_vj numeric;
  v_material_vj numeric;
  v_personnel_vj numeric;
  v_depreciation_vj numeric;
  v_other_expense_vj numeric;
  v_interest_income_vj numeric;
  v_interest_expense_vj numeric;
  v_income_tax_vj numeric;
  v_other_taxes_vj numeric;
  v_operating_vj numeric;
  v_ebt_vj numeric;
  v_after_tax_vj numeric;
  v_formula_annual_vj numeric;
  v_check_26 boolean;
  v_check_61 boolean;
  v_check_62 boolean;
  v_metrics jsonb := coalesce(p_payload #> '{integrityCheck,metrics}', '{}'::jsonb);
begin
  v_format_ok := p_payload->>'format' = 'kaikira-project-state' and p_payload->>'version' = '4';
  v_lists_ok := v_susa_count > 0 and v_mapping_count > 0 and v_structure_count > 0;

  for v_target, v_row in select key, value from pg_catalog.jsonb_each(v_snapshot) loop
    v_snapshot_normalized := v_snapshot_normalized || pg_catalog.jsonb_build_object(private.normalize_system_target(v_target), v_row);
  end loop;

  for v_row in select value from pg_catalog.jsonb_array_elements(v_susa) loop
    v_account := pg_catalog.btrim(coalesce(v_row->>'konto', ''));
    if v_account = '' or v_susa_seen ? v_account then v_unique_susa := false; end if;
    v_susa_seen := v_susa_seen || pg_catalog.jsonb_build_object(v_account, true);
    v_susa_by_account := v_susa_by_account || pg_catalog.jsonb_build_object(v_account, v_row);
  end loop;
  v_unique_susa := v_unique_susa and v_susa_count > 0;

  for v_row in select value from pg_catalog.jsonb_array_elements(v_structure) loop
    v_target := private.normalize_system_target(v_row->>'ziel');
    if v_target <> '' then
      v_structure_targets := v_structure_targets || pg_catalog.jsonb_build_object(v_target, true);
      v_levels := coalesce(v_row->'levels', '[]'::jsonb)::text;
      if v_levels like '%Aktiva%' then v_asset_targets := v_asset_targets || pg_catalog.jsonb_build_object(v_target, true); end if;
      if v_levels like '%Passiva%' then v_liability_targets := v_liability_targets || pg_catalog.jsonb_build_object(v_target, true); end if;
      if v_levels like '%GuV%' then v_income_targets := v_income_targets || pg_catalog.jsonb_build_object(v_target, true); end if;
    end if;
  end loop;

  for v_row in select value from pg_catalog.jsonb_array_elements(v_mapping) loop
    v_account := pg_catalog.btrim(coalesce(v_row->>'konto', ''));
    v_target := private.normalize_system_target(v_row->>'ziel');
    if v_mapping_seen ? v_account then v_one_to_one := false; end if;
    v_mapping_seen := v_mapping_seen || pg_catalog.jsonb_build_object(v_account, true);
    if not (v_susa_seen ? v_account) then v_extra := v_extra + 1; end if;
    if v_target = '' then v_empty_targets := v_empty_targets + 1; end if;
    if v_target <> '' and not (v_structure_targets ? v_target) then v_unknown_targets := v_unknown_targets + 1; end if;
    v_source := v_susa_by_account->v_account;
    if v_source is not null and v_target <> '' then
      v_bj := (v_source->>'bj')::numeric;
      v_vj := (v_source->>'vj')::numeric;
      v_aggregates := pg_catalog.jsonb_set(v_aggregates, array[v_target], pg_catalog.jsonb_build_object(
        'bj', coalesce((v_aggregates #>> array[v_target,'bj'])::numeric, 0) + v_bj,
        'vj', coalesce((v_aggregates #>> array[v_target,'vj'])::numeric, 0) + v_vj,
        'count', coalesce((v_aggregates #>> array[v_target,'count'])::integer, 0) + 1
      ), true);
    end if;
  end loop;

  select pg_catalog.count(*) into v_missing from pg_catalog.jsonb_object_keys(v_susa_seen) account where not (v_mapping_seen ? account);
  v_one_to_one := v_one_to_one and v_mapping_count = v_susa_count and v_missing = 0 and v_extra = 0;
  v_targets_ok := v_mapping_count > 0 and v_empty_targets = 0;
  v_structure_ok := private.system_jsonb_object_count(v_structure_targets) > 0 and v_unknown_targets = 0;

  for v_target in select key from pg_catalog.jsonb_each(v_aggregates) loop
    v_aggregate_count := v_aggregate_count + (v_aggregates #>> array[v_target,'count'])::integer;
    if not (v_snapshot_normalized ? v_target)
       or pg_catalog.abs((v_aggregates #>> array[v_target,'bj'])::numeric - (v_snapshot_normalized #>> array[v_target,'bj'])::numeric) > 0.01
       or pg_catalog.abs((v_aggregates #>> array[v_target,'vj'])::numeric - (v_snapshot_normalized #>> array[v_target,'vj'])::numeric) > 0.01
       or (v_aggregates #>> array[v_target,'count'])::integer <> (v_snapshot_normalized #>> array[v_target,'count'])::integer then
      v_snapshot_mismatches := v_snapshot_mismatches + 1;
    end if;
  end loop;
  v_snapshot_ok := private.system_jsonb_object_count(v_snapshot_normalized) = private.system_jsonb_object_count(v_aggregates) and v_snapshot_mismatches = 0;
  v_counts_ok := v_aggregate_count = v_susa_count;

  v_checks := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('label','Format und Version','ok',v_format_ok,'detail',coalesce(p_payload->>'format','fehlt') || ', Version ' || coalesce(p_payload->>'version','fehlt')),
    pg_catalog.jsonb_build_object('label','Core-Listen vorhanden','ok',v_lists_ok,'detail',v_susa_count || ' SuSa-, ' || v_mapping_count || ' Mapping-, ' || v_structure_count || ' Strukturzeilen'),
    pg_catalog.jsonb_build_object('label','SuSa-Konten eindeutig','ok',v_unique_susa,'detail',case when v_unique_susa then v_susa_count || ' eindeutige Konten' else 'Leere oder doppelte Kontonummer gefunden' end),
    pg_catalog.jsonb_build_object('label','SuSa und Mapping 1:1','ok',v_one_to_one,'detail',v_missing || ' fehlen, ' || v_extra || ' zusätzlich oder doppelt'),
    pg_catalog.jsonb_build_object('label','Mapping-Ziele befüllt','ok',v_targets_ok,'detail',v_empty_targets || ' leere Ziele'),
    pg_catalog.jsonb_build_object('label','Mapping-Ziele in Struktur','ok',v_structure_ok,'detail',v_unknown_targets || ' unbekannte Ziele'),
    pg_catalog.jsonb_build_object('label','Zielaggregate stimmen mit Snapshot','ok',v_snapshot_ok,'detail',v_snapshot_mismatches || ' Abweichungen bei 0,01 EUR Toleranz'),
    pg_catalog.jsonb_build_object('label','Aggregat-Zeilen vollständig','ok',v_counts_ok,'detail',v_aggregate_count || ' aggregierte von ' || v_susa_count || ' SuSa-Zeilen')
  );
  v_input_ok := v_format_ok and v_lists_ok and v_unique_susa and v_one_to_one and v_targets_ok and v_structure_ok and v_snapshot_ok and v_counts_ok;
  v_source_metrics := pg_catalog.jsonb_build_object('susaRows',v_susa_count,'mappingRows',v_mapping_count,'structureRows',v_structure_count,'aggregateTargets',private.system_jsonb_object_count(v_aggregates));

  if not v_input_ok then
    v_results := pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('nr','2.6','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Eingangskontrolle fehlgeschlagen')),
      pg_catalog.jsonb_build_object('nr','6.1','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Eingangskontrolle fehlgeschlagen')),
      pg_catalog.jsonb_build_object('nr','6.2','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Eingangskontrolle fehlgeschlagen'))
    );
    return pg_catalog.jsonb_build_object('inputOk',false,'inputChecks',v_checks,'sourceMetrics',v_source_metrics,'results',v_results);
  end if;

  select coalesce(pg_catalog.sum((v_aggregates #>> array[key,'bj'])::numeric),0), coalesce(pg_catalog.sum((v_aggregates #>> array[key,'vj'])::numeric),0)
    into v_assets_bj, v_assets_vj from pg_catalog.jsonb_object_keys(v_asset_targets) key;
  select coalesce(pg_catalog.sum((v_aggregates #>> array[key,'bj'])::numeric),0), coalesce(pg_catalog.sum((v_aggregates #>> array[key,'vj'])::numeric),0)
    into v_liabilities_bj, v_liabilities_vj from pg_catalog.jsonb_object_keys(v_liability_targets) key;
  select coalesce(pg_catalog.sum((v_aggregates #>> array[key,'bj'])::numeric),0), coalesce(pg_catalog.sum((v_aggregates #>> array[key,'vj'])::numeric),0)
    into v_guv_bj, v_guv_vj from pg_catalog.jsonb_object_keys(v_income_targets) key;
  select pg_catalog.bool_and(v_aggregates ? key) into v_balance_complete from (
    select key from pg_catalog.jsonb_object_keys(v_asset_targets) key union select key from pg_catalog.jsonb_object_keys(v_liability_targets) key
  ) targets;
  select pg_catalog.bool_and(v_aggregates ? key) into v_income_complete from pg_catalog.jsonb_object_keys(v_income_targets) key;

  v_annual_bj := -v_guv_bj; v_annual_vj := -v_guv_vj;
  v_identity_bj := pg_catalog.abs((v_assets_bj + v_liabilities_bj) - v_annual_bj) <= 0.01;
  v_identity_vj := pg_catalog.abs((v_assets_vj + v_liabilities_vj) - v_annual_vj) <= 0.01;
  v_no_deviations := coalesce(pg_catalog.jsonb_array_length(case when pg_catalog.jsonb_typeof(p_payload #> '{integrityCheck,deviations}')='array' then p_payload #> '{integrityCheck,deviations}' else '[]'::jsonb end),0)=0
    and coalesce((p_payload #>> '{integrityCheck,totalDeviations}')::integer,0)=0;
  v_revenue_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_UE,bj}')::numeric,0));
  v_revenue_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_UE,vj}')::numeric,0));
  v_inventory_bj := -coalesce((v_aggregates #>> '{G_BEST,bj}')::numeric,0);
  v_own_bj := -coalesce((v_aggregates #>> '{G_AEL,bj}')::numeric,0);
  v_other_income_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_SBE,bj}')::numeric,0));
  v_material_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_MAT_A,bj}')::numeric,0))+pg_catalog.abs(coalesce((v_aggregates #>> '{G_MAT_B,bj}')::numeric,0));
  v_personnel_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_PA_A,bj}')::numeric,0))+pg_catalog.abs(coalesce((v_aggregates #>> '{G_PA_B,bj}')::numeric,0));
  v_depreciation_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_AFA,bj}')::numeric,0));
  v_other_expense_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_SBA,bj}')::numeric,0));
  v_interest_income_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_ZE,bj}')::numeric,0));
  v_interest_expense_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_ZA,bj}')::numeric,0));
  v_income_tax_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_ST,bj}')::numeric,0));
  v_other_taxes_bj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_SST,bj}')::numeric,0));
  v_operating_bj := v_revenue_bj+v_inventory_bj+v_own_bj+v_other_income_bj-v_material_bj-v_personnel_bj-v_depreciation_bj-v_other_expense_bj;
  v_ebt_bj := v_operating_bj+v_interest_income_bj-v_interest_expense_bj;
  v_after_tax_bj := v_ebt_bj-v_income_tax_bj;
  v_formula_annual_bj := v_after_tax_bj-v_other_taxes_bj;
  v_inventory_vj := -coalesce((v_aggregates #>> '{G_BEST,vj}')::numeric,0);
  v_own_vj := -coalesce((v_aggregates #>> '{G_AEL,vj}')::numeric,0);
  v_other_income_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_SBE,vj}')::numeric,0));
  v_material_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_MAT_A,vj}')::numeric,0))+pg_catalog.abs(coalesce((v_aggregates #>> '{G_MAT_B,vj}')::numeric,0));
  v_personnel_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_PA_A,vj}')::numeric,0))+pg_catalog.abs(coalesce((v_aggregates #>> '{G_PA_B,vj}')::numeric,0));
  v_depreciation_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_AFA,vj}')::numeric,0));
  v_other_expense_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_SBA,vj}')::numeric,0));
  v_interest_income_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_ZE,vj}')::numeric,0));
  v_interest_expense_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_ZA,vj}')::numeric,0));
  v_income_tax_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_ST,vj}')::numeric,0));
  v_other_taxes_vj := pg_catalog.abs(coalesce((v_aggregates #>> '{G_SST,vj}')::numeric,0));
  v_operating_vj := v_revenue_vj+v_inventory_vj+v_own_vj+v_other_income_vj-v_material_vj-v_personnel_vj-v_depreciation_vj-v_other_expense_vj;
  v_ebt_vj := v_operating_vj+v_interest_income_vj-v_interest_expense_vj;
  v_after_tax_vj := v_ebt_vj-v_income_tax_vj;
  v_formula_annual_vj := v_after_tax_vj-v_other_taxes_vj;
  v_check_26 := v_identity_bj and v_identity_vj;
  v_check_61 := v_balance_complete and v_check_26 and v_no_deviations
    and pg_catalog.abs((v_metrics->>'balanceBJ')::numeric-v_assets_bj)<=0.01 and pg_catalog.abs((v_metrics->>'balanceVJ')::numeric-v_assets_vj)<=0.01;
  v_check_62 := v_income_complete and v_no_deviations and pg_catalog.abs(v_formula_annual_bj-v_annual_bj)<=0.01 and pg_catalog.abs(v_formula_annual_vj-v_annual_vj)<=0.01
    and pg_catalog.abs((v_metrics->>'revenueBJ')::numeric-v_revenue_bj)<=0.01 and pg_catalog.abs((v_metrics->>'revenueVJ')::numeric-v_revenue_vj)<=0.01
    and pg_catalog.abs((v_metrics->>'ebtBJ')::numeric-v_ebt_bj)<=0.01 and pg_catalog.abs((v_metrics->>'afterTaxBJ')::numeric-v_after_tax_bj)<=0.01;

  v_results := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('nr','2.6','status',case when v_check_26 then 'erledigt' else 'offen' end,'proof',pg_catalog.jsonb_build_object('assetsBJ',v_assets_bj,'assetsVJ',v_assets_vj,'liabilitiesBJ',v_liabilities_bj,'liabilitiesVJ',v_liabilities_vj,'annualBJ',v_annual_bj,'annualVJ',v_annual_vj)),
    pg_catalog.jsonb_build_object('nr','6.1','status',case when v_check_61 then 'erledigt' else 'offen' end,'proof',pg_catalog.jsonb_build_object('balanceBJ',v_assets_bj,'balanceVJ',v_assets_vj,'balanceTargets',private.system_jsonb_object_count(v_asset_targets)+private.system_jsonb_object_count(v_liability_targets))),
    pg_catalog.jsonb_build_object('nr','6.2','status',case when v_check_62 then 'erledigt' else 'offen' end,'proof',pg_catalog.jsonb_build_object('revenueBJ',v_revenue_bj,'revenueVJ',v_revenue_vj,'ebtBJ',v_ebt_bj,'ebtVJ',v_ebt_vj,'afterTaxBJ',v_after_tax_bj,'afterTaxVJ',v_after_tax_vj,'annualBJ',v_annual_bj,'annualVJ',v_annual_vj))
  );
  return pg_catalog.jsonb_build_object(
    'inputOk',true,
    'inputChecks',v_checks,
    'sourceMetrics',v_source_metrics,
    'financialKpis',pg_catalog.jsonb_build_object('balanceBJ',v_assets_bj,'balanceVJ',v_assets_vj,'revenueBJ',v_revenue_bj,'revenueVJ',v_revenue_vj,'ebtBJ',v_ebt_bj,'ebtVJ',v_ebt_vj,'afterTaxBJ',v_after_tax_bj,'afterTaxVJ',v_after_tax_vj),
    'results',v_results
  );
exception when others then
  v_checks := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('label','Format und Version','ok',false,'detail','JSON-Struktur nicht auswertbar'),
    pg_catalog.jsonb_build_object('label','Core-Listen vorhanden','ok',false,'detail','JSON-Struktur nicht auswertbar'),
    pg_catalog.jsonb_build_object('label','SuSa-Konten eindeutig','ok',false,'detail','JSON-Struktur nicht auswertbar'),
    pg_catalog.jsonb_build_object('label','SuSa und Mapping 1:1','ok',false,'detail','JSON-Struktur nicht auswertbar'),
    pg_catalog.jsonb_build_object('label','Mapping-Ziele befüllt','ok',false,'detail','JSON-Struktur nicht auswertbar'),
    pg_catalog.jsonb_build_object('label','Mapping-Ziele in Struktur','ok',false,'detail','JSON-Struktur nicht auswertbar'),
    pg_catalog.jsonb_build_object('label','Zielaggregate stimmen mit Snapshot','ok',false,'detail','JSON-Struktur nicht auswertbar'),
    pg_catalog.jsonb_build_object('label','Aggregat-Zeilen vollständig','ok',false,'detail','JSON-Struktur nicht auswertbar')
  );
  v_results := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('nr','2.6','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Serverseitige Auswertung nicht möglich')),
    pg_catalog.jsonb_build_object('nr','6.1','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Serverseitige Auswertung nicht möglich')),
    pg_catalog.jsonb_build_object('nr','6.2','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Serverseitige Auswertung nicht möglich'))
  );
  return pg_catalog.jsonb_build_object('inputOk',false,'inputChecks',v_checks,'sourceMetrics',pg_catalog.jsonb_build_object('errorClass',sqlstate,'errorMessage',sqlerrm),'results',v_results);
end;
$$;

create or replace function public.apply_system_check(p_payload jsonb, p_file_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_evaluation jsonb;
  v_kpis jsonb;
  v_run_id bigint;
  v_result jsonb;
  v_previous text;
  v_exported_at timestamptz;
  v_version integer;
begin
  if v_actor is null then raise exception 'ANMELDUNG_ERFORDERLICH'; end if;
  if not private.is_people_admin() then raise exception 'NUR_ADMIN_DARF_SYSTEM_CHECK_AUSFUEHREN'; end if;
  if p_file_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'UNGUELTIGER_DATEI_HASH'; end if;
  v_evaluation := private.evaluate_system_check(p_payload);
  begin v_exported_at := (p_payload->>'exportedAt')::timestamptz; exception when others then v_exported_at := null; end;
  begin v_version := (p_payload->>'version')::integer; exception when others then v_version := null; end;

  insert into public.system_check_runs(exported_at,file_sha256,json_format,json_version,rule_version,source_metrics,input_checks,imported_by)
  values(v_exported_at,p_file_sha256,p_payload->>'format',v_version,'core-json-check-v2',v_evaluation->'sourceMetrics',v_evaluation->'inputChecks',v_actor)
  returning id into v_run_id;

  v_kpis := v_evaluation->'financialKpis';
  if (v_evaluation->>'inputOk')::boolean and v_kpis is not null then
    insert into public.financial_kpi_snapshots(
      run_id,balance_bj,balance_vj,revenue_bj,revenue_vj,ebt_bj,ebt_vj,after_tax_bj,after_tax_vj
    ) values (
      v_run_id,
      (v_kpis->>'balanceBJ')::numeric,(v_kpis->>'balanceVJ')::numeric,
      (v_kpis->>'revenueBJ')::numeric,(v_kpis->>'revenueVJ')::numeric,
      (v_kpis->>'ebtBJ')::numeric,(v_kpis->>'ebtVJ')::numeric,
      (v_kpis->>'afterTaxBJ')::numeric,(v_kpis->>'afterTaxVJ')::numeric
    );
  end if;

  for v_result in select value from pg_catalog.jsonb_array_elements(v_evaluation->'results') loop
    select status into v_previous from public.measure_status where nr=v_result->>'nr' for update;
    insert into public.system_check_results(run_id,nr,previous_status,proposed_status,proof)
    values(v_run_id,v_result->>'nr',v_previous,v_result->>'status',v_result->'proof');
    update public.measure_status set status=v_result->>'status', system_check_run_id=v_run_id where nr=v_result->>'nr';
  end loop;
  return v_evaluation || pg_catalog.jsonb_build_object('runId',v_run_id);
end;
$$;

revoke all on function private.evaluate_system_check(jsonb) from public, anon, authenticated;
revoke all on function private.system_jsonb_object_count(jsonb) from public, anon, authenticated;
revoke all on function public.apply_system_check(jsonb,text) from public, anon;
grant execute on function public.apply_system_check(jsonb,text) to authenticated;

commit;

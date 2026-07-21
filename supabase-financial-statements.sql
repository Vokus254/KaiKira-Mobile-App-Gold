-- KaiKira Gold: vollständige Bilanz-/GuV-Hierarchie aus demselben bestätigten System-Check.
-- Das vollständige Core-JSON wird nur innerhalb der RPC-Transaktion verarbeitet und nicht gespeichert.

begin;

create table if not exists public.financial_statement_snapshots (
  run_id bigint primary key references public.system_check_runs(id) on delete cascade,
  balance_positions jsonb not null check (pg_catalog.jsonb_typeof(balance_positions) = 'array'),
  income_statement_positions jsonb not null check (pg_catalog.jsonb_typeof(income_statement_positions) = 'array'),
  validation jsonb not null check (pg_catalog.jsonb_typeof(validation) = 'object'),
  created_at timestamptz not null default pg_catalog.now()
);

create table if not exists public.financial_statement_accounts (
  run_id bigint not null references public.financial_statement_snapshots(run_id) on delete cascade,
  position_id text not null,
  account_no text not null,
  account_name text not null,
  bj numeric not null,
  vj numeric not null,
  source_index integer not null check (source_index > 0),
  primary key (run_id, position_id, account_no)
);

create index if not exists financial_statement_accounts_leaf_idx
  on public.financial_statement_accounts(run_id, position_id, source_index);

alter table public.financial_statement_snapshots enable row level security;
alter table public.financial_statement_accounts enable row level security;
revoke all on public.financial_statement_snapshots, public.financial_statement_accounts from anon, authenticated;
grant select on public.financial_statement_snapshots, public.financial_statement_accounts to authenticated;

drop policy if exists "financial_statement_snapshots_read_authenticated" on public.financial_statement_snapshots;
create policy "financial_statement_snapshots_read_authenticated" on public.financial_statement_snapshots
  for select to authenticated using (true);
drop policy if exists "financial_statement_accounts_read_authenticated" on public.financial_statement_accounts;
create policy "financial_statement_accounts_read_authenticated" on public.financial_statement_accounts
  for select to authenticated using (true);

create or replace function private.normalize_system_label(p_value text)
returns text language sql immutable set search_path = ''
as $$
  select pg_catalog.btrim(pg_catalog.regexp_replace(
    pg_catalog.translate(pg_catalog.lower(pg_catalog.btrim(coalesce(p_value, ''))),
      'äöüßáàâãåéèêëíìîïóòôõúùûüçñ',
      'aousaaaaaeeeeiiiioooouuuucn'),
    '[^a-z0-9]+', ' ', 'g'))
$$;

create or replace function private.normalize_system_account(p_value text)
returns text language sql immutable set search_path = ''
as $$ select pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_value, '')), '\.0$', '') $$;

create or replace function private.system_nonempty_levels(p_levels jsonb)
returns jsonb language sql immutable set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(value order by ordinality), '[]'::jsonb)
  from pg_catalog.jsonb_array_elements_text(
    case when pg_catalog.jsonb_typeof(p_levels) = 'array' then p_levels else '[]'::jsonb end
  ) with ordinality
  where pg_catalog.btrim(value) <> ''
$$;

create or replace function private.system_level_prefix(p_levels jsonb, p_depth integer)
returns jsonb language sql immutable set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(value order by ordinality), '[]'::jsonb)
  from pg_catalog.jsonb_array_elements_text(private.system_nonempty_levels(p_levels)) with ordinality
  where ordinality <= p_depth
$$;

create or replace function private.system_path_key(p_levels jsonb, p_target text default '')
returns text language sql immutable set search_path = ''
as $$
  select coalesce(pg_catalog.string_agg(private.normalize_system_label(value), '||' order by ordinality), '')
    || '##' || private.normalize_system_label(p_target)
  from pg_catalog.jsonb_array_elements_text(private.system_nonempty_levels(p_levels)) with ordinality
$$;

create or replace function private.build_financial_statements(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_susa jsonb := case when pg_catalog.jsonb_typeof(p_payload #> '{core,susa}') = 'array' then p_payload #> '{core,susa}' else '[]'::jsonb end;
  v_mapping jsonb := case when pg_catalog.jsonb_typeof(p_payload #> '{core,mapping}') = 'array' then p_payload #> '{core,mapping}' else '[]'::jsonb end;
  v_structure jsonb := case when pg_catalog.jsonb_typeof(p_payload #> '{core,structure}') = 'array' then p_payload #> '{core,structure}' else '[]'::jsonb end;
  v_susa_by_account jsonb := '{}'::jsonb;
  v_exact jsonb := '{}'::jsonb;
  v_by_target jsonb := '{}'::jsonb;
  v_balance_map jsonb := '{}'::jsonb;
  v_income_map jsonb := '{}'::jsonb;
  v_balance_order jsonb := '[]'::jsonb;
  v_income_order jsonb := '[]'::jsonb;
  v_balance_positions jsonb := '[]'::jsonb;
  v_income_positions jsonb := '[]'::jsonb;
  v_accounts jsonb := '[]'::jsonb;
  v_row jsonb;
  v_candidate jsonb;
  v_candidates jsonb;
  v_resolved jsonb;
  v_source jsonb;
  v_parts jsonb;
  v_prefix jsonb;
  v_position jsonb;
  v_key text;
  v_parent_key text;
  v_target text;
  v_account text;
  v_top text;
  v_kind text;
  v_deepest text;
  v_label text;
  v_depth integer;
  v_depth_count integer;
  v_match_count integer;
  v_bj numeric;
  v_vj numeric;
  v_resolved_count integer := 0;
  v_unresolved_count integer := 0;
  v_ambiguous_count integer := 0;
  v_duplicate_count integer := 0;
  v_balance_sort integer := 0;
  v_income_sort integer := 0;
  v_ok boolean;
begin
  for v_row in
    select value || pg_catalog.jsonb_build_object('_sourceIndex',ordinality)
    from pg_catalog.jsonb_array_elements(v_susa) with ordinality
  loop
    v_account := private.normalize_system_account(v_row->>'konto');
    v_susa_by_account := v_susa_by_account || pg_catalog.jsonb_build_object(v_account, v_row);
  end loop;

  for v_row in select value from pg_catalog.jsonb_array_elements(v_structure) loop
    v_parts := private.system_nonempty_levels(v_row->'levels');
    if pg_catalog.jsonb_array_length(v_parts) = 0 then continue; end if;
    v_target := private.normalize_system_label(v_row->>'ziel');
    v_key := private.system_path_key(v_parts, v_row->>'ziel');
    if v_exact ? v_key then v_duplicate_count := v_duplicate_count + 1; end if;
    v_exact := v_exact || pg_catalog.jsonb_build_object(v_key, v_row);
    v_candidates := coalesce(v_by_target->v_target, '[]'::jsonb) || pg_catalog.jsonb_build_array(v_row);
    v_by_target := pg_catalog.jsonb_set(v_by_target, array[v_target], v_candidates, true);

    v_top := private.normalize_system_label(v_parts->>0);
    v_kind := case
      when v_top like '%bilanz%' then 'balance'
      when v_top like '%guv%' or v_top like '%gewinn%' or v_top like '%verlust%' then 'income'
      else null
    end;
    if v_kind is null then continue; end if;
    v_depth_count := pg_catalog.jsonb_array_length(v_parts);
    for v_depth in 1..v_depth_count loop
      v_prefix := private.system_level_prefix(v_parts, v_depth);
      v_key := private.system_path_key(v_prefix, '');
      v_parent_key := case when v_depth > 1 then private.system_path_key(private.system_level_prefix(v_parts, v_depth - 1), '') else null end;
      v_label := v_prefix->>(v_depth - 1);
      if v_kind = 'balance' and not (v_balance_map ? v_key) then
        v_balance_sort := v_balance_sort + 1;
        v_position := pg_catalog.jsonb_build_object(
          'positionId','balance:'||v_key,'parentId',case when v_parent_key is null then null else 'balance:'||v_parent_key end,
          'sortIndex',v_balance_sort,'depth',v_depth,'label',v_label,'bj',0,'vj',0,'accountCount',0,'childCount',0
        );
        v_balance_map := pg_catalog.jsonb_set(v_balance_map, array[v_key], v_position, true);
        v_balance_order := v_balance_order || pg_catalog.to_jsonb(v_key);
        if v_parent_key is not null and v_balance_map ? v_parent_key then
          v_position := v_balance_map->v_parent_key;
          v_position := pg_catalog.jsonb_set(v_position,'{childCount}',pg_catalog.to_jsonb((v_position->>'childCount')::integer+1));
          v_balance_map := pg_catalog.jsonb_set(v_balance_map,array[v_parent_key],v_position,true);
        end if;
      elsif v_kind = 'income' and not (v_income_map ? v_key) then
        v_income_sort := v_income_sort + 1;
        v_position := pg_catalog.jsonb_build_object(
          'positionId','income:'||v_key,'parentId',case when v_parent_key is null then null else 'income:'||v_parent_key end,
          'sortIndex',v_income_sort,'depth',v_depth,'label',v_label,'bj',0,'vj',0,'accountCount',0,'childCount',0
        );
        v_income_map := pg_catalog.jsonb_set(v_income_map, array[v_key], v_position, true);
        v_income_order := v_income_order || pg_catalog.to_jsonb(v_key);
        if v_parent_key is not null and v_income_map ? v_parent_key then
          v_position := v_income_map->v_parent_key;
          v_position := pg_catalog.jsonb_set(v_position,'{childCount}',pg_catalog.to_jsonb((v_position->>'childCount')::integer+1));
          v_income_map := pg_catalog.jsonb_set(v_income_map,array[v_parent_key],v_position,true);
        end if;
      end if;
    end loop;
  end loop;

  for v_row in select value from pg_catalog.jsonb_array_elements(v_mapping) loop
    v_parts := private.system_nonempty_levels(v_row->'levels');
    v_target := private.normalize_system_label(v_row->>'ziel');
    v_resolved := v_exact->private.system_path_key(v_parts, v_row->>'ziel');
    if v_resolved is null then
      v_candidates := coalesce(v_by_target->v_target, '[]'::jsonb);
      if pg_catalog.jsonb_array_length(v_candidates) = 1 then
        v_resolved := v_candidates->0;
      elsif pg_catalog.jsonb_array_length(v_candidates) > 1 then
        select value into v_deepest
        from pg_catalog.jsonb_array_elements_text(v_parts) with ordinality
        order by ordinality desc limit 1;
        v_match_count := 0;
        for v_candidate in select value from pg_catalog.jsonb_array_elements(v_candidates) loop
          if exists (
            select 1 from pg_catalog.jsonb_array_elements_text(private.system_nonempty_levels(v_candidate->'levels')) level
            where private.normalize_system_label(level) = private.normalize_system_label(v_deepest)
          ) then
            v_match_count := v_match_count + 1;
            v_resolved := v_candidate;
          end if;
        end loop;
        if v_match_count <> 1 then
          v_resolved := null;
          v_ambiguous_count := v_ambiguous_count + 1;
        end if;
      end if;
    end if;

    v_account := private.normalize_system_account(v_row->>'konto');
    v_source := v_susa_by_account->v_account;
    if v_resolved is null or v_source is null then
      v_unresolved_count := v_unresolved_count + 1;
      continue;
    end if;
    begin
      v_bj := (v_source->>'bj')::numeric;
      v_vj := (v_source->>'vj')::numeric;
    exception when others then
      v_unresolved_count := v_unresolved_count + 1;
      continue;
    end;
    v_parts := private.system_nonempty_levels(v_resolved->'levels');
    v_top := private.normalize_system_label(v_parts->>0);
    v_kind := case
      when v_top like '%bilanz%' then 'balance'
      when v_top like '%guv%' or v_top like '%gewinn%' or v_top like '%verlust%' then 'income'
      else null
    end;
    if v_kind is null then
      v_unresolved_count := v_unresolved_count + 1;
      continue;
    end if;
    v_resolved_count := v_resolved_count + 1;
    v_depth_count := pg_catalog.jsonb_array_length(v_parts);
    v_key := private.system_path_key(v_parts,'');
    v_accounts := v_accounts || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'positionId',v_kind||':'||v_key,
      'accountNo',v_account,
      'accountName',coalesce(v_source->>'bezeichnung',''),
      'bj',v_bj,
      'vj',v_vj,
      'sourceIndex',(v_source->>'_sourceIndex')::integer
    ));
    for v_depth in 1..v_depth_count loop
      v_key := private.system_path_key(private.system_level_prefix(v_parts,v_depth),'');
      v_position := case when v_kind='balance' then v_balance_map->v_key else v_income_map->v_key end;
      v_position := pg_catalog.jsonb_set(v_position,'{bj}',pg_catalog.to_jsonb((v_position->>'bj')::numeric+v_bj));
      v_position := pg_catalog.jsonb_set(v_position,'{vj}',pg_catalog.to_jsonb((v_position->>'vj')::numeric+v_vj));
      v_position := pg_catalog.jsonb_set(v_position,'{accountCount}',pg_catalog.to_jsonb((v_position->>'accountCount')::integer+1));
      if v_kind='balance' then
        v_balance_map := pg_catalog.jsonb_set(v_balance_map,array[v_key],v_position,true);
      else
        v_income_map := pg_catalog.jsonb_set(v_income_map,array[v_key],v_position,true);
      end if;
    end loop;
  end loop;

  for v_key in select value from pg_catalog.jsonb_array_elements_text(v_balance_order) loop
    v_position := v_balance_map->v_key;
    v_balance_positions := v_balance_positions || pg_catalog.jsonb_build_array(
      (v_position - 'childCount') || pg_catalog.jsonb_build_object('isLeaf',(v_position->>'childCount')::integer=0)
    );
  end loop;
  for v_key in select value from pg_catalog.jsonb_array_elements_text(v_income_order) loop
    v_position := v_income_map->v_key;
    v_income_positions := v_income_positions || pg_catalog.jsonb_build_array(
      (v_position - 'childCount') || pg_catalog.jsonb_build_object('isLeaf',(v_position->>'childCount')::integer=0)
    );
  end loop;

  v_ok := v_duplicate_count=0 and v_unresolved_count=0 and v_ambiguous_count=0
    and v_resolved_count=pg_catalog.jsonb_array_length(v_mapping)
    and pg_catalog.jsonb_array_length(v_accounts)=v_resolved_count
    and pg_catalog.jsonb_array_length(v_balance_positions)>0 and pg_catalog.jsonb_array_length(v_income_positions)>0;
  return pg_catalog.jsonb_build_object(
    'ok',v_ok,
    'balancePositions',v_balance_positions,
    'incomeStatementPositions',v_income_positions,
    'accounts',v_accounts,
    'validation',pg_catalog.jsonb_build_object(
      'ruleVersion','core-hierarchy-v2','structureRows',pg_catalog.jsonb_array_length(v_structure),
      'resolvedAccounts',v_resolved_count,'unresolvedAccounts',v_unresolved_count,'ambiguousAccounts',v_ambiguous_count,
      'duplicateExactPaths',v_duplicate_count,'balancePositionCount',pg_catalog.jsonb_array_length(v_balance_positions),
      'incomePositionCount',pg_catalog.jsonb_array_length(v_income_positions),'accountRowCount',pg_catalog.jsonb_array_length(v_accounts)
    )
  );
end;
$$;

create or replace function private.evaluate_system_check_v3(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base jsonb := private.evaluate_system_check(p_payload);
  v_statements jsonb := private.build_financial_statements(p_payload);
  v_checks jsonb := coalesce(v_base->'inputChecks','[]'::jsonb);
  v_validation jsonb := v_statements->'validation';
  v_hierarchy_ok boolean := coalesce((v_statements->>'ok')::boolean,false);
  v_strict_ok boolean := coalesce((v_base->>'inputOk')::boolean,false) and v_hierarchy_ok;
  v_results jsonb;
begin
  if pg_catalog.jsonb_array_length(v_checks) >= 6 then
    v_checks := pg_catalog.jsonb_set(v_checks,'{5}',pg_catalog.jsonb_build_object(
      'label','Mapping-Ziele und Gliederung eindeutig','ok',v_hierarchy_ok,
      'detail',case when v_hierarchy_ok
        then (v_validation->>'resolvedAccounts')||' Konten in '||
          ((v_validation->>'balancePositionCount')::integer+(v_validation->>'incomePositionCount')::integer)||' Positionen eindeutig aufgelöst'
        else (v_validation->>'unresolvedAccounts')||' nicht auflösbar, '||(v_validation->>'ambiguousAccounts')||
          ' mehrdeutig, '||(v_validation->>'duplicateExactPaths')||' doppelte Strukturpfade' end
    ),false);
  end if;
  if v_strict_ok then
    return (v_base || pg_catalog.jsonb_build_object('inputOk',true,'inputChecks',v_checks,'financialStatements',v_statements));
  end if;
  v_results := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('nr','2.6','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Eingangskontrolle oder eindeutige Vollhierarchie fehlgeschlagen')),
    pg_catalog.jsonb_build_object('nr','6.1','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','Bilanzhierarchie nicht vollständig eindeutig auflösbar')),
    pg_catalog.jsonb_build_object('nr','6.2','status','nicht_pruefbar','proof',pg_catalog.jsonb_build_object('reason','GuV-Hierarchie nicht vollständig eindeutig auflösbar'))
  );
  return v_base || pg_catalog.jsonb_build_object('inputOk',false,'inputChecks',v_checks,'financialStatements',v_statements,'results',v_results);
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
  v_statements jsonb;
  v_accounts jsonb;
  v_run_id bigint;
  v_result jsonb;
  v_previous text;
  v_exported_at timestamptz;
  v_version integer;
begin
  if v_actor is null then raise exception 'ANMELDUNG_ERFORDERLICH'; end if;
  if not private.is_people_admin() then raise exception 'NUR_ADMIN_DARF_SYSTEM_CHECK_AUSFUEHREN'; end if;
  if p_file_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'UNGUELTIGER_DATEI_HASH'; end if;
  v_evaluation := private.evaluate_system_check_v3(p_payload);
  begin v_exported_at := (p_payload->>'exportedAt')::timestamptz; exception when others then v_exported_at := null; end;
  begin v_version := (p_payload->>'version')::integer; exception when others then v_version := null; end;

  insert into public.system_check_runs(exported_at,file_sha256,json_format,json_version,rule_version,source_metrics,input_checks,imported_by)
  values(v_exported_at,p_file_sha256,p_payload->>'format',v_version,'core-json-check-v4',v_evaluation->'sourceMetrics',v_evaluation->'inputChecks',v_actor)
  returning id into v_run_id;

  v_kpis := v_evaluation->'financialKpis';
  v_statements := v_evaluation->'financialStatements';
  v_accounts := v_statements->'accounts';
  if (v_evaluation->>'inputOk')::boolean and v_kpis is not null and coalesce((v_statements->>'ok')::boolean,false) then
    insert into public.financial_kpi_snapshots(
      run_id,balance_bj,balance_vj,revenue_bj,revenue_vj,ebt_bj,ebt_vj,after_tax_bj,after_tax_vj
    ) values (
      v_run_id,(v_kpis->>'balanceBJ')::numeric,(v_kpis->>'balanceVJ')::numeric,
      (v_kpis->>'revenueBJ')::numeric,(v_kpis->>'revenueVJ')::numeric,
      (v_kpis->>'ebtBJ')::numeric,(v_kpis->>'ebtVJ')::numeric,
      (v_kpis->>'afterTaxBJ')::numeric,(v_kpis->>'afterTaxVJ')::numeric
    );
    insert into public.financial_statement_snapshots(run_id,balance_positions,income_statement_positions,validation)
    values(v_run_id,v_statements->'balancePositions',v_statements->'incomeStatementPositions',v_statements->'validation');
    insert into public.financial_statement_accounts(run_id,position_id,account_no,account_name,bj,vj,source_index)
    select v_run_id,a->>'positionId',a->>'accountNo',a->>'accountName',
      (a->>'bj')::numeric,(a->>'vj')::numeric,(a->>'sourceIndex')::integer
    from pg_catalog.jsonb_array_elements(v_accounts) a;
  end if;

  for v_result in select value from pg_catalog.jsonb_array_elements(v_evaluation->'results') loop
    select status into v_previous from public.measure_status where nr=v_result->>'nr' for update;
    insert into public.system_check_results(run_id,nr,previous_status,proposed_status,proof)
    values(v_run_id,v_result->>'nr',v_previous,v_result->>'status',v_result->'proof');
    update public.measure_status set status=v_result->>'status', system_check_run_id=v_run_id where nr=v_result->>'nr';
  end loop;
  return (v_evaluation - 'financialStatements') || pg_catalog.jsonb_build_object('runId',v_run_id);
end;
$$;

revoke all on function private.normalize_system_label(text) from public, anon, authenticated;
revoke all on function private.normalize_system_account(text) from public, anon, authenticated;
revoke all on function private.system_nonempty_levels(jsonb) from public, anon, authenticated;
revoke all on function private.system_level_prefix(jsonb,integer) from public, anon, authenticated;
revoke all on function private.system_path_key(jsonb,text) from public, anon, authenticated;
revoke all on function private.build_financial_statements(jsonb) from public, anon, authenticated;
revoke all on function private.evaluate_system_check_v3(jsonb) from public, anon, authenticated;
revoke all on function public.apply_system_check(jsonb,text) from public, anon;
grant execute on function public.apply_system_check(jsonb,text) to authenticated;

commit;

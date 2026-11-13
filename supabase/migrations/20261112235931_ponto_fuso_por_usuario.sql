alter table public.profiles add column if not exists fuso text not null default 'America/Sao_Paulo'
  check (fuso in ('America/Noronha','America/Sao_Paulo','America/Manaus','America/Rio_Branco'));

-- Marcação: horário sempre definido pelo servidor, no fuso do colaborador
create or replace function public.registrar_ponto(
  p_lat double precision default null, p_lng double precision default null,
  p_precisao double precision default null, p_geo text default null, p_forcar boolean default false)
returns public.punches
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_prof public.profiles;
  v_now timestamp;
  v_last timestamptz;
  v_cfg public.config;
  r public.punches;
begin
  if v_uid is null then raise exception 'nao_autenticado'; end if;
  select * into v_prof from public.profiles where id = v_uid and ativo;
  if not found then raise exception 'usuario_inativo'; end if;
  v_now := date_trunc('second', now() at time zone v_prof.fuso);
  select * into v_cfg from public.config where id = 1;
  if p_lat is not null and (p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180) then
    raise exception 'coordenadas_invalidas';
  end if;
  if v_cfg.exigir_gps and p_lat is null then raise exception 'gps_obrigatorio'; end if;
  if p_lat is not null then p_geo := 'ok';
  elsif p_geo is null or p_geo not in ('negado','indisponivel','timeout') then p_geo := 'indisponivel';
  end if;
  if not p_forcar then
    select max(created_at) into v_last from public.punches
      where user_id = v_uid and origem = 'app' and not removido;
    if v_last is not null and now() - v_last < interval '2 minutes' then raise exception 'marcacao_duplicada'; end if;
  end if;
  insert into public.punches (user_id, dia, hora, origem, lat, lng, precisao, geo_status, created_by)
  values (v_uid, v_now::date, v_now::time, 'app', p_lat, p_lng, p_precisao, p_geo, v_uid)
  returning * into r;
  return r;
end $$;

-- Solicitação de ajuste pelo colaborador (fica pendente até o gestor aprovar)
create or replace function public.solicitar_ajuste(
  p_tipo text, p_dia date, p_motivo text, p_punch uuid default null,
  p_hora time default null, p_tipo_dia text default null)
returns public.requests
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_prof public.profiles;
  v_hoje date;
  v_p public.punches;
  v_hn time;
  r public.requests;
begin
  if v_uid is null then raise exception 'nao_autenticado'; end if;
  select * into v_prof from public.profiles where id = v_uid and ativo;
  if not found then raise exception 'usuario_inativo'; end if;
  v_hoje := (now() at time zone v_prof.fuso)::date;
  if p_motivo is null or length(trim(p_motivo)) < 3 then raise exception 'motivo_obrigatorio'; end if;
  if p_tipo is null or p_tipo not in ('incluir','alterar','remover','tipo_dia') then raise exception 'tipo_invalido'; end if;
  if p_tipo in ('alterar','remover') then
    select * into v_p from public.punches where id = p_punch and user_id = v_uid and not removido;
    if not found then raise exception 'marcacao_nao_encontrada'; end if;
    p_dia := v_p.dia;
  end if;
  if p_dia is null then raise exception 'data_invalida'; end if;
  if p_tipo <> 'tipo_dia' and p_dia > v_hoje then raise exception 'data_futura'; end if;
  if p_tipo = 'tipo_dia' and (p_dia > v_hoje + 400 or p_tipo_dia is null or p_tipo_dia not in ('normal','feriado','folga','ferias','atestado')) then
    raise exception 'tipo_invalido';
  end if;
  if p_tipo in ('incluir','alterar') and p_hora is null then raise exception 'hora_obrigatoria'; end if;
  v_hn := case when p_tipo in ('incluir','alterar') then date_trunc('minute', p_hora)::time end;
  if v_hn is not null and p_dia = v_hoje and v_hn > (now() at time zone v_prof.fuso)::time then
    raise exception 'hora_futura';
  end if;
  if exists (select 1 from public.requests q where q.user_id = v_uid and q.status = 'pendente' and q.tipo = p_tipo and q.dia = p_dia
             and q.punch_id is not distinct from (case when p_tipo in ('alterar','remover') then p_punch end)
             and q.hora_nova is not distinct from v_hn
             and q.tipo_dia is not distinct from (case when p_tipo = 'tipo_dia' then p_tipo_dia end)) then
    raise exception 'solicitacao_repetida';
  end if;
  insert into public.requests (user_id, tipo, dia, punch_id, hora_atual, hora_nova, tipo_dia, motivo)
    values (v_uid, p_tipo, p_dia, case when p_tipo in ('alterar','remover') then p_punch end, v_p.hora,
            v_hn, case when p_tipo = 'tipo_dia' then p_tipo_dia end, trim(p_motivo))
    returning * into r;
  return r;
end $$;

create or replace function public.gestor_salvar_usuario_v2(
  p_id uuid, p_nome text, p_matricula text, p_role text, p_ativo boolean, p_jornada int[], p_inicio date, p_fuso text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if p_role not in ('colaborador','gestor') or array_length(p_jornada, 1) <> 7 or coalesce(trim(p_nome), '') = ''
     or p_fuso not in ('America/Noronha','America/Sao_Paulo','America/Manaus','America/Rio_Branco')
     or exists (select 1 from unnest(p_jornada) x where x < 0 or x > 1440) then
    raise exception 'dados_invalidos';
  end if;
  if (p_role <> 'gestor' or not p_ativo)
     and exists (select 1 from public.profiles where id = p_id and role = 'gestor')
     and not exists (select 1 from public.profiles where id <> p_id and role = 'gestor' and ativo) then
    raise exception 'ultimo_gestor';
  end if;
  update public.profiles
    set nome = trim(p_nome), matricula = coalesce(trim(p_matricula), ''), role = p_role, ativo = p_ativo,
        jornada = p_jornada, inicio = coalesce(p_inicio, inicio), fuso = p_fuso
    where id = p_id;
  if not found then raise exception 'usuario_inexistente'; end if;
end $$;

revoke execute on function public.registrar_ponto(double precision, double precision, double precision, text, boolean) from public, anon;
revoke execute on function public.solicitar_ajuste(text, date, text, uuid, time, text) from public, anon;
revoke execute on function public.gestor_salvar_usuario_v2(uuid, text, text, text, boolean, int[], date, text) from public, anon;
grant execute on function public.registrar_ponto(double precision, double precision, double precision, text, boolean) to authenticated;
grant execute on function public.solicitar_ajuste(text, date, text, uuid, time, text) to authenticated;
grant execute on function public.gestor_salvar_usuario_v2(uuid, text, text, text, boolean, int[], date, text) to authenticated;
-- A versão antiga public.gestor_salvar_usuario(uuid,text,text,text,boolean,int[],date) existe no banco, sem permissão de execução para usuários.

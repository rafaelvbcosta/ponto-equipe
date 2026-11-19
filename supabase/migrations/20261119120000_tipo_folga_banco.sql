-- Novo tipo de dia "folga_banco" (Folga com banco de horas): a jornada prevista continua valendo, então o dia sem
-- marcação desconta a jornada do banco, mas aparece como folga (não como falta) e não recebe lembretes.
-- Só amplia as listas de tipos válidos (restrições e as três funções que validam o tipo); o resto é idêntico ao que estava no banco.
alter table public.day_status drop constraint day_status_tipo_check,
  add constraint day_status_tipo_check check (tipo in ('normal','feriado','folga','ferias','atestado','folga_banco'));
alter table public.requests drop constraint requests_tipo_dia_check,
  add constraint requests_tipo_dia_check check (tipo_dia in ('normal','feriado','folga','ferias','atestado','folga_banco'));

CREATE OR REPLACE FUNCTION public._aplicar_ajuste(p_user uuid, p_tipo text, p_dia date, p_punch uuid, p_hora time without time zone, p_tipo_dia text, p_obs text, p_autor uuid, p_motivo text, p_origem text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_p public.punches;
begin
  if p_tipo = 'incluir' then
    if p_hora is null or p_dia is null then raise exception 'hora_obrigatoria'; end if;
    insert into public.punches (user_id, dia, hora, origem, created_by)
      values (p_user, p_dia, date_trunc('minute', p_hora)::time, p_origem, p_autor);
    insert into public.historico (user_id, dia, acao, detalhe, autor)
      values (p_user, p_dia, 'incluido', 'Incluído ' || to_char(p_hora, 'HH24:MI') || ' · ' || p_motivo, p_autor);
  elsif p_tipo = 'alterar' then
    if p_hora is null then raise exception 'hora_obrigatoria'; end if;
    select * into v_p from public.punches where id = p_punch and user_id = p_user and not removido for update;
    if not found then raise exception 'marcacao_nao_encontrada'; end if;
    update public.punches
      set hora = date_trunc('minute', p_hora)::time, hora_original = coalesce(hora_original, v_p.hora),
          alterado_em = now(), alterado_por = p_autor
      where id = p_punch;
    insert into public.historico (user_id, dia, acao, detalhe, autor)
      values (p_user, v_p.dia, 'alterado', to_char(v_p.hora, 'HH24:MI') || ' → ' || to_char(p_hora, 'HH24:MI') || ' · ' || p_motivo, p_autor);
  elsif p_tipo = 'remover' then
    select * into v_p from public.punches where id = p_punch and user_id = p_user and not removido for update;
    if not found then raise exception 'marcacao_nao_encontrada'; end if;
    update public.punches set removido = true, alterado_em = now(), alterado_por = p_autor where id = p_punch;
    insert into public.historico (user_id, dia, acao, detalhe, autor)
      values (p_user, v_p.dia, 'removido', 'Removido ' || to_char(v_p.hora, 'HH24:MI') || ' · ' || p_motivo, p_autor);
  elsif p_tipo = 'tipo_dia' then
    if p_tipo_dia is null or p_tipo_dia not in ('normal','feriado','folga','ferias','atestado','folga_banco') then raise exception 'tipo_invalido'; end if;
    insert into public.day_status (user_id, dia, tipo, obs, updated_by)
      values (p_user, p_dia, p_tipo_dia, coalesce(p_obs, ''), p_autor)
      on conflict (user_id, dia) do update
        set tipo = excluded.tipo, obs = coalesce(p_obs, public.day_status.obs), updated_at = now(), updated_by = p_autor;
    insert into public.historico (user_id, dia, acao, detalhe, autor)
      values (p_user, p_dia, 'tipo_dia', 'Tipo do dia: ' || p_tipo_dia || ' · ' || p_motivo, p_autor);
  else
    raise exception 'tipo_invalido';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.gestor_periodo_tipo(p_user uuid, p_de date, p_ate date, p_tipo text, p_motivo text, p_obs text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d date; n int := 0; v_mot text;
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if p_motivo is null or length(trim(p_motivo)) < 3 then raise exception 'motivo_obrigatorio'; end if;
  if p_tipo is null or p_tipo not in ('normal','feriado','folga','ferias','atestado','folga_banco') then raise exception 'tipo_invalido'; end if;
  if p_de is null or p_ate is null or p_ate < p_de or p_ate - p_de > 366 then raise exception 'periodo_invalido'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'usuario_inexistente'; end if;
  v_mot := 'gestor: ' || trim(p_motivo) || ' (período ' || to_char(p_de, 'DD/MM/YYYY') || ' a ' || to_char(p_ate, 'DD/MM/YYYY') || ')';
  d := p_de;
  while d <= p_ate loop
    perform public._aplicar_ajuste(p_user, 'tipo_dia', d, null, null, p_tipo, nullif(trim(coalesce(p_obs, '')), ''), auth.uid(), v_mot, 'gestor');
    n := n + 1;
    d := d + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.solicitar_ajuste(p_tipo text, p_dia date, p_motivo text, p_punch uuid DEFAULT NULL::uuid, p_hora time without time zone DEFAULT NULL::time without time zone, p_tipo_dia text DEFAULT NULL::text)
 RETURNS requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if p_tipo = 'tipo_dia' and (p_dia > v_hoje + 400 or p_tipo_dia is null or p_tipo_dia not in ('normal','feriado','folga','ferias','atestado','folga_banco')) then
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
end $function$;

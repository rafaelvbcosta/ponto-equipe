-- Observação: registrar_ponto e solicitar_ajuste foram substituídas em 20261112235931 (fuso por usuário);
-- gestor_salvar_usuario foi substituída por gestor_salvar_usuario_v2.

create or replace function public.existe_gestor() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where role = 'gestor');
$$;

create or replace function public._aplicar_ajuste(
  p_user uuid, p_tipo text, p_dia date, p_punch uuid, p_hora time, p_tipo_dia text,
  p_obs text, p_autor uuid, p_motivo text, p_origem text)
returns void
language plpgsql security definer set search_path = '' as $$
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
    if p_tipo_dia is null or p_tipo_dia not in ('normal','feriado','folga','ferias','atestado') then raise exception 'tipo_invalido'; end if;
    insert into public.day_status (user_id, dia, tipo, obs, updated_by)
      values (p_user, p_dia, p_tipo_dia, coalesce(p_obs, ''), p_autor)
      on conflict (user_id, dia) do update
        set tipo = excluded.tipo, obs = coalesce(p_obs, public.day_status.obs), updated_at = now(), updated_by = p_autor;
    insert into public.historico (user_id, dia, acao, detalhe, autor)
      values (p_user, p_dia, 'tipo_dia', 'Tipo do dia: ' || p_tipo_dia || ' · ' || p_motivo, p_autor);
  else
    raise exception 'tipo_invalido';
  end if;
end $$;

create or replace function public.cancelar_solicitacao(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.requests set status = 'cancelado'
    where id = p_id and user_id = auth.uid() and status = 'pendente';
  if not found then raise exception 'solicitacao_invalida'; end if;
end $$;

create or replace function public.revisar_solicitacao(p_id uuid, p_aprovar boolean, p_resposta text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare r public.requests; v_me uuid := auth.uid();
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  select * into r from public.requests where id = p_id for update;
  if not found or r.status <> 'pendente' then raise exception 'solicitacao_invalida'; end if;
  if p_aprovar then
    perform public._aplicar_ajuste(r.user_id, r.tipo, r.dia, r.punch_id, r.hora_nova, r.tipo_dia, null, v_me,
      'aprovado: ' || r.motivo, 'ajuste');
  else
    insert into public.historico (user_id, dia, acao, detalhe, autor)
      values (r.user_id, r.dia, 'rejeitado', 'Solicitação rejeitada (' || r.tipo || ') · ' || coalesce(nullif(trim(p_resposta), ''), 'sem justificativa'), v_me);
  end if;
  update public.requests
    set status = case when p_aprovar then 'aprovado' else 'rejeitado' end,
        resposta = nullif(trim(coalesce(p_resposta, '')), ''), revisado_por = v_me, revisado_em = now()
    where id = p_id;
end $$;

create or replace function public.gestor_ajuste(
  p_user uuid, p_tipo text, p_dia date, p_motivo text, p_punch uuid default null,
  p_hora time default null, p_tipo_dia text default null, p_obs text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if p_motivo is null or length(trim(p_motivo)) < 3 then raise exception 'motivo_obrigatorio'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'usuario_inexistente'; end if;
  perform public._aplicar_ajuste(p_user, p_tipo, p_dia, p_punch, p_hora, p_tipo_dia, p_obs, auth.uid(),
    'gestor: ' || trim(p_motivo), 'gestor');
end $$;

create or replace function public.senha_trocada() returns void
language sql security definer set search_path = '' as $$
  update public.profiles set trocar_senha = false where id = auth.uid();
$$;

revoke execute on function public._aplicar_ajuste(uuid, text, date, uuid, time, text, text, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.cancelar_solicitacao(uuid) from public, anon;
revoke execute on function public.revisar_solicitacao(uuid, boolean, text) from public, anon;
revoke execute on function public.gestor_ajuste(uuid, text, date, text, uuid, time, text, text) from public, anon;
revoke execute on function public.senha_trocada() from public, anon;
revoke execute on function public.is_gestor() from public, anon;
grant execute on function public.cancelar_solicitacao(uuid) to authenticated;
grant execute on function public.revisar_solicitacao(uuid, boolean, text) to authenticated;
grant execute on function public.gestor_ajuste(uuid, text, date, text, uuid, time, text, text) to authenticated;
grant execute on function public.senha_trocada() to authenticated;
grant execute on function public.is_gestor() to authenticated;
grant execute on function public.existe_gestor() to anon, authenticated;

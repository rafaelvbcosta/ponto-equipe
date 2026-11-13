-- Justificativa (motivo) da hora extra do dia. Não é aprovação: a extra conta igual; o motivo fica registrado.
-- O próprio colaborador justifica os seus dias; o gestor pode registrar/corrigir o de qualquer pessoa.
create table if not exists public.justificativas_extra (
  user_id uuid not null references public.profiles(id) on delete cascade,
  dia date not null,
  motivo text not null check (length(trim(motivo)) >= 3),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (user_id, dia)
);
alter table public.justificativas_extra enable row level security;
create policy justificativas_extra_read on public.justificativas_extra for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_gestor()));

create or replace function public.justificar_extra(p_dia date, p_motivo text, p_user uuid default null)
returns public.justificativas_extra
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_alvo uuid := coalesce(p_user, auth.uid()); v_prof public.profiles; v_ant text; r public.justificativas_extra;
begin
  if v_uid is null then raise exception 'nao_autenticado'; end if;
  if v_alvo <> v_uid and not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and ativo) then raise exception 'usuario_inativo'; end if;
  select * into v_prof from public.profiles where id = v_alvo;
  if not found then raise exception 'usuario_inexistente'; end if;
  if p_motivo is null or length(trim(p_motivo)) < 3 then raise exception 'motivo_obrigatorio'; end if;
  if length(p_motivo) > 500 then raise exception 'dados_invalidos'; end if;
  if p_dia is null then raise exception 'data_invalida'; end if;
  if p_dia > (now() at time zone v_prof.fuso)::date then raise exception 'data_futura'; end if;
  select motivo into v_ant from public.justificativas_extra where user_id = v_alvo and dia = p_dia;
  insert into public.justificativas_extra (user_id, dia, motivo, created_by, updated_by)
    values (v_alvo, p_dia, trim(p_motivo), v_uid, v_uid)
    on conflict (user_id, dia) do update set motivo = excluded.motivo, updated_at = now(), updated_by = excluded.updated_by
    returning * into r;
  insert into public.historico (user_id, dia, acao, detalhe, autor)
    values (v_alvo, p_dia, 'extra_justificada',
      case when v_ant is null then 'Motivo da hora extra: ' else 'Motivo da hora extra alterado (era: ' || v_ant || '): ' end || trim(p_motivo), v_uid);
  return r;
end $$;

revoke execute on function public.justificar_extra(date, text, uuid) from public, anon;
grant execute on function public.justificar_extra(date, text, uuid) to authenticated;

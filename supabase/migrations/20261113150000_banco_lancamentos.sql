-- Lançamentos manuais no banco de horas (saldo anterior ao app, horas pagas/compensadas etc.)
-- Só o gestor lança/remove, sempre por RPC e com registro em historico. Remoção é lógica (removido = true).

create table if not exists public.banco_lancamentos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  dia date not null,
  minutos int not null check (minutos <> 0 and minutos between -60000 and 60000),
  motivo text not null check (length(trim(motivo)) >= 3),
  removido boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid,
  removido_em timestamptz,
  removido_por uuid
);
create index if not exists banco_lancamentos_user_dia on public.banco_lancamentos(user_id, dia);
alter table public.banco_lancamentos enable row level security;
create policy banco_lancamentos_read on public.banco_lancamentos for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_gestor()));

create or replace function public._fmt_saldo(p_min int) returns text
language sql immutable set search_path = '' as $$
  select case when p_min < 0 then '-' else '+' end || (abs(p_min) / 60)::text || ':' || lpad((abs(p_min) % 60)::text, 2, '0');
$$;

create or replace function public.gestor_lancar_banco(p_user uuid, p_dia date, p_minutos int, p_motivo text)
returns public.banco_lancamentos
language plpgsql security definer set search_path = '' as $$
declare v_prof public.profiles; r public.banco_lancamentos;
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if p_motivo is null or length(trim(p_motivo)) < 3 then raise exception 'motivo_obrigatorio'; end if;
  if p_minutos is null or p_minutos = 0 or p_minutos not between -60000 and 60000 then raise exception 'dados_invalidos'; end if;
  select * into v_prof from public.profiles where id = p_user;
  if not found then raise exception 'usuario_inexistente'; end if;
  if p_dia is null then raise exception 'data_invalida'; end if;
  if p_dia > (now() at time zone v_prof.fuso)::date then raise exception 'data_futura'; end if;
  insert into public.banco_lancamentos (user_id, dia, minutos, motivo, created_by)
    values (p_user, p_dia, p_minutos, trim(p_motivo), auth.uid())
    returning * into r;
  insert into public.historico (user_id, dia, acao, detalhe, autor)
    values (p_user, p_dia, 'banco', 'Lançamento no banco: ' || public._fmt_saldo(p_minutos) || ' · ' || trim(p_motivo), auth.uid());
  return r;
end $$;

create or replace function public.gestor_remover_lancamento(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.banco_lancamentos;
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if p_motivo is null or length(trim(p_motivo)) < 3 then raise exception 'motivo_obrigatorio'; end if;
  update public.banco_lancamentos set removido = true, removido_em = now(), removido_por = auth.uid()
    where id = p_id and not removido
    returning * into r;
  if not found then raise exception 'lancamento_nao_encontrado'; end if;
  insert into public.historico (user_id, dia, acao, detalhe, autor)
    values (r.user_id, r.dia, 'banco_removido', 'Lançamento removido: ' || public._fmt_saldo(r.minutos) || ' (' || r.motivo || ') · ' || trim(p_motivo), auth.uid());
end $$;

revoke execute on function public._fmt_saldo(int) from public, anon, authenticated;
revoke execute on function public.gestor_lancar_banco(uuid, date, int, text) from public, anon;
revoke execute on function public.gestor_remover_lancamento(uuid, text) from public, anon;
grant execute on function public.gestor_lancar_banco(uuid, date, int, text) to authenticated;
grant execute on function public.gestor_remover_lancamento(uuid, text) to authenticated;

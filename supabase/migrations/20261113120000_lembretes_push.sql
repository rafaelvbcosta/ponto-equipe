-- Lembretes de marcação por push (início e fim do horário)
-- Aplicado pelo SQL Editor do painel (não aparece em list_migrations).

--
-- Como funciona:
--  * profiles.entrada: horário de entrada por dia da semana (minutos desde 00:00, índice 0 = domingo).
--    Saída prevista = entrada + jornada + intervalo mínimo (só quando a jornada passa de 6h).
--  * Cada aparelho que ativa os lembretes grava uma inscrição em push_subscriptions (RPC push_salvar).
--  * O pg_cron roda public._lembretes_tick() a cada minuto. Se alguém precisa de lembrete, chama a
--    Edge Function "lembretes", que reserva os lembretes (_lembretes_reservar, uma vez por dia e tipo) e envia o push.
--  * Lembrete de entrada: ninguém marcou ainda no dia. Lembrete de saída: número ímpar de marcações (jornada aberta).
--    Não há lembrete em dias sem jornada, feriado nacional (se ligado), dias marcados como feriado/folga/férias/atestado
--    ou antes de profiles.inicio. Envio a partir de config.lembrete_min minutos depois do horário, por até 1h.
--  * Chaves VAPID e o token do agendamento ficam no Vault. A chave privada é gerada pela própria Edge Function.

create extension if not exists pg_cron;
create extension if not exists pg_net;

alter table public.profiles add column if not exists entrada int[] not null default '{480,480,480,480,480,480,480}'
  check (array_length(entrada, 1) = 7 and array_position(entrada, null) is null and 0 <= all(entrada) and 1439 >= all(entrada));
alter table public.config add column if not exists lembretes boolean not null default true;
alter table public.config add column if not exists lembrete_min int not null default 5 check (lembrete_min between 0 and 60);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text not null default '',
  created_at timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  ultimo_envio timestamptz,
  ultimo_status int
);
create index if not exists push_subscriptions_user on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
create policy push_read on public.push_subscriptions for select to authenticated using (user_id = (select auth.uid()));

create table if not exists public.lembretes_enviados (
  user_id uuid not null references public.profiles(id) on delete cascade,
  dia date not null,
  tipo text not null check (tipo in ('entrada','saida')),
  hora time(0) not null,
  enviado_em timestamptz not null default now(),
  primary key (user_id, dia, tipo)
);
create index if not exists lembretes_enviados_dia on public.lembretes_enviados(dia);
alter table public.lembretes_enviados enable row level security;
create policy lembretes_read on public.lembretes_enviados for select to authenticated using (user_id = (select auth.uid()) or (select public.is_gestor()));

-- Feriados nacionais (mesma lista do front: fixos + Sexta-feira Santa)
create or replace function public._pascoa(y int) returns date
language plpgsql immutable set search_path = '' as $$
declare
  a int := y % 19; b int := y / 100; c int := y % 100; d int := b / 4; e int := b % 4;
  f int := (b + 8) / 25; g int := (b - f + 1) / 3; h int := (19*a + b - d - g + 15) % 30;
  i int := c / 4; k int := c % 4; l int := (32 + 2*e + 2*i - h - k) % 7; m int := (a + 11*h + 22*l) / 451;
begin
  return make_date(y, (h + l - 7*m + 114) / 31, ((h + l - 7*m + 114) % 31) + 1);
end $$;

create or replace function public._feriado_nacional(p_dia date) returns boolean
language sql immutable set search_path = '' as $$
  select to_char(p_dia, 'MM-DD') in ('01-01','04-21','05-01','09-07','10-12','11-02','11-15','11-20','12-25')
      or p_dia = public._pascoa(extract(year from p_dia)::int) - 2;
$$;

-- Quem precisa de lembrete agora (sem reservar)
create or replace function public._lembretes_candidatos(p_agora timestamptz default now())
returns table(user_id uuid, tipo text, dia date, hora time)
language sql stable security definer set search_path = '' as $$
  with cfg as (select * from public.config where id = 1),
  d as (
    select p.id, p.inicio, (p_agora at time zone p.fuso)::date as dia,
      (extract(hour from p_agora at time zone p.fuso) * 60 + extract(minute from p_agora at time zone p.fuso))::int as agora_min,
      p.jornada[extract(dow from p_agora at time zone p.fuso)::int + 1] as jor,
      p.entrada[extract(dow from p_agora at time zone p.fuso)::int + 1] as ent
    from public.profiles p, cfg
    where cfg.lembretes and p.ativo
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
  ),
  c as (
    select d.id, 'entrada'::text as tipo, d.dia, d.agora_min, d.ent as alvo, d.inicio, d.jor from d
    union all
    select d.id, 'saida'::text, d.dia, d.agora_min,
      d.ent + d.jor + case when d.jor > 360 then cfg.intervalo_min else 0 end, d.inicio, d.jor
    from d, cfg
  )
  select c.id, c.tipo, c.dia, make_time(c.alvo / 60, c.alvo % 60, 0)
  from c, cfg,
    lateral (select count(*) as n from public.punches x where x.user_id = c.id and x.dia = c.dia and not x.removido) np
  where c.jor > 0 and c.alvo < 1440 and c.dia >= c.inicio
    and c.agora_min >= c.alvo + cfg.lembrete_min and c.agora_min < c.alvo + cfg.lembrete_min + 60
    and not (cfg.feriados_nac and public._feriado_nacional(c.dia))
    and not exists (select 1 from public.day_status s where s.user_id = c.id and s.dia = c.dia and s.tipo <> 'normal')
    and not exists (select 1 from public.lembretes_enviados e where e.user_id = c.id and e.dia = c.dia and e.tipo = c.tipo)
    and case when c.tipo = 'entrada' then np.n = 0 else np.n % 2 = 1 end;
$$;

-- Reserva (uma vez por pessoa, dia e tipo) e devolve o que deve ser enviado. Chamada pela Edge Function.
create or replace function public._lembretes_reservar(p_agora timestamptz default now())
returns table(user_id uuid, tipo text, dia date, hora time)
language plpgsql volatile security definer set search_path = '' as $$
#variable_conflict use_column
declare r record;
begin
  for r in select * from public._lembretes_candidatos(p_agora) loop
    insert into public.lembretes_enviados (user_id, dia, tipo, hora) values (r.user_id, r.dia, r.tipo, r.hora)
      on conflict do nothing;
    if found then
      user_id := r.user_id; tipo := r.tipo; dia := r.dia; hora := r.hora;
      return next;
    end if;
  end loop;
end $$;

-- Token do agendamento (Vault) e validação pela Edge Function
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'lembretes_cron_token') then
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
      'lembretes_cron_token', 'Ponto Equipe: token do agendamento de lembretes');
  end if;
end $$;

create or replace function public._lembretes_token_ok(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(p_token, '') <> '' and exists (select 1 from vault.decrypted_secrets where name = 'lembretes_cron_token' and decrypted_secret = p_token);
$$;

-- Executado pelo pg_cron a cada minuto: só chama a Edge Function quando há lembrete a enviar
create or replace function public._lembretes_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare v_token text;
begin
  if not exists (select 1 from public._lembretes_candidatos()) then return; end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'lembretes_cron_token';
  if v_token is null then return; end if;
  perform net.http_post(
    url := 'https://wxqynubloybfmhozexpb.supabase.co/functions/v1/lembretes',
    body := '{"acao":"enviar"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', v_token),
    timeout_milliseconds := 20000);
end $$;

-- Chaves VAPID no Vault (geradas pela Edge Function na primeira vez)
create or replace function public._vapid_obter() returns table(publica text, privada text)
language sql stable security definer set search_path = '' as $$
  select (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_publica'),
         (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_privada');
$$;

create or replace function public._vapid_salvar(p_publica text, p_privada text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(p_publica, '') !~ '^[A-Za-z0-9_-]{87}$' or coalesce(p_privada, '') !~ '^[A-Za-z0-9_-]{43}$' then
    raise exception 'dados_invalidos';
  end if;
  if exists (select 1 from vault.secrets where name in ('vapid_publica', 'vapid_privada')) then return false; end if;
  perform vault.create_secret(p_privada, 'vapid_privada', 'Ponto Equipe: chave privada VAPID (push)');
  perform vault.create_secret(p_publica, 'vapid_publica', 'Ponto Equipe: chave pública VAPID (push)');
  return true;
exception when unique_violation then
  return false;
end $$;

-- Chave pública para o navegador se inscrever
create or replace function public.vapid_publica() returns text
language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'vapid_publica';
$$;

-- Inscrição do aparelho (o endpoint passa para quem estiver logado; até 5 aparelhos por pessoa)
create or replace function public.push_salvar(p_endpoint text, p_p256dh text, p_auth text, p_ua text default '')
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'nao_autenticado'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and ativo) then raise exception 'usuario_inativo'; end if;
  if p_endpoint is null or length(p_endpoint) > 1000
     or p_endpoint !~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|([a-z0-9-]+\.)*push\.services\.mozilla\.com|([a-z0-9-]+\.)*notify\.windows\.com|web\.push\.apple\.com|([a-z0-9-]+\.)*push\.apple\.com)/'
     or coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_-]{86,88}={0,2}$'
     or coalesce(p_auth, '') !~ '^[A-Za-z0-9_-]{22,44}={0,2}$' then
    raise exception 'dados_invalidos';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
    values (v_uid, p_endpoint, p_p256dh, p_auth, left(coalesce(p_ua, ''), 200))
    on conflict (endpoint) do update
      set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
          user_agent = excluded.user_agent, atualizado_em = now();
  delete from public.push_subscriptions
    where user_id = v_uid and id not in (
      select id from public.push_subscriptions where user_id = v_uid order by atualizado_em desc limit 5);
end $$;

create or replace function public.push_remover(p_endpoint text) returns void
language sql security definer set search_path = '' as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- Cadastro do usuário com horário de entrada (v2 continua no banco)
create or replace function public.gestor_salvar_usuario_v3(
  p_id uuid, p_nome text, p_matricula text, p_role text, p_ativo boolean, p_jornada int[], p_inicio date, p_fuso text, p_entrada int[])
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if p_role not in ('colaborador','gestor') or array_length(p_jornada, 1) <> 7 or coalesce(trim(p_nome), '') = ''
     or p_fuso not in ('America/Noronha','America/Sao_Paulo','America/Manaus','America/Rio_Branco')
     or exists (select 1 from unnest(p_jornada) x where x is null or x < 0 or x > 1440)
     or coalesce(array_length(p_entrada, 1), 0) <> 7
     or exists (select 1 from unnest(p_entrada) x where x is null or x < 0 or x > 1439) then
    raise exception 'dados_invalidos';
  end if;
  if (p_role <> 'gestor' or not p_ativo)
     and exists (select 1 from public.profiles where id = p_id and role = 'gestor')
     and not exists (select 1 from public.profiles where id <> p_id and role = 'gestor' and ativo) then
    raise exception 'ultimo_gestor';
  end if;
  update public.profiles
    set nome = trim(p_nome), matricula = coalesce(trim(p_matricula), ''), role = p_role, ativo = p_ativo,
        jornada = p_jornada, inicio = coalesce(p_inicio, inicio), fuso = p_fuso, entrada = p_entrada
    where id = p_id;
  if not found then raise exception 'usuario_inexistente'; end if;
  if not p_ativo then delete from public.push_subscriptions where user_id = p_id; end if;
end $$;

-- Permissões
revoke execute on function public._pascoa(int) from public, anon, authenticated, service_role;
revoke execute on function public._feriado_nacional(date) from public, anon, authenticated, service_role;
revoke execute on function public._lembretes_candidatos(timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public._lembretes_tick() from public, anon, authenticated, service_role;
revoke execute on function public._lembretes_reservar(timestamptz) from public, anon, authenticated;
revoke execute on function public._lembretes_token_ok(text) from public, anon, authenticated;
revoke execute on function public._vapid_obter() from public, anon, authenticated;
revoke execute on function public._vapid_salvar(text, text) from public, anon, authenticated;
revoke execute on function public.vapid_publica() from public, anon;
revoke execute on function public.push_salvar(text, text, text, text) from public, anon;
revoke execute on function public.push_remover(text) from public, anon;
revoke execute on function public.gestor_salvar_usuario_v3(uuid, text, text, text, boolean, int[], date, text, int[]) from public, anon;
grant execute on function public._lembretes_reservar(timestamptz) to service_role;
grant execute on function public._lembretes_token_ok(text) to service_role;
grant execute on function public._vapid_obter() to service_role;
grant execute on function public._vapid_salvar(text, text) to service_role;
grant execute on function public.vapid_publica() to authenticated;
grant execute on function public.push_salvar(text, text, text, text) to authenticated;
grant execute on function public.push_remover(text) to authenticated;
grant execute on function public.gestor_salvar_usuario_v3(uuid, text, text, text, boolean, int[], date, text, int[]) to authenticated;

-- Agendamentos
select cron.schedule('ponto-lembretes', '* * * * *', 'select public._lembretes_tick()');
select cron.schedule('ponto-lembretes-limpeza', '17 7 * * *', $job$
  delete from public.lembretes_enviados where dia < current_date - 60;
  delete from cron.job_run_details where end_time < now() - interval '7 days';
$job$);

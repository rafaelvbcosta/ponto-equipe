-- Feriados da empresa (municipais, estaduais, pontes): o gestor cadastra uma vez e vale para toda a equipe
-- ou só para as pessoas escolhidas (ex.: quem é de BH). Remoção lógica (removido = true).
create table if not exists public.feriados_locais (
  id uuid primary key default gen_random_uuid(),
  dia date not null,
  nome text not null check (length(trim(nome)) >= 3),
  todos boolean not null default true,
  usuarios uuid[] not null default '{}',
  removido boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  check (todos or cardinality(usuarios) > 0)
);
create index if not exists feriados_locais_dia on public.feriados_locais(dia) where not removido;
alter table public.feriados_locais enable row level security;
-- Cada um vê os feriados que valem para ele; o gestor vê todos
create policy feriados_locais_read on public.feriados_locais for select to authenticated
  using (todos or (select auth.uid()) = any(usuarios) or (select public.is_gestor()));
-- Como config e locais: o gestor grava direto (sem apagar; remover = marcar removido)
create policy feriados_locais_ins on public.feriados_locais for insert to authenticated with check ((select public.is_gestor()));
create policy feriados_locais_upd on public.feriados_locais for update to authenticated using ((select public.is_gestor())) with check ((select public.is_gestor()));

-- Lembretes: não enviar em feriado da empresa que vale para a pessoa (mesma função, com mais uma condição)
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
    and not exists (select 1 from public.feriados_locais f where f.dia = c.dia and not f.removido and (f.todos or c.id = any(f.usuarios)))
    and not exists (select 1 from public.day_status s where s.user_id = c.id and s.dia = c.dia and s.tipo <> 'normal')
    and not exists (select 1 from public.lembretes_enviados e where e.user_id = c.id and e.dia = c.dia and e.tipo = c.tipo)
    and case when c.tipo = 'entrada' then np.n = 0 else np.n % 2 = 1 end;
$$;

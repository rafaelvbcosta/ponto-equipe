create table public.config (
  id int primary key default 1 check (id = 1),
  empresa text not null default '',
  tolerancia int not null default 10 check (tolerancia between 0 and 120),
  feriados_nac boolean not null default true,
  exigir_gps boolean not null default false,
  padrao text[] not null default '{08:00,12:00,13:00,17:00}',
  updated_at timestamptz not null default now()
);
insert into public.config (id) values (1);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  email text not null,
  matricula text not null default '',
  role text not null default 'colaborador' check (role in ('colaborador','gestor')),
  ativo boolean not null default true,
  jornada int[] not null default '{0,480,480,480,480,480,0}' check (array_length(jornada,1) = 7),
  inicio date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  trocar_senha boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.locais (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  raio_m int not null default 300 check (raio_m between 20 and 20000),
  created_at timestamptz not null default now()
);

create table public.punches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  dia date not null,
  hora time(0) not null,
  origem text not null default 'app' check (origem in ('app','ajuste','gestor')),
  hora_original time(0),
  lat double precision,
  lng double precision,
  precisao double precision,
  geo_status text check (geo_status in ('ok','negado','indisponivel','timeout')),
  removido boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid,
  alterado_em timestamptz,
  alterado_por uuid
);
create index punches_user_dia on public.punches(user_id, dia);
create index punches_dia on public.punches(dia);

create table public.day_status (
  user_id uuid not null references public.profiles(id) on delete cascade,
  dia date not null,
  tipo text not null default 'normal' check (tipo in ('normal','feriado','folga','ferias','atestado')),
  obs text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (user_id, dia)
);

create table public.requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  tipo text not null check (tipo in ('incluir','alterar','remover','tipo_dia')),
  dia date not null,
  punch_id uuid references public.punches(id) on delete set null,
  hora_atual time(0),
  hora_nova time(0),
  tipo_dia text check (tipo_dia in ('normal','feriado','folga','ferias','atestado')),
  motivo text not null check (length(trim(motivo)) >= 3),
  status text not null default 'pendente' check (status in ('pendente','aprovado','rejeitado','cancelado')),
  resposta text,
  created_at timestamptz not null default now(),
  revisado_por uuid references public.profiles(id) on delete set null,
  revisado_em timestamptz
);
create index requests_status on public.requests(status);
create index requests_user on public.requests(user_id);
create index requests_punch on public.requests(punch_id);
create index requests_revisor on public.requests(revisado_por);

create table public.historico (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  dia date,
  acao text not null,
  detalhe text,
  autor uuid,
  created_at timestamptz not null default now()
);
create index historico_user_dia on public.historico(user_id, dia);

alter table public.config enable row level security;
alter table public.profiles enable row level security;
alter table public.locais enable row level security;
alter table public.punches enable row level security;
alter table public.day_status enable row level security;
alter table public.requests enable row level security;
alter table public.historico enable row level security;

create or replace function public.is_gestor() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'gestor' and ativo);
$$;

create policy config_read on public.config for select to authenticated using (true);
create policy config_write on public.config for update to authenticated using ((select public.is_gestor())) with check ((select public.is_gestor()));

create policy profiles_read on public.profiles for select to authenticated using (id = (select auth.uid()) or (select public.is_gestor()));

create policy locais_read on public.locais for select to authenticated using (true);
create policy locais_ins on public.locais for insert to authenticated with check ((select public.is_gestor()));
create policy locais_upd on public.locais for update to authenticated using ((select public.is_gestor())) with check ((select public.is_gestor()));
create policy locais_del on public.locais for delete to authenticated using ((select public.is_gestor()));

create policy punches_read on public.punches for select to authenticated using (user_id = (select auth.uid()) or (select public.is_gestor()));
create policy day_status_read on public.day_status for select to authenticated using (user_id = (select auth.uid()) or (select public.is_gestor()));
create policy requests_read on public.requests for select to authenticated using (user_id = (select auth.uid()) or (select public.is_gestor()));
create policy historico_read on public.historico for select to authenticated using (user_id = (select auth.uid()) or (select public.is_gestor()));

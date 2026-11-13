-- Aplicado no banco como duas migrations: config_intervalo_minimo e config_limite_banco_dia
alter table public.config add column if not exists intervalo_min int not null default 60 check (intervalo_min between 0 and 240);
alter table public.config add column if not exists limite_banco_dia int not null default 120 check (limite_banco_dia between 0 and 720);

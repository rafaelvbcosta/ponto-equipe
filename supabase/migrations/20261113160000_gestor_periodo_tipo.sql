-- Período de férias/afastamento: o gestor aplica um tipo de dia a um intervalo de datas de uma vez.
-- Cada dia passa por _aplicar_ajuste (grava day_status e uma linha em historico), como o ajuste de um dia.
create or replace function public.gestor_periodo_tipo(
  p_user uuid, p_de date, p_ate date, p_tipo text, p_motivo text, p_obs text default null)
returns int
language plpgsql security definer set search_path = '' as $$
declare d date; n int := 0; v_mot text;
begin
  if not public.is_gestor() then raise exception 'sem_permissao'; end if;
  if p_motivo is null or length(trim(p_motivo)) < 3 then raise exception 'motivo_obrigatorio'; end if;
  if p_tipo is null or p_tipo not in ('normal','feriado','folga','ferias','atestado') then raise exception 'tipo_invalido'; end if;
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
end $$;

revoke execute on function public.gestor_periodo_tipo(uuid, date, date, text, text, text) from public, anon;
grant execute on function public.gestor_periodo_tipo(uuid, date, date, text, text, text) to authenticated;

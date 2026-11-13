// Edge Function "lembretes" (verify_jwt = false; a autenticação é feita no código).
// Ações:
//   enviar  — chamada pelo pg_cron (public._lembretes_tick) com o cabeçalho x-cron-token (token no Vault).
//             Reserva os lembretes devidos (public._lembretes_reservar) e envia o push para os aparelhos de cada pessoa.
//   chave   — usuário logado: devolve a chave pública VAPID (gera o par na primeira vez e guarda no Vault).
//   teste   — usuário logado: envia uma notificação de teste para os aparelhos dele.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { enviarPush, gerarVapid, type VapidKeys } from './webpush.ts';

const APP_URL = 'https://rafaelvbcosta.github.io/ponto-equipe/';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });

function secretKey(): string {
  try {
    const k = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}');
    if (k && k.default) return k.default;
  } catch (_) { /* ignore */ }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
}

async function chaves(admin: SupabaseClient): Promise<VapidKeys> {
  const ler = async () => {
    const { data, error } = await admin.rpc('_vapid_obter');
    if (error) throw error;
    const r = Array.isArray(data) ? data[0] : data;
    return r?.publica && r?.privada ? { publica: r.publica as string, privada: r.privada as string } : null;
  };
  const k = await ler();
  if (k) return k;
  const novo = await gerarVapid();
  const { error } = await admin.rpc('_vapid_salvar', { p_publica: novo.publica, p_privada: novo.privada });
  if (error) throw error;
  const k2 = await ler(); // se outra chamada gravou antes, usa a que ficou salva
  if (!k2) throw new Error('Falha ao gerar as chaves de notificação.');
  return k2;
}

type Msg = { title: string; body: string; tag: string; url: string };
const hhmm = (t: string) => String(t || '').slice(0, 5);
const MSG: Record<string, (h: string) => Msg> = {
  entrada: (h) => ({ title: 'Hora de registrar a entrada', body: `Seu horário começa às ${h}. Toque para marcar o ponto.`, tag: 'lembrete-entrada', url: './#hoje' }),
  saida: (h) => ({ title: 'Hora de registrar a saída', body: `Sua saída prevista é às ${h}. Não esqueça de marcar o ponto.`, tag: 'lembrete-saida', url: './#hoje' }),
};

async function enviarPara(admin: SupabaseClient, keys: VapidKeys, userId: string, msg: Msg) {
  const { data: subs, error } = await admin.from('push_subscriptions').select('id, endpoint, p256dh, auth').eq('user_id', userId);
  if (error) throw error;
  let enviados = 0, falhas = 0;
  await Promise.all((subs || []).map(async (s) => {
    let st = 0;
    try { st = await enviarPush(s, msg, keys, APP_URL); } catch (e) { st = String((e as Error)?.message).includes('chaves_invalidas') ? 410 : 0; }
    if (st >= 200 && st < 300) enviados++; else falhas++;
    if (st === 404 || st === 410) await admin.from('push_subscriptions').delete().eq('id', s.id); // inscrição expirada
    else await admin.from('push_subscriptions').update({ ultimo_envio: new Date().toISOString(), ultimo_status: st }).eq('id', s.id);
  }));
  return { enviados, falhas, aparelhos: (subs || []).length };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ erro: 'Método inválido.' }, 405);
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, secretKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const body = await req.json().catch(() => ({}));
    const acao = body?.acao;

    if (acao === 'enviar') {
      const { data: ok } = await admin.rpc('_lembretes_token_ok', { p_token: req.headers.get('x-cron-token') || '' });
      if (ok !== true) return json({ erro: 'Não autorizado.' }, 401);
      const keys = await chaves(admin);
      const { data: devidos, error } = await admin.rpc('_lembretes_reservar');
      if (error) return json({ erro: error.message }, 500);
      if (!devidos?.length) return json({ ok: true, lembretes: 0 });
      const res = await Promise.all(devidos.map((d: { user_id: string; tipo: string; hora: string }) =>
        enviarPara(admin, keys, d.user_id, MSG[d.tipo](hhmm(d.hora))).catch(() => ({ enviados: 0, falhas: 1, aparelhos: 0 }))));
      return json({ ok: true, lembretes: devidos.length, enviados: res.reduce((n, r) => n + r.enviados, 0), falhas: res.reduce((n, r) => n + r.falhas, 0) });
    }

    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) return json({ erro: 'Sessão inválida.' }, 401);
    const { data: u, error: ue } = await admin.auth.getUser(token);
    if (ue || !u?.user) return json({ erro: 'Sessão inválida.' }, 401);
    const { data: me } = await admin.from('profiles').select('ativo').eq('id', u.user.id).maybeSingle();
    if (!me || !me.ativo) return json({ erro: 'Usuário inativo.' }, 403);

    if (acao === 'chave') {
      const keys = await chaves(admin);
      return json({ ok: true, publica: keys.publica });
    }

    if (acao === 'teste') {
      const keys = await chaves(admin);
      const r = await enviarPara(admin, keys, u.user.id, {
        title: 'Lembretes de ponto ativos',
        body: 'Você será avisado no início e no fim do seu horário, se ainda não tiver marcado o ponto.',
        tag: 'lembrete-teste', url: './#conta',
      });
      return json({ ok: true, ...r });
    }

    return json({ erro: 'Ação inválida.' }, 400);
  } catch (e) {
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});

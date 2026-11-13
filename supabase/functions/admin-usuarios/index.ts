// Edge Function "admin-usuarios" (verify_jwt = false; a autenticação é feita no código).
// Ações: bootstrap (cria o primeiro gestor, só enquanto não existe nenhum), criar (gestor cria conta),
// senha (gestor redefine senha temporária).
import { createClient } from 'npm:@supabase/supabase-js@2';

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

const FUSOS = ['America/Noronha', 'America/Sao_Paulo', 'America/Manaus', 'America/Rio_Branco'];
const emailOk = (e: unknown) => typeof e === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) && e.length <= 200;
const senhaOk = (p: unknown) => typeof p === 'string' && p.length >= 8 && p.length <= 72;
const nomeOk = (n: unknown) => typeof n === 'string' && n.trim().length >= 2 && n.trim().length <= 120;
const jornadaOk = (j: unknown) => Array.isArray(j) && j.length === 7 && j.every((x) => Number.isInteger(x) && x >= 0 && x <= 1440);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ erro: 'Método inválido.' }, 405);
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, secretKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const body = await req.json().catch(() => ({}));
    const acao = body?.acao;

    if (acao === 'bootstrap') {
      const { count, error: ce } = await admin.from('profiles').select('id', { count: 'exact', head: true }).eq('role', 'gestor');
      if (ce) return json({ erro: ce.message }, 500);
      if ((count ?? 0) > 0) return json({ erro: 'Já existe um gestor configurado.' }, 403);
      const { nome, email, senha, matricula } = body;
      if (!nomeOk(nome) || !emailOk(email) || !senhaOk(senha)) return json({ erro: 'Preencha nome, e-mail válido e senha com pelo menos 8 caracteres.' }, 400);
      const { data, error } = await admin.auth.admin.createUser({ email: email.trim().toLowerCase(), password: senha, email_confirm: true });
      if (error || !data?.user) return json({ erro: error?.message || 'Falha ao criar usuário.' }, 400);
      const { error: pe } = await admin.from('profiles').insert({
        id: data.user.id, nome: nome.trim(), email: email.trim().toLowerCase(), matricula: String(matricula || '').trim(),
        role: 'gestor', trocar_senha: false,
      });
      if (pe) { await admin.auth.admin.deleteUser(data.user.id); return json({ erro: pe.message }, 500); }
      return json({ ok: true });
    }

    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) return json({ erro: 'Sessão inválida.' }, 401);
    const { data: u, error: ue } = await admin.auth.getUser(token);
    if (ue || !u?.user) return json({ erro: 'Sessão inválida.' }, 401);
    const { data: me } = await admin.from('profiles').select('role, ativo').eq('id', u.user.id).maybeSingle();
    if (!me || me.role !== 'gestor' || !me.ativo) return json({ erro: 'Apenas gestores podem fazer isso.' }, 403);

    if (acao === 'criar') {
      const { nome, email, senha, matricula, role, jornada, inicio, fuso } = body;
      if (!nomeOk(nome) || !emailOk(email) || !senhaOk(senha)) return json({ erro: 'Preencha nome, e-mail válido e senha com pelo menos 8 caracteres.' }, 400);
      if (role && role !== 'colaborador' && role !== 'gestor') return json({ erro: 'Perfil inválido.' }, 400);
      if (jornada && !jornadaOk(jornada)) return json({ erro: 'Jornada inválida.' }, 400);
      if (inicio && !/^\d{4}-\d{2}-\d{2}$/.test(inicio)) return json({ erro: 'Data de início inválida.' }, 400);
      if (fuso && !FUSOS.includes(fuso)) return json({ erro: 'Fuso inválido.' }, 400);
      const { data, error } = await admin.auth.admin.createUser({ email: email.trim().toLowerCase(), password: senha, email_confirm: true });
      if (error || !data?.user) {
        const msg = /already|registered|exists/i.test(error?.message || '') ? 'Já existe uma conta com este e-mail.' : (error?.message || 'Falha ao criar usuário.');
        return json({ erro: msg }, 400);
      }
      const row: Record<string, unknown> = {
        id: data.user.id, nome: nome.trim(), email: email.trim().toLowerCase(), matricula: String(matricula || '').trim(),
        role: role || 'colaborador', trocar_senha: true,
      };
      if (jornada) row.jornada = jornada;
      if (inicio) row.inicio = inicio;
      if (fuso) row.fuso = fuso;
      const { error: pe } = await admin.from('profiles').insert(row);
      if (pe) { await admin.auth.admin.deleteUser(data.user.id); return json({ erro: pe.message }, 500); }
      return json({ ok: true, id: data.user.id });
    }

    if (acao === 'senha') {
      const { user_id, senha } = body;
      if (typeof user_id !== 'string' || !senhaOk(senha)) return json({ erro: 'Senha com pelo menos 8 caracteres.' }, 400);
      const { data: alvo } = await admin.from('profiles').select('id').eq('id', user_id).maybeSingle();
      if (!alvo) return json({ erro: 'Usuário não encontrado.' }, 404);
      const { error } = await admin.auth.admin.updateUserById(user_id, { password: senha });
      if (error) return json({ erro: error.message }, 400);
      if (user_id !== u.user.id) await admin.from('profiles').update({ trocar_senha: true }).eq('id', user_id);
      return json({ ok: true });
    }

    return json({ erro: 'Ação inválida.' }, 400);
  } catch (e) {
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});

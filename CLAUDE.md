# Ponto Equipe — instruções para o Claude

App de ponto eletrônico da equipe técnica do Rafael (GroundProbe Brasil). Responda em português.

## Onde está cada coisa

| Parte | Onde |
|---|---|
| Front-end | `index.html` (página única, sem build). Publicado pelo GitHub Pages a partir da branch `main`, raiz: https://rafaelvbcosta.github.io/ponto-equipe/ |
| PWA | `manifest.webmanifest`, `icon.svg`, `icon-192.png`, `icon-512.png`, `sw.js` (service worker só para push; sem cache) |
| Back-end | Supabase, projeto `ponto-equipe`, id `wxqynubloybfmhozexpb`, região `sa-east-1`, org "BuscAqui" (plano free) |
| SQL | `supabase/migrations/` (cópia do que foi aplicado; a fonte da verdade é o banco: `list_migrations` / `execute_sql`) |
| Edge Functions | `supabase/functions/admin-usuarios/index.ts` e `supabase/functions/lembretes/` (`index.ts` + `webpush.ts`); deploy com `verify_jwt: false` (autenticam no código) |

Na mesma org do Supabase existe o projeto `buscaqui` (outro app). Não mexa nele.

## Arquitetura e regras de segurança

- O front usa a chave *publishable*; toda a segurança está em RLS + funções `security definer`.
- Tabelas só têm políticas de SELECT (exceto `config` e `locais` para gestor). **Nenhuma escrita direta em `punches`, `requests`, `day_status`, `historico`**: tudo passa por RPC.
- RPCs: `registrar_ponto` (horário do servidor, no `profiles.fuso`; bloqueia repetição em menos de 2 min sem `p_forcar`), `solicitar_ajuste`, `cancelar_solicitacao`, `revisar_solicitacao` (gestor), `gestor_ajuste` (gestor, aplica direto), `gestor_salvar_usuario_v3` (v2 ainda existe), `senha_trocada`, `existe_gestor` (anon), `push_salvar`, `push_remover`, `vapid_publica`, `gestor_lancar_banco`, `gestor_remover_lancamento` e `gestor_periodo_tipo` (gestor; aplica um tipo de dia a um intervalo, até 1 ano, chamando `_aplicar_ajuste` dia a dia), `justificar_extra`.
- `_aplicar_ajuste` é interna (sem execute para ninguém) e grava em `historico`. Marcações nunca são apagadas: `removido = true`; alteração guarda `hora_original`.
- Contas são criadas pela Edge Function (`criar`, `senha`). `bootstrap` só funciona enquanto não existe nenhum gestor. Cadastro público do Supabase Auth está **desligado**.
- Mudanças de schema: sempre por `apply_migration`, preferindo mudanças não destrutivas (ex.: criar `_v2` em vez de dropar função). Salve uma cópia em `supabase/migrations/`.
- O servidor MCP do Supabase pede confirmação para SQL com `delete`/`revoke` e, na sessão na nuvem, essa pergunta não chega ao Rafael (expira em 60 s). Nesses casos peça para ele rodar no SQL Editor. A migration `20261113120000_lembretes_push.sql` foi aplicada assim e por isso não aparece em `list_migrations`.

## Lembretes de marcação (push)

- `profiles.entrada` (int[7], minutos, índice 0 = domingo, padrão 08:00): horário de entrada definido pelo gestor. Saída prevista = entrada + jornada + `config.intervalo_min` (só se a jornada passa de 6h).
- `config.lembretes` (liga/desliga geral) e `config.lembrete_min` (envia X min depois do horário, padrão 5; janela de 1h).
- Cada aparelho ativa em Conta → `push_salvar` grava em `push_subscriptions` (endpoint só de serviços conhecidos: FCM, Mozilla, Windows, Apple; até 5 por pessoa). Sair do app chama `push_remover`; inativar o usuário apaga as inscrições.
- pg_cron `ponto-lembretes` (a cada minuto) roda `_lembretes_tick()`: se `_lembretes_candidatos()` tiver alguém, chama a Edge Function `lembretes` (`acao: enviar`, cabeçalho `x-cron-token` = segredo `lembretes_cron_token` do Vault). A função reserva com `_lembretes_reservar()` (tabela `lembretes_enviados`, uma vez por pessoa/dia/tipo) e envia o push. Inscrição que responde 404/410 é apagada.
- Regras: entrada só se não há marcação no dia; saída só se o número de marcações é ímpar. Nada em dia sem jornada, feriado nacional (`_feriado_nacional`, se `feriados_nac`), `day_status` diferente de normal, antes de `inicio`, usuário inativo.
- Chaves VAPID no Vault (`vapid_publica`, `vapid_privada`), geradas pela própria Edge Function na primeira chamada. Não troque: invalidaria todas as inscrições.
- Limpeza diária (`ponto-lembretes-limpeza`): `lembretes_enviados` com mais de 60 dias e `cron.job_run_details` com mais de 7 dias.
- iPhone: só funciona com o app instalado na Tela de Início (iOS 16.4+). A Conta explica isso.

## Regras de cálculo (todas no front, função `calc()` do `index.html`)

- Jornada por dia da semana em minutos (`profiles.jornada`, índice 0 = domingo). Padrão 8h seg–sex.
- **Intervalo mínimo** (`config.intervalo_min`, 60): dia com mais de 6h trabalhadas sem intervalo marcado (ou com intervalo menor) tem a diferença descontada, sem deixar o dia abaixo de 6h.
- **Tolerância** (`config.tolerancia`, 10 min): diferença diária de até X min vira zero.
- **Banco x extra paga** (`config.limite_banco_dia`, 120) — regra única definida pelo Rafael (13/11/2026): em **qualquer dia** (semana, sábado, domingo, feriado), as 2 primeiras horas extras do dia vão para o banco e o excedente é "extra paga". Saldo negativo (falta/atraso) desconta do banco.
- **Domingo e feriado** (nacional automático, ou dia marcado como "Feriado") sem jornada prevista: a parte paga (o que passa das 2h) fica separada como `paga100` ("extra 100%") para o financeiro; não há mais "tudo extra 100%".
- Extras pagas fecham por mês (Hoje e Histórico mostram o mês; o cartão "Resumo por mês" do Histórico guarda cada mês); o banco é acumulado.
- Tipos de dia (`day_status`): normal, feriado, folga, férias, atestado (zeram a jornada prevista). Períodos (férias etc.) são lançados pelo gestor no Histórico da pessoa (cartão "Férias e afastamentos"); dias sem marcação não mexem no banco, trabalho nesses dias conta como extra, e não há lembrete.
- **Feriados da empresa** (`feriados_locais`: dia, nome, `todos` ou lista `usuarios`; remoção lógica): municipais/estaduais/pontes cadastrados pelo gestor em Mais. `holiday(k, uid)` no front junta esses com os nacionais (os da empresa valem mesmo se `feriados_nac` estiver desligado); `_lembretes_candidatos` também os ignora. Escrita direta do gestor por RLS (como `config`/`locais`).
- Dias antes de `profiles.inicio` não contam; dia de hoje só conta quando fechado (número par de marcações).
- **Lançamentos manuais** (`banco_lancamentos`: dia, minutos ±, motivo; remoção lógica com `removido`): entram direto no banco, sem tolerância nem limite diário. Usados para o saldo anterior ao app (data = dia anterior ao `inicio`) e para horas pagas/compensadas. Gestor lança no Histórico da pessoa; tudo gera linha em `historico` (`banco` / `banco_removido`).
- Banco acumulado = soma diária desde `inicio` + todos os lançamentos até hoje (`extrato()` no front). Banco do mês inclui os lançamentos com data no mês.
- **Justificativa de hora extra** (`justificativas_extra`, uma por pessoa/dia; RPC `justificar_extra(p_dia, p_motivo, p_user)`: o próprio colaborador ou o gestor por qualquer um; grava `historico` `extra_justificada`). Dia com extra = `calc().extra` (conta e saldo > 0 depois da tolerância, inclusive domingo/feriado). Não é aprovação: a extra conta igual.
  O app pede o motivo ao marcar a saída que fecha o dia com extra, mostra o cartão "Informe o motivo da hora extra" na tela Hoje e abre o pedido ao entrar no app enquanto houver dia pendente (decisão do Rafael: insistir). Relatórios: Observações traz "Motivo da extra: …" ou "EXTRA SEM JUSTIFICATIVA" (destacado no PDF) e o total de dias sem justificativa.

## Relatórios

Excel (SheetJS 0.18.5) com abas Resumo (equipe), Espelho por pessoa, Marcações (coordenadas + link do mapa) e Ajustes. Espelho e PDF terminam com o extrato do banco: saldo anterior + dias do período + lançamentos = saldo final. PDF (jsPDF 2.5.1 + autotable 3.8.2), A4 paisagem, uma pessoa por página, com campos de assinatura.

## Como testar antes de publicar

- O sandbox não acessa `*.supabase.co` diretamente. Para testar a lógica do banco, use `execute_sql` com
  `set_config('request.jwt.claims', '{"sub":"<uuid>","role":"authenticated"}', true)` e `set local role authenticated` dentro de um bloco `do`, com usuários de teste (`teste.*@exemplo.invalid`). Prefira terminar o bloco com `raise exception` contendo os resultados: tudo é desfeito e não precisa de `delete` (que pede confirmação).
- Não deixe usuário de teste gravado (fora de transação desfeita): o `auth.users` criado por SQL só com id/email quebra o serviço de Auth ("Database error loading user") e o painel não consegue apagá-lo; só sai com `delete from auth.users ...` no SQL Editor.
- Para chamar Edge Functions a partir do banco: `net.http_post(...)` e ler `net._http_response`.
- `_lembretes_candidatos(p_agora)` aceita um horário fixo para testar cenários.
- Para o front, rode o `index.html` no jsdom com um mock de `window.supabase` (servindo o mock no lugar do CDN do supabase-js) e as libs de xlsx/jspdf locais.
- Verifique sempre `node --check` no script e gere um Excel/PDF de exemplo.
- Publicar = commit + push em `main` (o Pages atualiza em 1–2 min).

## Pendências (pedidas pelo Rafael, ainda não implementadas)

- Nenhuma no momento.

## Observação

É controle interno de jornada, não REP-P certificado (Portaria 671/2021).

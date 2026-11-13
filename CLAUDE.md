# Ponto Equipe — instruções para o Claude

App de ponto eletrônico da equipe técnica do Rafael (GroundProbe Brasil). Responda em português.

## Onde está cada coisa

| Parte | Onde |
|---|---|
| Front-end | `index.html` (página única, sem build). Publicado pelo GitHub Pages a partir da branch `main`, raiz: https://rafaelvbcosta.github.io/ponto-equipe/ |
| PWA | `manifest.webmanifest`, `icon.svg`, `icon-192.png`, `icon-512.png` |
| Back-end | Supabase, projeto `ponto-equipe`, id `wxqynubloybfmhozexpb`, região `sa-east-1`, org "BuscAqui" (plano free) |
| SQL | `supabase/migrations/` (cópia do que foi aplicado; a fonte da verdade é o banco: `list_migrations` / `execute_sql`) |
| Edge Function | `supabase/functions/admin-usuarios/index.ts` (deploy com `verify_jwt: false`; autentica no código) |

Na mesma org do Supabase existe o projeto `buscaqui` (outro app). Não mexa nele.

## Arquitetura e regras de segurança

- O front usa a chave *publishable*; toda a segurança está em RLS + funções `security definer`.
- Tabelas só têm políticas de SELECT (exceto `config` e `locais` para gestor). **Nenhuma escrita direta em `punches`, `requests`, `day_status`, `historico`**: tudo passa por RPC.
- RPCs: `registrar_ponto` (horário do servidor, no `profiles.fuso`; bloqueia repetição em menos de 2 min sem `p_forcar`), `solicitar_ajuste`, `cancelar_solicitacao`, `revisar_solicitacao` (gestor), `gestor_ajuste` (gestor, aplica direto), `gestor_salvar_usuario_v2`, `senha_trocada`, `existe_gestor` (anon).
- `_aplicar_ajuste` é interna (sem execute para ninguém) e grava em `historico`. Marcações nunca são apagadas: `removido = true`; alteração guarda `hora_original`.
- Contas são criadas pela Edge Function (`criar`, `senha`). `bootstrap` só funciona enquanto não existe nenhum gestor. Cadastro público do Supabase Auth está **desligado**.
- Mudanças de schema: sempre por `apply_migration`, preferindo mudanças não destrutivas (ex.: criar `_v2` em vez de dropar função). Salve uma cópia em `supabase/migrations/`.

## Regras de cálculo (todas no front, função `calc()` do `index.html`)

- Jornada por dia da semana em minutos (`profiles.jornada`, índice 0 = domingo). Padrão 8h seg–sex.
- **Intervalo mínimo** (`config.intervalo_min`, 60): dia com mais de 6h trabalhadas sem intervalo marcado (ou com intervalo menor) tem a diferença descontada, sem deixar o dia abaixo de 6h.
- **Tolerância** (`config.tolerancia`, 10 min): diferença diária de até X min vira zero.
- **Banco x extra paga** (`config.limite_banco_dia`, 120): saldo positivo do dia vai para o banco até 2h; o excedente é "extra paga". Saldo negativo (falta/atraso) desconta do banco.
- **Domingo e feriado** (nacional automático, ou dia marcado como "Feriado") sem jornada prevista: tudo que for trabalhado é **extra 100%**, não entra no banco.
- Sábado sem jornada: segue a regra normal (2h banco + resto pago), a confirmar com o Rafael se mudar.
- Tipos de dia (`day_status`): normal, feriado, folga, férias, atestado (zeram a jornada prevista).
- Dias antes de `profiles.inicio` não contam; dia de hoje só conta quando fechado (número par de marcações).

## Relatórios

Excel (SheetJS 0.18.5) com abas Resumo (equipe), Espelho por pessoa, Marcações (coordenadas + link do mapa) e Ajustes. PDF (jsPDF 2.5.1 + autotable 3.8.2), A4 paisagem, uma pessoa por página, com campos de assinatura.

## Como testar antes de publicar

- O sandbox não acessa `*.supabase.co` diretamente. Para testar a lógica do banco, use `execute_sql` com
  `set_config('request.jwt.claims', '{"sub":"<uuid>","role":"authenticated"}', true)` e `set local role authenticated` dentro de um bloco `do`, com usuários de teste (`teste.*@exemplo.invalid`) apagados ao final.
- Para o front, rode o `index.html` no jsdom com um mock de `window.supabase` (servindo o mock no lugar do CDN do supabase-js) e as libs de xlsx/jspdf locais.
- Verifique sempre `node --check` no script e gere um Excel/PDF de exemplo.
- Publicar = commit + push em `main` (o Pages atualiza em 1–2 min).

## Observação

É controle interno de jornada, não REP-P certificado (Portaria 671/2021).

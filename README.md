# Ponto Equipe

Registro de ponto eletrônico da equipe, com localização (GPS) em cada marcação, solicitações de ajuste com aprovação do gestor e relatórios em Excel e PDF.

- **Front-end:** página única (`index.html`) publicada no GitHub Pages; instalável na tela inicial do celular.
- **Back-end:** Supabase (projeto `ponto-equipe`, região São Paulo): login, banco de dados e a função `admin-usuarios`.

## Como funciona

| Quem | O que faz |
|---|---|
| Colaborador | Marca o ponto (horário do servidor + GPS), vê o histórico e o banco de horas, solicita ajustes (incluir, alterar ou remover marcação, ou mudar o tipo do dia) e gera o próprio relatório. |
| Gestor | Vê a equipe em tempo real, aprova ou rejeita solicitações, ajusta diretamente qualquer dia, cria contas e redefine senhas, cadastra locais (minas, escritório) e gera relatórios individuais ou da equipe. |

- **Lembretes:** cada pessoa pode ativar, em Conta, um aviso no celular no início e no fim do horário (definido pelo gestor no cadastro). O aviso só chega se ela ainda não marcou e não é enviado em feriados, folgas, férias e atestados. No iPhone, é preciso instalar o app na Tela de Início.
- O horário de cada marcação é definido pelo servidor, no fuso de cada colaborador. Não dá para marcar com horário inventado.
- Ninguém altera o ponto diretamente pela API: tudo passa por funções que validam permissões e gravam um histórico de alterações.
- Cada colaborador só enxerga os próprios dados (Row Level Security).
- A chave usada na página é a chave *publishable* do Supabase, pública por definição; a segurança está nas regras do banco.

## Primeiro acesso

1. Abra o link do app. Enquanto não existir gestor, aparece o formulário **Configuração inicial — conta do gestor**.
2. Crie sua conta. O formulário some depois disso.
3. Em **Mais**, cadastre os locais de trabalho, as configurações gerais e as contas da equipe. O app gera uma senha temporária para você enviar a cada pessoa.

## Recomendado no painel do Supabase

- **Authentication → Sign In / Providers → desativar "Allow new users to sign up".** As contas são criadas pelo gestor; o cadastro público não é usado. Mesmo ativo, uma conta criada por fora não acessa nada sem perfil na equipe.

## Observação legal

É um controle de jornada interno da equipe. Não é um sistema de registro de ponto certificado (REP-P, Portaria MTP 671/2021). Para servir como ponto oficial, use o sistema homologado da empresa.

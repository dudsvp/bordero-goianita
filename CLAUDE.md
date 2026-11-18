# Borderô GOIANITA — regras do projeto

Site estático (`index.html` único) publicado no GitHub Pages (branch `main`).
Tem duas telas: **Gerador de borderô**, usado pelos vendedores sem login, e **Painel de Controle**, exclusivo da central (Karinne), protegido por senha.

## Deploy
- `.nojekyll` é obrigatório na raiz. Sem ele o build do Pages falha e o site fica preso na versão antiga.
- Commit/push só com aprovação do Eduardo.

## Banco online (Supabase)
- O HTML usa **apenas a anon key**. Nunca colocar a `service_role` key no código nem no chat.
- O anônimo (gerador) só **insere**, via RPC `registrar_bordero`. Não pode ler, alterar nem apagar.
- Leitura e alteração só com o usuário autenticado da central (RLS).
- Schema versionado em `supabase/schema.sql`. Toda mudança no banco passa por esse arquivo.
- Nada é apagado de verdade. "Excluir" vira status cancelado, com evento no histórico.

## Fluxo de status
Gerado na loja → Recebido na central → Saiu para entrega → Entregue (quem recebeu + data + foto obrigatórios) / Não realizada (motivo obrigatório). Também existe "Retirado na central".
Toda mudança de status grava uma linha em `eventos`.

## Como trabalhar
- Planejar e revisar segurança: Opus/Fable no Plan mode. Implementar: Sonnet. Tarefas pequenas: Haiku.
- Testar sempre no preview local (`.claude/launch.json`). Verificar o painel em outro navegador/aba anônima para confirmar que está online.
- Parser de pedidos: depurar só com pdf.js real, nunca com pdftotext.
- Rodar `/code-review` no fim de cada fase.

Plano completo: `C:\Users\Eduardo\.claude\plans\me-explique-se-faz-gentle-galaxy.md`

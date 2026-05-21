# Repository Instructions — Sameka AI Agent Reference

Este repositório é a **implementação de referência** de um agente de IA do padrão "Sameka": n8n workflows + front HTML/Netlify + (opcional) Supabase auth/migrations + (opcional) RAG.

Sua principal função para o Copilot/agent é servir de **template e fonte de macetes** quando o usuário pedir para criar *outros* agentes seguindo o mesmo padrão.

## Quando o usuário pedir um agente novo

**Não improvise.** Invoque o agente customizado **AI Agent Architect** ([.github/agents/ai-agent-architect.agent.md](.github/agents/ai-agent-architect.agent.md)).

Pontos de entrada:
- `/discovery <brief>` — só interpreta o brief e devolve o Discovery Map, sem criar arquivos.
- `/scaffold-agent <brief>` — cria o repositório completo.
- Ou simplesmente: "criar agente novo para X" → o picker carrega `AI Agent Architect` pela `description`.

## Padrão arquitetural (resumo, 5 camadas)

1. **migrations/** — Supabase/Postgres com RPCs `SECURITY DEFINER`, metadata-first auth, sufixo `<prefix>_`, `NOTIFY pgrst` no fim de cada arquivo.
2. **workspaces/** — n8n: main LangChain agent, RAG, Chat CRUD, subflows `[<Brand>] *`. Padrão de naming, contrato `{ok,data,error}` em cada subflow.
3. **front-<brand>.html + netlify/** — monolito source-of-truth + split idempotente para hosting estático.
4. **scripts PowerShell** — `_sync-netlify.ps1`, `_sync-front-workflow.ps1`, `004_seed.ps1`.
5. **RAG** — pasta dedicada no Drive (`DRIVE_FOLDER_ID_RAG`) com identidade estável (`file_id` nunca muda).

## Skills disponíveis (em .github/skills/)

Carregue via `read_file` quando aplicável (cada SKILL.md tem `description` com gatilhos):

- `supabase-auth` — login Supabase + roles + admin RPCs
- `n8n-langchain-prompt` — system prompt 7-section + `<user_context>` injection
- `n8n-tool-contract` — envelope `{ok,data,error}` + JSON Schema + idempotency
- `n8n-rag-stable-id` — pasta Drive dedicada + `files.update` no mesmo `file_id`
- `n8n-reset-safety` — Tier A vs Tier B + ban CASCADE + TRUNCATE
- `n8n-workflow-rewrite` — clonar JSON do n8n preservando node IDs/connections
- `n8n-front-injection` — monolito ↔ Netlify split ↔ n8n-served front
- `n8n-credential-placeholders` — `__FILL_ME__`, `.env.example`, Drive IDs

## Regras invioláveis (todas as Constraints do agente AI Agent Architect aplicam aqui também)

- **Nunca** `DROP ... CASCADE` em workflows do n8n.
- **Nunca** `ON DELETE CASCADE` em FK para `auth.users`.
- **Nunca** chamar `files.delete` da Google Drive em qualquer workflow.
- **Nunca** colocar `SUPABASE_SERVICE_ROLE_KEY`, password do Postgres ou token longo em `front-*.html` / `netlify/*`.
- **Nunca** inventar Drive `file_id` / `folder_id` / tokens — use placeholder `__FILL_ME__<KEY>__`.
- **Sempre** rename exaustivo ao clonar (SQL identifiers, `tableName`, `queryName`, webhook `path`, credential names, classes CSS, `localStorage` keys).
- **Sempre** consulte Context7 antes de gerar sintaxe de API externa não vista no Sameka (Supabase JS, Drive API, pgvector, SDK de LLM, novos nodes n8n).
- **Sempre** preserve casing original em `brand_display` (`São Rafael`, `printAG`); sanitize para `brand_prefix`.

## Hooks ativos

[.github/hooks/check-dangerous-patterns.json](.github/hooks/check-dangerous-patterns.json) — PreToolUse hook que bloqueia:
- `DROP CASCADE` em workspaces/migrations
- `files.delete` em workspaces
- `ON DELETE CASCADE` para `auth.users` em migrations
- `SUPABASE_SERVICE_ROLE_KEY` ou JWT muito longo no front

## Comunicação com o usuário

- pt-BR por padrão.
- Pergunte parâmetros faltantes em **uma única** lista numerada consolidada (≤ 8 itens).
- Apresente Discovery Map + File Map e peça **confirmação explícita** antes de qualquer escrita.
- Nomes/identificadores de código permanecem em English/snake_case.

## Não faça

- Não edite arquivos do Sameka (`migrations/`, `workspaces/Sameka-*`, `front-sameka.html`, `netlify/`) ao scaffolddar um agente *novo*. Use-os como template lendo + reescrevendo para o `target_repo_path`.
- Não crie documentação solicitada (`.md` de resumo de mudanças) a menos que o usuário peça explicitamente.

# Castor — Agente de Reativação & Prospecção B2B

Agente de IA (perfil **FULL**: Supabase Auth + roles + RAG) que apoia representantes Castor na reativação de clientes inativos e prospecção de leads novos. As bases Protheus são **uploadadas via a tela admin** (CSV/XLSX) → armazenadas no Google Drive (pasta source, preservando `file_id`) → ingeridas no Postgres em tabelas espelho/agregadas via `TRUNCATE + INSERT` em transação. O snapshot do painel agora é servido por **SQL puro** (sem reparse de CSV em runtime), o que elimina o OOM em arquivos grandes (SF2010 ~35MB, SC5010 ~57MB).

## Quickstart

1. Preencha `.env` (copiado de `.env.example`).
2. Garanta no n8n: `N8N_DEFAULT_BINARY_DATA_MODE=filesystem` (essencial para arquivos grandes; sem isso o ingest faz fallback para buffer e pode estourar memória).
3. `pwsh ./scripts/001_apply_migrations.ps1` — aplica as migrations Tier A (`001_bootstrap` → `008_sources`).
4. `pwsh ./scripts/003_upload_rag_to_drive.ps1` — sobe `RAG/*` para `DRIVE_FOLDER_ID_RAG` e imprime os `DRIVE_FILE_ID_*`. Cole-os no `.env`.
5. Importe os workflows de `workspaces/` no n8n (ordem: subflows → DB-Schema-Setup → main agent → RAG → Chat CRUD → Source Manager → Panel-API → CNPJ Refresh).
6. Religue credentials no n8n (Postgres, OpenAI, Google Drive OAuth, Header Auth).
7. Trigger `POST /castor-rag-schema-setup` (Tier B) e `POST /castor-rag-reindex-drive`.
8. `pwsh ./scripts/004_seed_admin.ps1` — cria o primeiro admin (caso a migration 007_seed_admin não tenha sido suficiente).
9. `pwsh ./scripts/_sync-netlify.ps1` — gera `netlify/` a partir de `front-castor.html`.
10. Deploy do diretório `netlify/` no Netlify.
11. Pela tela admin (aba **Fontes Protheus**), suba cada CSV (SA1010, SA3010, ZA7010, CC2010, SF2010, SC5010). Cada upload substitui o conteúdo no Drive (mesmo `file_id`) e dispara a ingestão no Postgres automaticamente.

Consulte `docs/business-rules.md` para regras de negócio (idêntico a `../RAG/regras_de_negocio_castor.md`).

## Camada de dados

```
Upload admin (front)
   ↓ multipart
Castor-Source-Manager  —  POST /castor-source-replace  (files.update no mesmo file_id)
   ↓ file_id
Castor-Source-Manager  —  POST /castor-source-ingest   (parse streaming + TRUNCATE+INSERT)
   ↓
Postgres:
  • castor_src_sa1010      ← SA1010
  • castor_src_sa3010      ← SA3010
  • castor_src_za7010      ← ZA7010
  • castor_src_cc2010      ← CC2010
  • castor_metrics_sf2010  ← SF2010  (agregado 12m por cliente)
  • castor_metrics_sc5010  ← SC5010  (último pedido por cliente)
  • castor_client_metrics  ← VIEW unindo os dois acima
  • castor_ingest_log      ← auditoria
```

Arquivos grandes que não entram no Postgres (SB1010, SBM010, SF4010, SX5010, SC6010, SD2010, SZ1010, FATOTEMPO) ficam apenas no Drive como histórico bruto.

## Estrutura

- `migrations/` — Tier A. Idempotentes. `008_sources.sql` cria as tabelas-espelho e agregadas.
- `workspaces/` — JSONs n8n (main agent, RAG, subflows, chat CRUD, admin).
- `netlify/` — gerado por `_sync-netlify.ps1`. Não edite à mão.
- `front-castor.html` — fonte única do front (monolito). Aba **Fontes Protheus** faz upload + ingest.
- `scripts/` — automação PowerShell.
- `docs/` — documentação humana.

## Restrições invioláveis

- Sem `DROP ... CASCADE` em workflow algum.
- Sem `ON DELETE CASCADE` em FK para `auth.users`.
- Sem `files.delete` da Drive API — substituições usam `files.update` (PATCH) preservando `file_id`.
- `SUPABASE_SERVICE_ROLE_KEY` jamais no front.
- Updates de RAG: `files.update` no mesmo `file_id` da pasta `DRIVE_FOLDER_ID_RAG`.
- Ingest no Postgres sempre em transação: `BEGIN; TRUNCATE <tabela>; INSERT em lotes; COMMIT;` (sem CASCADE).

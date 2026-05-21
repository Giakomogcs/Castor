# Migrations consolidadas (Castor)

Conjunto enxuto de 12 migrations derivado das 36 originais em `../migrations/`.
Aplique **em ordem** em um Supabase novo (vazio). Cada arquivo é idempotente
e termina com `NOTIFY pgrst, 'reload schema'`. O `-- DOWN` de cada migration
fica **comentado no rodapé** do próprio arquivo — descomente o bloco para reverter.

## Ordem de execução

| #   | Arquivo                                                                                | Responsabilidade                                                                                                                                                                                                                                                                                                                                                                                        |
| --- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 001 | [001_ext_and_helpers.sql](001_ext_and_helpers.sql)                                     | `pgcrypto`, `vector`, `castor_schema_migrations`, grants `auth.*`, `castor_is_admin`, `castor_assert_admin`                                                                                                                                                                                                                                                                                             |
| 002 | [002_auth_users_rpcs.sql](002_auth_users_rpcs.sql)                                     | `castor_admin_list/create/update/delete/confirm_user` (multi-tenant `company_name='castor'`)                                                                                                                                                                                                                                                                                                            |
| 003 | [003_chat.sql](003_chat.sql)                                                           | `castor_chat_session`, `castor_chat_message`, `castor_chat_stamp_user`                                                                                                                                                                                                                                                                                                                                  |
| 004 | [004_runtime.sql](004_runtime.sql)                                                     | `castor_cnpj_cache`, `castor_vendor_user`, `castor_admin_set_vendor_code`, `castor_my_vendor_code`                                                                                                                                                                                                                                                                                                      |
| 005 | [005_sources_protheus.sql](005_sources_protheus.sql)                                   | Espelhos `castor_src_sa3010/cc2010/za7010/sf2010/sc5010`, métricas 12m, `castor_ingest_log`, views v1                                                                                                                                                                                                                                                                                                   |
| 006 | [006_business_core.sql](006_business_core.sql)                                         | `castor_visita_feedback`, `castor_register_visit_feedback`, `castor_route_log`, `castor_haversine_km`                                                                                                                                                                                                                                                                                                   |
| 007 | [007_overrides_and_interactions_tables.sql](007_overrides_and_interactions_tables.sql) | Tabelas `castor_client_address_override`, `castor_client_interactions` (sem funções — dependem de 010)                                                                                                                                                                                                                                                                                                  |
| 008 | [008_metrics_snapshot.sql](008_metrics_snapshot.sql)                                   | `castor_metrics_alltime`, `castor_geocode_cache`, parsers L.E., refresh, views `*_v2` (usam override de 007)                                                                                                                                                                                                                                                                                            |
| 009 | [009_rag.sql](009_rag.sql)                                                             | RAG: `castor_document_metadata`, `castor_document_rows`, `castor_documents` (vector 1536), `match_castor_documents`                                                                                                                                                                                                                                                                                     |
| 010 | [010_routes_and_interactions.sql](010_routes_and_interactions.sql)                     | `castor_route_saved` + **TODAS** as funções de roteiro/cliente (`route_save`, `route_save_unified`, `route_list`, `route_detail`, `route_update_stop`, `route_candidates`, `route_stop_remove`, `route_delete` x2, `client_detail`, `client_address_override_set/get`, `client_status_set`, `client_interaction_add/list`, `client_pending_followups`, `client_recent_changes`, `admin_route_reassign`) |
| 011 | [011_admin_ops.sql](011_admin_ops.sql)                                                 | `admin_vendor_offboard`, `admin_task_assign`, `admin_suggest_pool`, `admin_card_reassign`, `admin_route_move`, `admin_followup_clear_by_user/transfer`, `vendor_orphan_tasks`, `admin_orphan_tasks`                                                                                                                                                                                                     |
| 012 | [012_seed_admin.sql](012_seed_admin.sql)                                               | Cria/garante `admin@castor.com.br` com role `admin`. **Trocar a senha após o primeiro login.**                                                                                                                                                                                                                                                                                                          |

## Aplicar em Supabase novo

No SQL Editor do dashboard:

```sh
# Ordem: cole o conteúdo de cada arquivo, em sequência, e rode.
001 → 002 → 003 → 004 → 005 → 006 → 007 → 008 → 009 → 010 → 011 → 012
```

Ou via psql:

```sh
for f in 001_*.sql 002_*.sql 003_*.sql 004_*.sql 005_*.sql 006_*.sql \
         007_*.sql 008_*.sql 009_*.sql 010_*.sql 011_*.sql 012_*.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
```

## Como o consolidado foi gerado

Partindo das 36 migrations originais (`../migrations/001_bootstrap.sql` … `036_orphan_tasks_align_kanban.sql`),
para cada objeto (`function`, `table`, `view`) foi mantida apenas a **definição mais recente**
(arquivo de número mais alto vence). Os DROPs ficaram comentados no rodapé de cada arquivo
seguindo a regra do repo: **nunca CASCADE**, **nunca ON DELETE CASCADE para `auth.users`**.

Diferença para a numeração original:

- O conteúdo da migration original **010** (snapshot all-time) foi dividido:
  as **tabelas** `castor_client_address_override` e `castor_client_interactions` (que originalmente
  vinham depois, em 015) foram movidas para o **novo 007** porque as views `castor_client_address`
  e `castor_client_metrics_v2` em 008 dependem do override.
- O conteúdo de 015–036 foi consolidado nas versões finais em 010 e 011.

# Regras de Negócio — Agente Castor

Este documento consolida as regras de negócio que o agente Castor deve respeitar. É indexado pelo RAG e também referenciado pelo system prompt do agente principal.

## 1. Fonte de dados

Toda a operação do agente lê de **tabelas espelho/agregadas no Postgres** populadas via upload admin. Os CSVs originais do Protheus ficam armazenados no Google Drive (pasta `DRIVE_FOLDER_ID_SOURCE = 1mFSgsUNhDCAsq73prFtD5b1RyqtXpIUx`) como histórico bruto, e cada upload **substitui o conteúdo preservando o mesmo `file_id`** (Drive nunca sofre `files.delete`).

O workflow `Castor-Source-Manager` expõe:
- `GET  /castor-source-list`    — lista os arquivos canônicos no Drive.
- `GET  /castor-source-status`  — `castor_admin_sources_status()` retorna por tabela: rows_count, last_ingest_at, last_ok, etc.
- `POST /castor-source-replace` — multipart upload. Se o arquivo existe, `files.update` (PATCH) no mesmo `file_id`; senão `files.create`.
- `POST /castor-source-ingest`  — `{ table, file_id }`. Parse streaming + `TRUNCATE + INSERT em lotes` em transação no Postgres, registra em `castor_ingest_log`, invalida cache do Panel-API.

O workflow `Castor-Panel-API` (endpoint `GET /castor-panel-snapshot`) faz **1 query SQL** agregando `castor_src_*`, `castor_metrics_*`, `castor_visita_feedback`, `castor_cnpj_cache` e devolve um snapshot único (cache 5 min em `workflowStaticData`). Não há parse de CSV em runtime.

Não há integração Protheus em tempo real. A frequência das atualizações é decisão da empresa (re-upload via tela admin).

| Arquivo no Drive | Origem Protheus | Tabela Postgres | Conteúdo | Usado em |
|---|---|---|---|---|
| `SA1010.csv` | SA1010 | `castor_src_sa1010` | Cadastro de clientes (CNPJ, endereço, vendedor `a1_vend`, status `a1_ustatus`) | snapshot.clientes |
| `SA3010.csv` | SA3010 | `castor_src_sa3010` | Cadastro de vendedores (`a3_cod`, `a3_nome`) | join `vendedor_nome` |
| `SF2010.csv` | SF2010 | `castor_metrics_sf2010` (agregado) | NF cabeçalho → agregado em 365d: `faturamento_12m`, `pedidos_12m`, `ticket_medio_12m`, `ultima_nota` | snapshot.clientes |
| `SC5010.csv` | SC5010 | `castor_metrics_sc5010` (agregado) | Pedidos cabeçalho → agregado: `ultimo_pedido` / `dias_sem_pedido` | snapshot.clientes |
| `ZA7010.csv` | ZA7010 | `castor_src_za7010` | TMKT / base de leads. Filtrado pelos CNPJs que **não** estão em SA1010 | snapshot.leads |
| `CC2010.csv` | CC2010 | `castor_src_cc2010` | Municípios IBGE com lat/lng | snapshot.municipios + roteirização |

Os demais CSVs (`SB1010`, `SBM010`, `SF4010`, `SX5010`, `SC6010`, `SD2010`, `SZ1010`, `FATOTEMPO`) ficam apenas no Drive como histórico bruto; não entram no snapshot.

## 2. Definição de "cliente inativo elegível para reativação"

**Critério único:** `castor_src_sa1010.a1_ustatus = '2'` (no snapshot: `cliente.a1_ustatus === '2'`).

Não há janela de tempo adicional (ex.: "sem pedido há N dias"). Confiamos 100% no que o ERP marca em `a1_ustatus`. Se o status muda para outro valor (via novo upload de SA1010), o cliente sai automaticamente da fila de reativação.

O subflow `[Castor] Sub-fluxo_ Get Reactivation List` aplica esse filtro sobre `snapshot.clientes` e ainda exclui clientes com `last_feedback.outcome = 'convertido'`.

## 3. Definição de "lead novo"

**Critério:** registro em `ZA7010` cujo CNPJ (apenas dígitos) **não** aparece em `SA1010`. Lead = empresa em prospecção que ainda não virou cliente.

A filtragem é feita pelo `Castor-Panel-API` ao construir `snapshot.leads`.

## 4. Feedback de visita

Toda visita ao cliente gera um registro em `castor_visita_feedback` via RPC `castor_register_visit_feedback`.

Regras de `next_contact_at`:

| outcome | Cálculo |
|---|---|
| `negativo` | `visited_at + COALESCE(custom_days, 20)` dias |
| `voltar_depois` | `visited_at + COALESCE(custom_days, 20)` dias (vendedor pode passar `custom_days` quando o cliente sugeriu data) |
| `convertido` | `next_contact_at = NULL`. Cliente só reentra na fila se `a1_ustatus` voltar a `'2'` |

Vendedor sempre pode sobrescrever os 20 dias default passando `custom_days` no payload.

## 5. Classificação de porte

Há **duas** fontes de porte, com precedência:

1. **Porte efetivo (preferencial)** — calculado pelo ingest do SF2010 a partir do faturamento real
   nos últimos 365 dias (`SF2010.f2_valbrut` agregado por `cliente_codigo = a1_cod || a1_loja`),
   armazenado em `castor_metrics_sf2010.ticket_medio_12m`:

   | Ticket médio 12m | Porte |
   |---|---|
   | < R$ 3.000 | `pequeno` |
   | R$ 3.000 – 10.000 | `medio` |
   | > R$ 10.000 | `grande` |

   Cliente sem histórico recai automaticamente no porte da Receita Federal.
   No snapshot, o campo é exposto como `porte_efetivo` com `porte_origem` em `historico | receita_federal | sem_dados`.

2. **Porte Receita Federal (fallback)** — subflow `[Castor] Sub-fluxo_ Consultar CNPJ`:

1. Consulta cache `castor_cnpj_cache` (TTL 30 dias).
2. Se expirado/ausente: chama BrasilAPI (`https://brasilapi.com.br/api/cnpj/v1/{cnpj}`); fallback ReceitaWS em caso de erro.
3. Armazena `payload` completo + `fetched_at` + `expires_at = fetched_at + 30 days`.

Mapeamento Receita Federal → Castor:

| RF `porte` | Castor |
|---|---|
| `MEI`, `ME` | `pequeno` |
| `EPP` | `medio` |
| `DEMAIS` / qualquer outro | `grande` |

Workflow `Castor-CNPJ-Refresh.json` (cron semanal) renova entradas expiradas em lote.

## 5.1. Fila de reativação priorizada

O subflow `[Castor] Sub-fluxo_ Get Reactivation List` (e o front, em `RoutesPanel.deriveReactivation`) calcula em memória, sobre `snapshot.clientes`:

- `priority_rank` — posição na fila. Ordem: **faturamento dos últimos 12 meses (DESC)**, depois `pedidos_12m`, depois `cliente_codigo`. `#1` = topo da fila.
- `days_until_recall` — `next_contact_at - hoje`. `null` ou `≤0` significa elegível agora.
- `elegivel_agora` — boolean derivado.
- `porte_efetivo`, `faturamento_12m`, `ticket_medio_12m`, `ultima_visita`, `proximo_contato`.

A aba **Roteiros & Clientes** do front consome esses campos para exibir badges
"#1", "faltam 12d", "elegível agora". Não há mais views/RPCs Postgres para essa fila — tudo é derivado do snapshot Drive-only.

## 6. Roteirização

Endpoint `POST /castor-panel-route` (e o subflow `[Castor] Sub-fluxo_ Route Order`):

- Resolve coordenadas usando `snapshot.municipios` (vindo de `CC2010`) por `(a1_mun, a1_est)`. Clientes sem coordenada são devolvidos em `skipped[]`.
- Nearest-neighbor greedy em JS a partir da origem (depósito).
- Distance via Haversine.
- Retorna `stops[]` reordenados (com `leg_km` e `cum_km`), `total_km` e `maps_url` (Google Maps).
- Loga em `castor_route_log` (uma linha por chamada) para auditoria.

Constantes:
- `CASTOR_DEPOT_ADDRESS = 'R. Álvares Cabral, 1049 - Serraria, Diadema - SP, 09980-160'`
- `CASTOR_DEPOT_LAT ≈ -23.6884`
- `CASTOR_DEPOT_LNG ≈ -46.6178`

O front renderiza um modal com lista numerada + km estimado + link `https://www.google.com/maps/dir/?api=1&origin=...&waypoints=...&destination=...`. Não chamamos nenhuma API de mapas paga.

## 7. Visibilidade por role

- **`admin`**: vê todos os clientes, todos os vendedores, todas as visitas.
- **`vendedor`**: vê apenas registros onde `castor_src_sa1010.a1_vend = (SELECT codigo FROM castor_vendor_user WHERE user_id = auth.uid())`.

Mapeamento `user_id ↔ a3_cod` vive em `castor_vendor_user`. Admin gerencia esse vínculo via UI.

Tools enviam `X-User-Id` e `X-User-Role` como headers; RPCs `SECURITY DEFINER` aplicam o filtro server-side. O front nunca decide visibilidade sozinho.

## 8. Bloco de resposta especializado

O agente principal pode emitir blocos fenced renderizados pelo front:

- ```` ```castor-route ```` — lista roteirizada
- ```` ```castor-client-card ```` — card de cliente com porte/contato/última visita
- ```` ```castor-lead-card ```` — card de lead novo
- ```` ```castor-feedback-form ```` — formulário inline pós-visita

Schemas detalhados ficam no system prompt do `Castor-Agent-IA.json`.

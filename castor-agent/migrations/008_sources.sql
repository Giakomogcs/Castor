-- file: 008_castor_sources.sql
-- tier: A
-- purpose:
--   Tabelas espelho das fontes Protheus disponíveis (SEM SA1010 — não foi liberado).
--   CSVs são dumps posicionais sem header; o parser do workflow Castor-Source-Manager
--   converte por POSIÇÃO conhecida (ver mapa em /memories/session/castor-rewrite-plan.md).
--
--   Fontes disponíveis: SF2010 (NF cab), SC5010 (pedido cab), ZA7010 (TMKT),
--   SA3010 (vendedores), CC2010 (municípios).
--
--   "Cliente master" é DERIVADO via view `castor_clientes_derived` (UNION de
--   códigos vistos em SC5/SF2/ZA7 + nome best-effort dos campos embutidos).
--
-- depends: 001, 004
-- reversible: yes
-- IDEMPOTENTE.

BEGIN;

-- ============================================================
-- Cleanup de schema antigo (caso 008 anterior tenha rodado)
-- ============================================================
DROP VIEW IF EXISTS castor_client_metrics;
DROP VIEW IF EXISTS castor_clientes_derived;
DROP TABLE IF EXISTS castor_src_sa1010;

-- ============================================================
-- SA3010 — vendedores (pos: 1=A3_FILIAL, 2=A3_COD, 3=A3_NOME, 4=A3_NREDUZ)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sa3010 (
  a3_cod      TEXT PRIMARY KEY,
  a3_nome     TEXT,
  a3_nreduz   TEXT,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- migration: drop legacy column a3_email if present (no source)
ALTER TABLE castor_src_sa3010 DROP COLUMN IF EXISTS a3_email;
ALTER TABLE castor_src_sa3010 ADD COLUMN IF NOT EXISTS a3_nreduz TEXT;

-- ============================================================
-- CC2010 — municípios (pos: 1=FILIAL, 2=EST, 3=CODMUN, 4=MUN)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_cc2010 (
  cc2_est     TEXT NOT NULL,
  cc2_codmun  TEXT NOT NULL,
  cc2_mun     TEXT,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (cc2_est, cc2_codmun)
);
-- migration: dropar schema legado (id/mun/est/lat/lng)
ALTER TABLE castor_src_cc2010 DROP COLUMN IF EXISTS id;
ALTER TABLE castor_src_cc2010 DROP COLUMN IF EXISTS lat;
ALTER TABLE castor_src_cc2010 DROP COLUMN IF EXISTS lng;
ALTER TABLE castor_src_cc2010 DROP COLUMN IF EXISTS mun;
ALTER TABLE castor_src_cc2010 DROP COLUMN IF EXISTS est;

CREATE INDEX IF NOT EXISTS castor_src_cc2010_mun_idx ON castor_src_cc2010(cc2_mun);

-- ============================================================
-- ZA7010 — TMKT (uma linha por ligação)
-- pos: 1=FILIAL, 2=OPERAD, 3=NOMEOP, 6=STAATE (assunto), 7=DATA, 8=HORA,
--      13=DESCNT (contato), 14=CODCLI, 15=DESCLI (nome cli embutido),
--      16=VEND, 19=COMPLE
-- ============================================================
-- migration: schema antigo (id, za7_cnpj…) → novo
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_id;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_cnpj;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_tel;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_email;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_mun;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_est;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_segmento;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_status;
ALTER TABLE IF EXISTS castor_src_za7010 DROP COLUMN IF EXISTS za7_nome;
DROP TABLE IF EXISTS castor_src_za7010;

CREATE TABLE castor_src_za7010 (
  id           BIGSERIAL PRIMARY KEY,
  za7_data     DATE,
  za7_hora     TEXT,
  za7_operad   TEXT,
  za7_nomeop   TEXT,
  za7_assunto  TEXT,
  za7_contato  TEXT,
  za7_cliente  TEXT,
  za7_nome_cli TEXT,
  za7_vend     TEXT,
  za7_compl    TEXT,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX castor_src_za7010_cliente_idx ON castor_src_za7010(za7_cliente);
CREATE INDEX castor_src_za7010_data_idx    ON castor_src_za7010(za7_data DESC);

-- ============================================================
-- SF2010 — uma linha por NF (cabeçalho)
-- pos: 1=FILIAL, 2=DOC, 3=SERIE, 4=CLIENTE, 5=LOJA, 8=EMISSAO, 14=VALBRUT
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sf2010 (
  id           BIGSERIAL PRIMARY KEY,
  f2_doc       TEXT,
  f2_serie     TEXT,
  f2_cliente   TEXT,
  f2_loja      TEXT,
  f2_emissao   DATE,
  f2_valor     NUMERIC(14,2) DEFAULT 0,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_src_sf2010_cli_idx ON castor_src_sf2010(f2_cliente, f2_loja);
CREATE INDEX IF NOT EXISTS castor_src_sf2010_emis_idx ON castor_src_sf2010(f2_emissao DESC);

-- ============================================================
-- SC5010 — uma linha por pedido (cabeçalho)
-- pos: 1=FILIAL, 3=NUM, 4=CLIENTE, 5=LOJACLI, 10=YNOMEC (nome), 13=VEND1, 42=EMISSAO
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sc5010 (
  id           BIGSERIAL PRIMARY KEY,
  c5_num       TEXT,
  c5_cliente   TEXT,
  c5_loja      TEXT,
  c5_nome      TEXT,
  c5_vend      TEXT,
  c5_emissao   DATE,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_src_sc5010_cli_idx ON castor_src_sc5010(c5_cliente, c5_loja);
CREATE INDEX IF NOT EXISTS castor_src_sc5010_emis_idx ON castor_src_sc5010(c5_emissao DESC);

-- ============================================================
-- AGREGADOS pré-computados (refresh via função, chamado após ingest)
-- ============================================================
DROP TABLE IF EXISTS castor_metrics_sf2010;
DROP TABLE IF EXISTS castor_metrics_sc5010;
CREATE TABLE castor_metrics_sf2010 (
  cliente_codigo   TEXT PRIMARY KEY,
  faturamento_12m  NUMERIC(14,2) NOT NULL DEFAULT 0,
  pedidos_12m      INT NOT NULL DEFAULT 0,
  ticket_medio_12m NUMERIC(14,2) NOT NULL DEFAULT 0,
  ultima_nota      DATE,
  computed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX castor_metrics_sf2010_fat_idx ON castor_metrics_sf2010(faturamento_12m DESC);

CREATE TABLE castor_metrics_sc5010 (
  cliente_codigo TEXT PRIMARY KEY,
  ultimo_pedido  DATE,
  computed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- VIEW: Cliente master DERIVADO (substitui SA1010 ausente)
-- Junta todos os códigos vistos em SC5/SF2/ZA7 + nome best-effort.
-- ============================================================
CREATE OR REPLACE VIEW castor_clientes_derived AS
WITH unioned AS (
  SELECT (f2_cliente || COALESCE(f2_loja,'')) AS cliente_codigo,
         f2_cliente AS cod, f2_loja AS loja, NULL::TEXT AS nome, NULL::TEXT AS vend
    FROM castor_src_sf2010
   WHERE f2_cliente IS NOT NULL AND f2_cliente <> ''
  UNION ALL
  SELECT (c5_cliente || COALESCE(c5_loja,'')), c5_cliente, c5_loja, c5_nome, c5_vend
    FROM castor_src_sc5010
   WHERE c5_cliente IS NOT NULL AND c5_cliente <> ''
  UNION ALL
  SELECT (za7_cliente || '01'), za7_cliente, '01', za7_nome_cli, za7_vend
    FROM castor_src_za7010
   WHERE za7_cliente IS NOT NULL AND za7_cliente <> ''
)
SELECT cliente_codigo,
       MAX(cod)  AS a1_cod,
       MAX(loja) AS a1_loja,
       MAX(NULLIF(BTRIM(nome),'')) AS a1_nome,
       MAX(NULLIF(BTRIM(vend),'')) AS a1_vend
  FROM unioned
 GROUP BY cliente_codigo;

-- ============================================================
-- VIEW: métricas consolidadas + status inferido
-- ============================================================
CREATE OR REPLACE VIEW castor_client_metrics AS
SELECT
  d.cliente_codigo,
  d.a1_cod,
  d.a1_loja,
  d.a1_nome,
  d.a1_vend,
  v.a3_nome AS vendedor_nome,
  COALESCE(f.faturamento_12m, 0)   AS faturamento_12m,
  COALESCE(f.pedidos_12m, 0)       AS pedidos_12m,
  COALESCE(f.ticket_medio_12m, 0)  AS ticket_medio_12m,
  f.ultima_nota,
  c.ultimo_pedido,
  CASE
    WHEN f.ultima_nota >= (CURRENT_DATE - INTERVAL '90 days')  THEN 'ATIVO'
    WHEN f.ultima_nota >= (CURRENT_DATE - INTERVAL '180 days') THEN 'EM_RISCO'
    WHEN f.ultima_nota >= (CURRENT_DATE - INTERVAL '365 days') THEN 'REATIVAR'
    WHEN f.ultima_nota IS NOT NULL                              THEN 'INATIVO'
    WHEN c.ultimo_pedido IS NOT NULL                            THEN 'PROSPECT'
    ELSE 'SEM_HISTORICO'
  END AS status_inferido
FROM castor_clientes_derived d
LEFT JOIN castor_metrics_sf2010 f ON f.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_metrics_sc5010 c ON c.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_src_sa3010   v ON v.a3_cod = d.a1_vend;

-- ============================================================
-- FUNÇÃO: refresh dos agregados (chamada pelo Source-Manager após
-- ingest de SF2010 ou SC5010). Calcula janela 12m diretamente em SQL.
-- ============================================================
CREATE OR REPLACE FUNCTION castor_refresh_metrics_sf()
RETURNS INT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_rows INT;
BEGIN
  TRUNCATE castor_metrics_sf2010;
  -- Insere TODOS os clientes que já tiveram alguma NF (ultima_nota all-time),
  -- mas só conta faturamento/pedidos dentro da janela 365d.
  -- Isso permite que `status_inferido` chegue em INATIVO quando a última NF
  -- existe mas está fora dos 365 dias.
  INSERT INTO castor_metrics_sf2010(cliente_codigo, faturamento_12m, pedidos_12m, ticket_medio_12m, ultima_nota)
  SELECT (f2_cliente || COALESCE(f2_loja,'')) AS cliente_codigo,
         ROUND(COALESCE(SUM(f2_valor) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0)::NUMERIC, 2) AS faturamento_12m,
         COALESCE(COUNT(*) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0)::INT             AS pedidos_12m,
         ROUND(
           (COALESCE(SUM(f2_valor) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0)
            / NULLIF(COUNT(*) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0))::NUMERIC, 2) AS ticket_medio_12m,
         MAX(f2_emissao)                                AS ultima_nota
    FROM castor_src_sf2010
   WHERE f2_cliente IS NOT NULL AND f2_cliente <> ''
   GROUP BY 1;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

CREATE OR REPLACE FUNCTION castor_refresh_metrics_sc()
RETURNS INT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_rows INT;
BEGIN
  TRUNCATE castor_metrics_sc5010;
  INSERT INTO castor_metrics_sc5010(cliente_codigo, ultimo_pedido)
  SELECT (c5_cliente || COALESCE(c5_loja,'')) AS cliente_codigo,
         MAX(c5_emissao)
    FROM castor_src_sc5010
   WHERE c5_cliente IS NOT NULL AND c5_cliente <> ''
   GROUP BY 1;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_refresh_metrics_sf() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_refresh_metrics_sc() TO authenticated, service_role;

-- ============================================================
-- LOG DE INGESTÕES
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_ingest_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name   TEXT NOT NULL,
  file_id      TEXT,
  file_name    TEXT,
  uploaded_by  UUID,
  rows_in      INT,
  rows_out     INT,
  duration_ms  INT,
  ok           BOOLEAN,
  error        TEXT,
  started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS castor_ingest_log_table_idx ON castor_ingest_log(table_name, started_at DESC);

-- ============================================================
-- RPC: status atual das fontes
-- ============================================================
CREATE OR REPLACE FUNCTION castor_admin_sources_status()
RETURNS TABLE(
  table_name       TEXT,
  rows_count       BIGINT,
  last_ingest_at   TIMESTAMPTZ,
  last_rows_in     INT,
  last_rows_out    INT,
  last_duration_ms INT,
  last_ok          BOOLEAN,
  last_error       TEXT,
  last_file_name   TEXT,
  last_file_id     TEXT
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
#variable_conflict use_column
DECLARE
  v_tables TEXT[] := ARRAY['sa3010','cc2010','za7010','sf2010','sc5010'];
  v_t TEXT;
  v_count BIGINT;
  v_log castor_ingest_log%ROWTYPE;
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  FOREACH v_t IN ARRAY v_tables LOOP
    EXECUTE format('SELECT COUNT(*) FROM castor_src_%I', v_t) INTO v_count;
    SELECT l.* INTO v_log
      FROM castor_ingest_log l
      WHERE l.table_name = v_t
      ORDER BY l.started_at DESC
      LIMIT 1;
    table_name       := v_t;
    rows_count       := v_count;
    last_ingest_at   := v_log.started_at;
    last_rows_in     := v_log.rows_in;
    last_rows_out    := v_log.rows_out;
    last_duration_ms := v_log.duration_ms;
    last_ok          := v_log.ok;
    last_error       := v_log.error;
    last_file_name   := v_log.file_name;
    last_file_id     := v_log.file_id;
    RETURN NEXT;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION castor_admin_sources_status() TO authenticated;

-- ============================================================
-- RPCs do log (start/finish) — usados pelo Castor-Source-Manager
-- ============================================================
CREATE OR REPLACE FUNCTION castor_ingest_log_start(
  p_table_name TEXT, p_file_id TEXT, p_file_name TEXT, p_uploaded_by UUID
) RETURNS UUID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO castor_ingest_log(table_name, file_id, file_name, uploaded_by)
  VALUES (p_table_name, p_file_id, p_file_name, p_uploaded_by)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION castor_ingest_log_finish(
  p_id UUID, p_rows_in INT, p_rows_out INT, p_duration_ms INT,
  p_ok BOOLEAN, p_error TEXT
) RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE castor_ingest_log
     SET rows_in = p_rows_in,
         rows_out = p_rows_out,
         duration_ms = p_duration_ms,
         ok = p_ok,
         error = p_error,
         finished_at = NOW()
   WHERE id = p_id;
END;
$$;
GRANT EXECUTE ON FUNCTION castor_ingest_log_start(TEXT, TEXT, TEXT, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_ingest_log_finish(UUID, INT, INT, INT, BOOLEAN, TEXT) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version) VALUES ('008_sources') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

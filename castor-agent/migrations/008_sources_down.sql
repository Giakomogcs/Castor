-- file: 008_sources_down.sql
-- tier: A
-- purpose:
--   Reverte 008_sources.sql. Use quando a migration foi aplicada parcialmente
--   (ex.: `castor_client_metrics` criada como TABLE em versão anterior e agora
--   o `CREATE OR REPLACE VIEW` falha com:
--       ERROR 42809: "castor_client_metrics" is not a view
--
--   Estratégia: dropar o objeto independentemente do tipo (view, mview, table),
--   dropar as tabelas/funcs/log criados em 008 e remover a linha de
--   castor_schema_migrations para permitir re-rodar 008_sources.sql limpo.
--
--   NÃO usa CASCADE. Drops são feitos na ordem inversa de dependência.
-- depends: 008
-- reversible: n/a (este É o down)

BEGIN;

-- ---------------------------------------------------------------
-- Helper local: dropa public.<name> seja qual for o relkind.
-- Evita "X is not a view" quando versão anterior criou o objeto
-- como tabela e a nova define como view (ou vice-versa).
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp._castor_drop_any(p_name TEXT)
RETURNS VOID
LANGUAGE plpgsql AS $fn$
DECLARE
  v_kind CHAR;
BEGIN
  SELECT c.relkind
    INTO v_kind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = p_name;

  IF v_kind IS NULL THEN
    RETURN;
  ELSIF v_kind = 'v' THEN
    EXECUTE format('DROP VIEW public.%I', p_name);
  ELSIF v_kind = 'm' THEN
    EXECUTE format('DROP MATERIALIZED VIEW public.%I', p_name);
  ELSIF v_kind IN ('r','p') THEN
    EXECUTE format('DROP TABLE public.%I', p_name);
  ELSE
    RAISE EXCEPTION '% tem relkind inesperado: %', p_name, v_kind;
  END IF;
END;
$fn$;

-- ---------------------------------------------------------------
-- 1) RPCs / funções públicas criadas em 008
-- ---------------------------------------------------------------
DROP FUNCTION IF EXISTS castor_refresh_metrics_sf();
DROP FUNCTION IF EXISTS castor_refresh_metrics_sc();
DROP FUNCTION IF EXISTS castor_ingest_log_finish(UUID, INT, INT, INT, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS castor_ingest_log_start(TEXT, TEXT, TEXT, UUID);
DROP FUNCTION IF EXISTS castor_admin_sources_status();

-- ---------------------------------------------------------------
-- 2) Views derivadas (ordem inversa de dependência:
--    castor_client_metrics depende de castor_clientes_derived)
-- ---------------------------------------------------------------
SELECT pg_temp._castor_drop_any('castor_client_metrics');
SELECT pg_temp._castor_drop_any('castor_clientes_derived');

-- ---------------------------------------------------------------
-- 3) Métricas agregadas
-- ---------------------------------------------------------------
SELECT pg_temp._castor_drop_any('castor_metrics_sc5010');
SELECT pg_temp._castor_drop_any('castor_metrics_sf2010');

-- ---------------------------------------------------------------
-- 4) Tabelas espelho dos CSVs Protheus
--    Inclui sa1010 (legacy da versão antiga do 008) + as 5 atuais.
-- ---------------------------------------------------------------
SELECT pg_temp._castor_drop_any('castor_src_sc5010');
SELECT pg_temp._castor_drop_any('castor_src_sf2010');
SELECT pg_temp._castor_drop_any('castor_src_cc2010');
SELECT pg_temp._castor_drop_any('castor_src_za7010');
SELECT pg_temp._castor_drop_any('castor_src_sa3010');
SELECT pg_temp._castor_drop_any('castor_src_sa1010');

-- ---------------------------------------------------------------
-- 5) Log de ingestões
-- ---------------------------------------------------------------
SELECT pg_temp._castor_drop_any('castor_ingest_log');

-- ---------------------------------------------------------------
-- 6) Marca migration como não aplicada (idempotente)
-- ---------------------------------------------------------------
DELETE FROM castor_schema_migrations WHERE version = '008_sources';

COMMIT;

NOTIFY pgrst, 'reload schema';

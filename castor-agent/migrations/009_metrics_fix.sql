-- file: 009_metrics_fix.sql
-- tier: A
-- purpose:
--   Fix em castor_refresh_metrics_sf(): coluna ticket_medio_12m é NOT NULL,
--   mas a fórmula antiga (SUM / NULLIF(COUNT, 0)) gera NULL para clientes que
--   tiveram NF histórica mas zero NFs nos últimos 365d → INSERT falha com
--   "null value in column ticket_medio_12m of relation castor_metrics_sf2010".
--   Solução: COALESCE(..., 0) no ticket_medio (e idem no faturamento por consistência).
-- depends: 008
-- reversible: yes (basta dar CREATE OR REPLACE com a versão antiga)
-- IDEMPOTENTE.

BEGIN;

CREATE OR REPLACE FUNCTION castor_refresh_metrics_sf()
RETURNS INT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_rows INT;
BEGIN
  TRUNCATE castor_metrics_sf2010;
  INSERT INTO castor_metrics_sf2010(cliente_codigo, faturamento_12m, pedidos_12m, ticket_medio_12m, ultima_nota)
  SELECT (f2_cliente || COALESCE(f2_loja,'')) AS cliente_codigo,
         COALESCE(ROUND(COALESCE(SUM(f2_valor) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0)::NUMERIC, 2), 0) AS faturamento_12m,
         COALESCE(COUNT(*) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0)::INT AS pedidos_12m,
         COALESCE(
           ROUND(
             (COALESCE(SUM(f2_valor) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0)
              / NULLIF(COUNT(*) FILTER (WHERE f2_emissao >= (CURRENT_DATE - INTERVAL '365 days')), 0))::NUMERIC,
             2
           ),
           0
         ) AS ticket_medio_12m,
         MAX(f2_emissao) AS ultima_nota
    FROM castor_src_sf2010
   WHERE f2_cliente IS NOT NULL AND f2_cliente <> ''
   GROUP BY 1;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_refresh_metrics_sf() TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version) VALUES ('009_metrics_fix') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 012_geocode_cleanup.sql
-- Remove linhas lixo geradas pelo bug do Geocode-Warmup
-- (n8n Postgres v2.6 injetou `{success:true}` quando 0 linhas
--  pendentes, e o SplitInBatches iterou com mun=undefined).
-- ============================================================

BEGIN;

DELETE FROM castor_geocode_cache
 WHERE scope = 'municipio'
   AND (
        query_key IS NULL
     OR upper(query_key) LIKE '%UNDEFINED%'
     OR query_key = '|'
     OR municipio IS NULL
     OR upper(coalesce(municipio,'')) = 'UNDEFINED'
   );

INSERT INTO castor_schema_migrations(version) VALUES ('012_geocode_cleanup')
  ON CONFLICT (version) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

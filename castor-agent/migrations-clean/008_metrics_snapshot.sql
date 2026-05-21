-- file: 008_metrics_snapshot.sql
-- tier: A
-- purpose: Snapshot all-time + cache de geocoding + parser de L.E. (endereço Protheus) +
--   views unificadas castor_clientes_derived_v2, castor_client_address, castor_client_metrics_v2.
-- depends: 001, 005, 006, 007
-- IDEMPOTENTE.

BEGIN;

CREATE TABLE IF NOT EXISTS castor_metrics_alltime (
  cliente_codigo       TEXT PRIMARY KEY,
  faturamento_alltime  NUMERIC(14,2) NOT NULL DEFAULT 0,
  pedidos_alltime      INT NOT NULL DEFAULT 0,
  ticket_medio_alltime NUMERIC(14,2) NOT NULL DEFAULT 0,
  primeira_nota        DATE,
  ultima_nota          DATE,
  primeiro_pedido      DATE,
  ultimo_pedido        DATE,
  ultima_atividade     DATE,
  computed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_metrics_alltime_fat_idx ON castor_metrics_alltime(faturamento_alltime DESC);
CREATE INDEX IF NOT EXISTS castor_metrics_alltime_ult_idx ON castor_metrics_alltime(ultima_atividade DESC);

CREATE TABLE IF NOT EXISTS castor_geocode_cache (
  id            BIGSERIAL PRIMARY KEY,
  scope         TEXT NOT NULL CHECK (scope IN ('municipio','endereco')),
  query_key     TEXT NOT NULL,
  uf            TEXT,
  municipio     TEXT,
  endereco      TEXT,
  cep           TEXT,
  lat           DOUBLE PRECISION,
  lng           DOUBLE PRECISION,
  display_name  TEXT,
  source        TEXT NOT NULL DEFAULT 'nominatim',
  ok            BOOLEAN NOT NULL DEFAULT TRUE,
  fetched_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (scope, query_key)
);
CREATE INDEX IF NOT EXISTS castor_geocode_cache_munuf_idx
  ON castor_geocode_cache(scope, uf, municipio);

CREATE OR REPLACE FUNCTION castor_parse_le(p_text TEXT)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  s        TEXT := upper(coalesce(p_text, ''));
  m        TEXT[];
  v_cep    TEXT;
  v_mun    TEXT;
  v_uf     TEXT;
  v_end    TEXT;
BEGIN
  IF btrim(s) = '' THEN
    RETURN jsonb_build_object('endereco', NULL, 'cep', NULL, 'municipio', NULL, 'uf', NULL);
  END IF;

  m := regexp_match(s, 'CEP:?\s*([0-9]{5})-?([0-9]{3})\s+(.+?)-([A-Z]{2})(?:\s|$)');
  IF m IS NOT NULL THEN
    v_cep := m[1] || m[2];
    v_mun := btrim(m[3]);
    v_uf  := m[4];
  ELSE
    m := regexp_match(s, 'CEP:?\s*([0-9]{5})-?([0-9]{3})');
    IF m IS NOT NULL THEN v_cep := m[1] || m[2]; END IF;
    m := regexp_match(s, '([A-ZÀ-Ú][A-ZÀ-Ú0-9 .\/]{1,60})-([A-Z]{2})(?:[^A-Z]|$)');
    IF m IS NOT NULL THEN
      v_mun := btrim(m[1]);
      v_uf  := m[2];
    END IF;
  END IF;

  IF v_mun IS NOT NULL THEN
    v_mun := btrim(regexp_replace(v_mun, '\s+[0-9]+\s*$', '', 'g'));
    v_mun := regexp_replace(v_mun, '\s+', ' ', 'g');
    IF v_mun = '' THEN v_mun := NULL; END IF;
  END IF;

  v_end := regexp_replace(s, '\s*CEP:?\s*[0-9]{5}-?[0-9]{3}.*$', '', 'i');
  v_end := regexp_replace(v_end, '^\s*L\.?E\.?:?\s*', '', 'i');
  v_end := btrim(v_end);
  IF v_end = '' THEN v_end := NULL; END IF;

  RETURN jsonb_build_object(
    'endereco',  v_end,
    'cep',       v_cep,
    'municipio', v_mun,
    'uf',        v_uf
  );
END;
$$;

CREATE OR REPLACE FUNCTION castor_parse_le_full(p_text TEXT)
RETURNS TABLE(endereco TEXT, cep TEXT, municipio TEXT, uf TEXT)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_block TEXT;
  v_cep   TEXT;
  v_mun   TEXT;
  v_uf    TEXT;
  v_end   TEXT;
  v_after_cep TEXT;
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN;
  END IF;

  v_block := substring(upper(p_text)
    FROM '(?:L\.?\s*E\s*\.?\s*:?)\s*(.+?)(?:\s+PEDIDO\b|$)');

  IF v_block IS NULL OR btrim(v_block) = '' THEN
    RETURN;
  END IF;

  v_cep := substring(v_block FROM 'CEP\s*:?\s*([0-9]{8})');
  IF v_cep IS NULL THEN
    v_cep := substring(v_block FROM '([0-9]{5}-?[0-9]{3})');
    IF v_cep IS NOT NULL THEN
      v_cep := regexp_replace(v_cep, '\D', '', 'g');
    END IF;
  END IF;

  v_after_cep := v_block;
  IF v_cep IS NOT NULL THEN
    v_after_cep := regexp_replace(v_after_cep, 'CEP\s*:?\s*' || v_cep, '', 'g');
  END IF;
  v_mun := substring(v_after_cep FROM '([A-ZÇÁÉÍÓÚÂÊÔÃÕÀ\.\s]{3,})\-([A-Z]{2})\s*$');
  v_uf  := substring(v_after_cep FROM '\-([A-Z]{2})\s*$');
  IF v_mun IS NOT NULL THEN v_mun := btrim(v_mun); END IF;

  v_end := v_block;
  v_end := regexp_replace(v_end, '\s*CEP\s*:?\s*[0-9]{8}\b.*$', '', 'g');
  v_end := regexp_replace(v_end, '\s*[0-9]{5}-?[0-9]{3}\b.*$', '', 'g');
  IF v_end = v_block AND v_uf IS NOT NULL THEN
    v_end := regexp_replace(v_end, '\s*[A-ZÇÁÉÍÓÚÂÊÔÃÕÀ\.\s]{3,}\-[A-Z]{2}\s*$', '', 'g');
  END IF;
  v_end := btrim(v_end);
  IF v_end = '' THEN v_end := NULL; END IF;

  endereco  := v_end;
  cep       := v_cep;
  municipio := v_mun;
  uf        := v_uf;
  RETURN NEXT;
END; $$;

CREATE OR REPLACE FUNCTION castor_refresh_sc5_address()
RETURNS INT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_rows INT;
BEGIN
  UPDATE castor_src_sc5010 SET
    c5_end = (castor_parse_le(c5_le_raw)->>'endereco'),
    c5_cep = (castor_parse_le(c5_le_raw)->>'cep'),
    c5_mun = (castor_parse_le(c5_le_raw)->>'municipio'),
    c5_uf  = (castor_parse_le(c5_le_raw)->>'uf')
  WHERE c5_le_raw IS NOT NULL AND c5_le_raw <> '';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

CREATE OR REPLACE FUNCTION castor_refresh_metrics_alltime()
RETURNS INT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_rows INT;
BEGIN
  TRUNCATE castor_metrics_alltime;
  WITH f AS (
    SELECT (f2_cliente || COALESCE(f2_loja,'')) AS cliente_codigo,
           COALESCE(SUM(f2_valor), 0)::NUMERIC(14,2) AS faturamento,
           COUNT(*)::INT AS notas,
           MIN(f2_emissao) AS primeira_nota,
           MAX(f2_emissao) AS ultima_nota
      FROM castor_src_sf2010
     WHERE f2_cliente IS NOT NULL AND f2_cliente <> ''
     GROUP BY 1
  ),
  c AS (
    SELECT (c5_cliente || COALESCE(c5_loja,'')) AS cliente_codigo,
           MIN(c5_emissao) AS primeiro_pedido,
           MAX(c5_emissao) AS ultimo_pedido
      FROM castor_src_sc5010
     WHERE c5_cliente IS NOT NULL AND c5_cliente <> ''
     GROUP BY 1
  ),
  u AS (
    SELECT cliente_codigo FROM f
    UNION
    SELECT cliente_codigo FROM c
  )
  INSERT INTO castor_metrics_alltime(
    cliente_codigo, faturamento_alltime, pedidos_alltime, ticket_medio_alltime,
    primeira_nota, ultima_nota, primeiro_pedido, ultimo_pedido, ultima_atividade
  )
  SELECT u.cliente_codigo,
         COALESCE(f.faturamento, 0),
         COALESCE(f.notas, 0),
         CASE WHEN COALESCE(f.notas,0) > 0
              THEN ROUND((f.faturamento / f.notas)::NUMERIC, 2)
              ELSE 0
         END,
         f.primeira_nota,
         f.ultima_nota,
         c.primeiro_pedido,
         c.ultimo_pedido,
         GREATEST(f.ultima_nota, c.ultimo_pedido)
    FROM u
    LEFT JOIN f USING (cliente_codigo)
    LEFT JOIN c USING (cliente_codigo);
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

CREATE OR REPLACE FUNCTION castor_geocode_lookup(p_scope TEXT, p_key TEXT)
RETURNS castor_geocode_cache
LANGUAGE sql STABLE AS $$
  SELECT * FROM castor_geocode_cache
   WHERE scope = p_scope AND query_key = p_key
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION castor_geocode_upsert(
  p_scope TEXT, p_key TEXT,
  p_uf TEXT, p_mun TEXT, p_endereco TEXT, p_cep TEXT,
  p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION,
  p_display TEXT, p_source TEXT, p_ok BOOLEAN
) RETURNS castor_geocode_cache
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_row castor_geocode_cache;
BEGIN
  INSERT INTO castor_geocode_cache(scope, query_key, uf, municipio, endereco, cep, lat, lng, display_name, source, ok)
  VALUES (p_scope, p_key, p_uf, p_mun, p_endereco, p_cep, p_lat, p_lng, p_display, COALESCE(p_source,'nominatim'), COALESCE(p_ok,TRUE))
  ON CONFLICT (scope, query_key) DO UPDATE SET
    uf=EXCLUDED.uf, municipio=EXCLUDED.municipio, endereco=EXCLUDED.endereco, cep=EXCLUDED.cep,
    lat=EXCLUDED.lat, lng=EXCLUDED.lng, display_name=EXCLUDED.display_name,
    source=EXCLUDED.source, ok=EXCLUDED.ok, fetched_at=NOW()
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION castor_user_scope(p_user_id UUID)
RETURNS TABLE(role TEXT, vendor_code TEXT, estados TEXT[], cidades TEXT[])
LANGUAGE sql STABLE AS $$
  SELECT
    COALESCE(u.raw_user_meta_data->>'role','vendedor')::TEXT,
    (SELECT codigo FROM castor_vendor_user vu WHERE vu.user_id = u.id),
    CASE
      WHEN jsonb_typeof(u.raw_user_meta_data->'estados') = 'array'
        THEN ARRAY(SELECT upper(jsonb_array_elements_text(u.raw_user_meta_data->'estados')))
      ELSE NULL::TEXT[]
    END,
    CASE
      WHEN jsonb_typeof(u.raw_user_meta_data->'cidades') = 'array'
        THEN ARRAY(SELECT upper(jsonb_array_elements_text(u.raw_user_meta_data->'cidades')))
      ELSE NULL::TEXT[]
    END
  FROM auth.users u
  WHERE u.id = p_user_id;
$$;

-- Views unificadas (dependem de castor_client_address_override de 007) ----------
CREATE OR REPLACE VIEW castor_clientes_derived_v2 AS
WITH unioned AS (
  SELECT (f2_cliente || COALESCE(f2_loja,'')) AS cliente_codigo,
         f2_cliente AS cod, f2_loja AS loja, NULL::TEXT AS nome, NULL::TEXT AS vend,
         f2_emissao AS dt
    FROM castor_src_sf2010
   WHERE f2_cliente IS NOT NULL AND f2_cliente <> ''
  UNION ALL
  SELECT (c5_cliente || COALESCE(c5_loja,'')),
         c5_cliente, c5_loja, c5_nome, c5_vend,
         c5_emissao
    FROM castor_src_sc5010
   WHERE c5_cliente IS NOT NULL AND c5_cliente <> ''
),
ranked AS (
  SELECT cliente_codigo, cod, loja, nome, vend,
         ROW_NUMBER() OVER (
           PARTITION BY cliente_codigo
           ORDER BY (nome IS NOT NULL AND btrim(nome) <> '') DESC,
                    (vend IS NOT NULL AND btrim(vend) <> '') DESC,
                    dt DESC NULLS LAST
         ) AS rn
    FROM unioned
)
SELECT cliente_codigo, cod AS a1_cod, loja AS a1_loja,
       NULLIF(btrim(nome),'') AS a1_nome,
       NULLIF(btrim(vend),'') AS a1_vend
  FROM ranked
 WHERE rn = 1;

CREATE OR REPLACE VIEW castor_client_address AS
WITH ranked AS (
  SELECT (c5_cliente || COALESCE(c5_loja,'')) AS cliente_codigo,
         c5_end, c5_cep, c5_mun, c5_uf, c5_emissao,
         ROW_NUMBER() OVER (
           PARTITION BY (c5_cliente || COALESCE(c5_loja,''))
           ORDER BY (c5_uf IS NOT NULL) DESC, c5_emissao DESC NULLS LAST
         ) AS rn
    FROM castor_src_sc5010
   WHERE c5_cliente IS NOT NULL AND c5_cliente <> ''
),
parsed AS (
  SELECT
    r.cliente_codigo,
    r.c5_end, r.c5_cep, r.c5_mun, r.c5_uf,
    le.endereco  AS le_end,
    le.cep       AS le_cep,
    le.municipio AS le_mun,
    le.uf        AS le_uf
  FROM ranked r
  LEFT JOIN LATERAL castor_parse_le_full(r.c5_end) le ON true
  WHERE r.rn = 1
),
sc5 AS (
  SELECT
    cliente_codigo,
    COALESCE(
      NULLIF(btrim(le_end), ''),
      CASE
        WHEN c5_end IS NOT NULL
          AND upper(c5_end) NOT LIKE '%PEDIDO%'
          AND upper(c5_end) NOT LIKE '%ORDEM DE COMPRA%'
          AND upper(c5_end) NOT LIKE '%OC %'
          AND length(btrim(c5_end)) >= 8
        THEN btrim(c5_end)
        ELSE NULL
      END
    ) AS endereco,
    COALESCE(NULLIF(btrim(le_cep),''), NULLIF(btrim(c5_cep),'')) AS cep,
    COALESCE(NULLIF(btrim(le_mun),''), NULLIF(btrim(c5_mun),'')) AS municipio,
    COALESCE(NULLIF(btrim(le_uf),''),  NULLIF(btrim(c5_uf),''))  AS uf
  FROM parsed
)
SELECT
  COALESCE(o.cliente_codigo, sc5.cliente_codigo) AS cliente_codigo,
  COALESCE(NULLIF(btrim(o.endereco),''),  sc5.endereco)  AS endereco,
  COALESCE(NULLIF(btrim(o.cep),''),       sc5.cep)       AS cep,
  COALESCE(NULLIF(btrim(o.municipio),''), sc5.municipio) AS municipio,
  COALESCE(NULLIF(btrim(o.uf),''),        sc5.uf)        AS uf,
  o.contato_nome,
  o.contato_tel,
  o.contato_whats,
  o.contato_email,
  o.lifecycle_status,
  CASE WHEN o.cliente_codigo IS NOT NULL THEN 'override'
       WHEN sc5.endereco IS NOT NULL OR sc5.municipio IS NOT NULL THEN 'sc5010_le'
       ELSE NULL END AS endereco_source
FROM sc5
FULL OUTER JOIN castor_client_address_override o
  ON o.cliente_codigo = sc5.cliente_codigo;

CREATE OR REPLACE VIEW castor_client_metrics_v2 AS
SELECT
  d.cliente_codigo,
  d.a1_cod,
  d.a1_loja,
  d.a1_nome,
  d.a1_vend,
  v.a3_nome      AS vendedor_nome,
  v.a3_nreduz    AS vendedor_nreduz,
  addr.endereco  AS a1_end,
  addr.cep       AS a1_cep,
  addr.municipio AS a1_mun,
  addr.uf        AS a1_est,
  addr.endereco_source,
  addr.lifecycle_status,
  COALESCE(f12.faturamento_12m, 0)   AS faturamento_12m,
  COALESCE(f12.pedidos_12m, 0)       AS pedidos_12m,
  COALESCE(f12.ticket_medio_12m, 0)  AS ticket_medio_12m,
  COALESCE(fa.faturamento_alltime, 0)  AS faturamento_alltime,
  COALESCE(fa.pedidos_alltime, 0)      AS pedidos_alltime,
  COALESCE(fa.ticket_medio_alltime, 0) AS ticket_medio_alltime,
  fa.primeira_nota,
  fa.ultima_nota,
  fa.primeiro_pedido,
  fa.ultimo_pedido,
  fa.ultima_atividade,
  CASE WHEN fa.ultima_atividade IS NOT NULL
       THEN (CURRENT_DATE - fa.ultima_atividade)::INT
       ELSE NULL END AS dias_sem_atividade,
  CASE WHEN fa.ultimo_pedido IS NOT NULL
       THEN (CURRENT_DATE - fa.ultimo_pedido)::INT
       ELSE NULL END AS dias_sem_pedido,
  CASE
    WHEN addr.lifecycle_status = 'encerrado'                       THEN 'ENCERRADO'
    WHEN addr.lifecycle_status = 'nao_interessado_permanente'      THEN 'NAO_INTERESSADO'
    WHEN fa.ultima_atividade IS NULL                               THEN 'SEM_HISTORICO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '90 days')  THEN 'ATIVO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '180 days') THEN 'EM_RISCO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '365 days') THEN 'REATIVAR'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '730 days') THEN 'INATIVO'
    ELSE 'DORMENTE'
  END AS status_real,
  CASE
    WHEN COALESCE(f12.ticket_medio_12m,0) > 0 THEN
      CASE WHEN f12.ticket_medio_12m < 3000  THEN 'pequeno'
           WHEN f12.ticket_medio_12m <= 10000 THEN 'medio'
           ELSE 'grande' END
    WHEN COALESCE(fa.ticket_medio_alltime,0) > 0 THEN
      CASE WHEN fa.ticket_medio_alltime < 3000  THEN 'pequeno'
           WHEN fa.ticket_medio_alltime <= 10000 THEN 'medio'
           ELSE 'grande' END
    ELSE 'desconhecido'
  END AS porte_efetivo,
  CASE
    WHEN COALESCE(f12.ticket_medio_12m,0)     > 0 THEN 'historico_12m'
    WHEN COALESCE(fa.ticket_medio_alltime,0)  > 0 THEN 'historico_alltime'
    ELSE 'sem_dados'
  END AS porte_origem,
  LEAST(100, GREATEST(0,
    COALESCE((CURRENT_DATE - fa.ultima_atividade)::INT / 4, 0)
    + CASE WHEN COALESCE(fa.faturamento_alltime,0) > 50000 THEN 10 ELSE 0 END
  ))::INT AS urgencia_score,
  addr.contato_nome,
  addr.contato_tel,
  addr.contato_whats,
  addr.contato_email
FROM castor_clientes_derived_v2 d
LEFT JOIN castor_client_address addr ON addr.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_metrics_alltime fa  ON fa.cliente_codigo  = d.cliente_codigo
LEFT JOIN castor_client_metrics f12  ON f12.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_src_sa3010 v        ON v.a3_cod = d.a1_vend;

GRANT EXECUTE ON FUNCTION castor_parse_le(TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_parse_le_full(TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_refresh_sc5_address() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_refresh_metrics_alltime() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_geocode_lookup(TEXT,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_geocode_upsert(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT,BOOLEAN) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_user_scope(UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version)
VALUES ('008_metrics_snapshot') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP VIEW IF EXISTS castor_client_metrics_v2;
-- DROP VIEW IF EXISTS castor_client_address;
-- DROP VIEW IF EXISTS castor_clientes_derived_v2;
-- DROP FUNCTION IF EXISTS castor_user_scope(UUID);
-- DROP FUNCTION IF EXISTS castor_geocode_upsert(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT,BOOLEAN);
-- DROP FUNCTION IF EXISTS castor_geocode_lookup(TEXT,TEXT);
-- DROP FUNCTION IF EXISTS castor_refresh_metrics_alltime();
-- DROP FUNCTION IF EXISTS castor_refresh_sc5_address();
-- DROP FUNCTION IF EXISTS castor_parse_le_full(TEXT);
-- DROP FUNCTION IF EXISTS castor_parse_le(TEXT);
-- DROP TABLE IF EXISTS castor_geocode_cache;
-- DROP TABLE IF EXISTS castor_metrics_alltime;
-- COMMIT;

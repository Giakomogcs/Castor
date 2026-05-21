-- file: 010_richer_snapshot.sql
-- tier: A
-- purpose:
--   Enriquece o snapshot do painel sem SA1010:
--   * Endereço parseado do campo "L.E:" embutido em SC5010/SD2010 (colunas novas em castor_src_sc5010 + função parser).
--   * Métricas all-time (não só janela 12m) → fallback para porte/ATIVO/etc.
--   * status_real (string explícita) e urgencia_score em view nova `castor_client_metrics_v2`.
--   * Tabela `castor_geocode_cache` para lazy geocoding (Nominatim/OSM) — município e endereço.
--   * Helpers para escopo de vendedor por UF/cidade (já lidos do raw_user_meta_data).
--   * View `castor_clientes_derived_v2` corrigida — endereço/UF/município best-effort por SC5/SF2 mais recente.
--
-- depends: 001, 004, 008, 009
-- reversible: yes
-- IDEMPOTENTE.

BEGIN;

-- ============================================================
-- 1) NOVAS COLUNAS em castor_src_sc5010 (endereço parseado de L.E:)
-- ============================================================
ALTER TABLE castor_src_sc5010
  ADD COLUMN IF NOT EXISTS c5_le_raw   TEXT,
  ADD COLUMN IF NOT EXISTS c5_end      TEXT,
  ADD COLUMN IF NOT EXISTS c5_cep      TEXT,
  ADD COLUMN IF NOT EXISTS c5_mun      TEXT,
  ADD COLUMN IF NOT EXISTS c5_uf       TEXT;

CREATE INDEX IF NOT EXISTS castor_src_sc5010_uf_idx  ON castor_src_sc5010(c5_uf);
CREATE INDEX IF NOT EXISTS castor_src_sc5010_mun_idx ON castor_src_sc5010(c5_mun);

-- ============================================================
-- 2) Parser de endereço embutido no campo "L.E:" do Protheus
--    Exemplo: "L.E: AV MARCOS PAULO GONCALVES 955 CEP:07175120 GUARULHOS-SP 115"
--    Output: jsonb { endereco, cep, municipio, uf }
-- ============================================================
CREATE OR REPLACE FUNCTION castor_parse_le(p_text TEXT)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  s        TEXT;
  v_cep    TEXT;
  v_mun    TEXT;
  v_uf     TEXT;
  v_end    TEXT;
  m_cep    TEXT[];
  m_munuf  TEXT[];
BEGIN
  IF p_text IS NULL OR p_text = '' THEN RETURN NULL; END IF;
  s := regexp_replace(p_text, '^\s*L\.E:\s*', '', 'i');
  s := btrim(s);

  -- CEP: 8 dígitos (com ou sem hífen)
  m_cep := regexp_match(s, 'CEP:?\s*([0-9]{5}-?[0-9]{3})', 'i');
  IF m_cep IS NOT NULL THEN
    v_cep := regexp_replace(m_cep[1], '\D', '', 'g');
  END IF;

  -- Município-UF: ...MUNICIPIO-UF... (UF = 2 letras)
  -- pega a primeira ocorrência de "PALAVRA(S)-UF" depois do CEP (ou em qualquer lugar se sem CEP)
  m_munuf := regexp_match(s, '([A-ZÀ-Ú][A-ZÀ-Ú0-9\s\.\-/]{2,40}?)-([A-Z]{2})(?:\s|$)');
  IF m_munuf IS NOT NULL THEN
    v_mun := btrim(m_munuf[1]);
    v_uf  := upper(m_munuf[2]);
  END IF;

  -- Endereço = tudo antes de CEP: (ou antes do MUN-UF se não houver CEP)
  v_end := regexp_replace(s, '\s*CEP:?\s*[0-9]{5}-?[0-9]{3}.*$', '', 'i');
  IF v_end = s THEN
    -- sem CEP — corta antes do MUN-UF
    v_end := regexp_replace(s, '\s+[A-ZÀ-Ú][A-ZÀ-Ú0-9\s\.\-/]{2,40}?-[A-Z]{2}(\s.*)?$', '', '');
  END IF;
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

GRANT EXECUTE ON FUNCTION castor_parse_le(TEXT) TO authenticated, service_role;

-- ============================================================
-- 3) Refresh: aplica parser sobre c5_le_raw → c5_end/c5_cep/c5_mun/c5_uf
--    Chamado pelo Source-Manager após cada ingest de SC5010.
-- ============================================================
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
GRANT EXECUTE ON FUNCTION castor_refresh_sc5_address() TO authenticated, service_role;

-- ============================================================
-- 4) MÉTRICAS ALL-TIME (independente de janela 365d)
-- ============================================================
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
CREATE INDEX IF NOT EXISTS castor_metrics_alltime_fat_idx  ON castor_metrics_alltime(faturamento_alltime DESC);
CREATE INDEX IF NOT EXISTS castor_metrics_alltime_ult_idx  ON castor_metrics_alltime(ultima_atividade DESC);

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
GRANT EXECUTE ON FUNCTION castor_refresh_metrics_alltime() TO authenticated, service_role;

-- ============================================================
-- 5) ENDEREÇO MAIS RECENTE por cliente (rolled-up de SC5)
-- ============================================================
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
)
SELECT cliente_codigo, c5_end AS endereco, c5_cep AS cep, c5_mun AS municipio, c5_uf AS uf
  FROM ranked
 WHERE rn = 1;

-- ============================================================
-- 6) View `castor_clientes_derived_v2` — substitui a v1 (que incluía ZA7,
--    quebrando o filtro de leads). Agora SÓ une SF2 + SC5 (atividade real).
-- ============================================================
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

-- ============================================================
-- 7) View MASTER: `castor_client_metrics_v2`
--    Agora com status_real (string), urgencia_score (0-100), porte_origem.
--    Substitui a velha `castor_client_metrics` (que mapeava status_inferido → a1_ustatus '1'/'2'/'3').
-- ============================================================
CREATE OR REPLACE VIEW castor_client_metrics_v2 AS
SELECT
  d.cliente_codigo,
  d.a1_cod,
  d.a1_loja,
  d.a1_nome,
  d.a1_vend,
  v.a3_nome      AS vendedor_nome,
  v.a3_nreduz    AS vendedor_nreduz,
  -- endereço (derivado de SC5)
  addr.endereco  AS a1_end,
  addr.cep       AS a1_cep,
  addr.municipio AS a1_mun,
  addr.uf        AS a1_est,
  -- métricas 12m
  COALESCE(f12.faturamento_12m, 0)   AS faturamento_12m,
  COALESCE(f12.pedidos_12m, 0)       AS pedidos_12m,
  COALESCE(f12.ticket_medio_12m, 0)  AS ticket_medio_12m,
  -- métricas all-time
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
  -- status_real (string explícita, sem mapear pra a1_ustatus)
  CASE
    WHEN fa.ultima_atividade IS NULL                                         THEN 'SEM_HISTORICO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '90 days')          THEN 'ATIVO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '180 days')         THEN 'EM_RISCO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '365 days')         THEN 'REATIVAR'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '730 days')         THEN 'INATIVO'
    ELSE 'DORMENTE'
  END AS status_real,
  -- porte: prefere ticket 12m; fallback ticket all-time; senão sem_dados
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
  -- urgencia_score (0-100): combina dias sem pedido com peso de valor e frequência
  LEAST(100, GREATEST(0, ROUND(
    LEAST(100, COALESCE((CURRENT_DATE - fa.ultimo_pedido)::NUMERIC, 0) / 7.0)
    * (
        0.4
      + 0.4 * LEAST(1.0, LOG(10, GREATEST(1, COALESCE(fa.faturamento_alltime, 0) + 1)) / 6.0)
      + 0.2 * LEAST(1.0, COALESCE(fa.pedidos_alltime, 0)::NUMERIC / 12.0)
    )
  )))::INT AS urgencia_score
FROM castor_clientes_derived_v2 d
LEFT JOIN castor_metrics_sf2010    f12  ON f12.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_metrics_alltime   fa   ON fa.cliente_codigo  = d.cliente_codigo
LEFT JOIN castor_client_address    addr ON addr.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_src_sa3010        v    ON v.a3_cod = d.a1_vend;

-- ============================================================
-- 8) GEOCODE CACHE (lazy via Nominatim/OSM no workflow Castor-Geocode)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_geocode_cache (
  id            BIGSERIAL PRIMARY KEY,
  scope         TEXT NOT NULL CHECK (scope IN ('municipio','endereco')),
  query_key     TEXT NOT NULL,                -- normalized lookup key
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

-- helper: lookup ou retorno NULL (chamado pelo Panel-API/Geocode workflow)
CREATE OR REPLACE FUNCTION castor_geocode_lookup(p_scope TEXT, p_key TEXT)
RETURNS castor_geocode_cache
LANGUAGE sql STABLE AS $$
  SELECT * FROM castor_geocode_cache
   WHERE scope = p_scope AND query_key = p_key
   LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION castor_geocode_lookup(TEXT,TEXT) TO authenticated, service_role;

-- helper: upsert resultado do Nominatim
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
GRANT EXECUTE ON FUNCTION castor_geocode_upsert(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT,BOOLEAN)
  TO authenticated, service_role;

-- ============================================================
-- 9) HELPERS de escopo do vendedor (UF/cidade lidos de auth.users.raw_user_meta_data)
-- ============================================================
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
GRANT EXECUTE ON FUNCTION castor_user_scope(UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version) VALUES ('010_richer_snapshot') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

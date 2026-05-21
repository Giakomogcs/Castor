-- ============================================================
-- 018 — Roteiro IA: incluir clientes SEM geocode
-- ------------------------------------------------------------
-- Antes:
--   * `castor_route_candidates` filtrava `WHERE g.lat IS NOT NULL`,
--     então clientes sem geocode municipal não apareciam.
--   * `castor_route_build_maps_url` só usava lat/lng; paradas sem
--     coordenadas eram puladas no Maps.
--
-- Agora:
--   * `castor_route_candidates` devolve TODOS os candidatos (com ou sem
--     lat/lng). Quem não tem geocode vem com `lat = NULL, lng = NULL`
--     e o subflow Auto-Route Builder coloca essas paradas no final do
--     roteiro, sem leg_km, e usa o endereço (a1_end, a1_mun-a1_est, CEP)
--     como waypoint do Google Maps.
--   * `castor_route_build_maps_url` agora também aceita stops sem lat/lng:
--     se o stop tiver `address` (ou monta a partir de a1_end/a1_mun/a1_est),
--     usa essa string URL-encoded como waypoint do Maps.
--
-- Idempotente. Não toca tabelas.
-- ============================================================

CREATE OR REPLACE FUNCTION castor_route_build_maps_url(
  p_origin_lat DOUBLE PRECISION,
  p_origin_lng DOUBLE PRECISION,
  p_stops      JSONB
) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_url   TEXT;
  v_pts   TEXT := '';
  v_count INT := 0;
  v_elem  JSONB;
  v_lat   DOUBLE PRECISION;
  v_lng   DOUBLE PRECISION;
  v_addr  TEXT;
  v_token TEXT;
BEGIN
  IF p_origin_lat IS NULL OR p_origin_lng IS NULL OR p_stops IS NULL OR jsonb_array_length(p_stops) = 0 THEN
    RETURN NULL;
  END IF;
  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_stops) LOOP
    v_lat := NULLIF(v_elem->>'lat','')::DOUBLE PRECISION;
    v_lng := NULLIF(v_elem->>'lng','')::DOUBLE PRECISION;
    v_token := NULL;

    IF v_lat IS NOT NULL AND v_lng IS NOT NULL THEN
      v_token := v_lat::TEXT || ',' || v_lng::TEXT;
    ELSE
      -- fallback: usa endereço textual quando não há coord
      v_addr := NULLIF(btrim(COALESCE(v_elem->>'address','')),'');
      IF v_addr IS NULL THEN
        v_addr := btrim(
          COALESCE(v_elem->>'a1_end','') ||
          CASE WHEN COALESCE(v_elem->>'a1_mun','') <> '' THEN ', ' || (v_elem->>'a1_mun') ELSE '' END ||
          CASE WHEN COALESCE(v_elem->>'a1_est','') <> '' THEN ' - ' || (v_elem->>'a1_est') ELSE '' END
        );
        v_addr := NULLIF(v_addr,'');
      END IF;
      IF v_addr IS NULL THEN CONTINUE; END IF;
      -- URL-encode mínimo (espaços, vírgulas, hash, barras)
      v_token := replace(replace(replace(replace(replace(replace(
                 v_addr,
                 '%','%25'),
                 ' ','%20'),
                 ',','%2C'),
                 '/','%2F'),
                 '#','%23'),
                 '?','%3F');
    END IF;

    v_count := v_count + 1;
    IF v_count > 23 THEN EXIT; END IF; -- Maps limita waypoints
    v_pts := v_pts || '/' || v_token;
  END LOOP;
  IF v_count = 0 THEN RETURN NULL; END IF;
  v_url := 'https://www.google.com/maps/dir/' ||
           p_origin_lat::TEXT || ',' || p_origin_lng::TEXT ||
           v_pts ||
           '/' || p_origin_lat::TEXT || ',' || p_origin_lng::TEXT;
  RETURN v_url;
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_build_maps_url(DOUBLE PRECISION,DOUBLE PRECISION,JSONB) TO authenticated, service_role;

-- Inclui clientes sem geocode (LEFT JOIN sem o filtro lat/lng NOT NULL).
CREATE OR REPLACE FUNCTION castor_route_candidates(
  p_user_id   UUID,
  p_mode      TEXT,
  p_uf        TEXT,
  p_cidade    TEXT,
  p_limit     INT
)
RETURNS TABLE(
  cliente_codigo TEXT, a1_nome TEXT, a1_vend TEXT,
  a1_mun TEXT, a1_est TEXT, a1_end TEXT, a1_cep TEXT,
  status_real TEXT, urgencia_score INT,
  faturamento_alltime NUMERIC, ultimo_pedido DATE, dias_sem_pedido INT,
  porte_efetivo TEXT, lat DOUBLE PRECISION, lng DOUBLE PRECISION
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_role TEXT;
  v_vend TEXT;
  v_est  TEXT[];
  v_cid  TEXT[];
BEGIN
  SELECT s.role, s.vendor_code, s.estados, s.cidades
    INTO v_role, v_vend, v_est, v_cid
  FROM castor_user_scope(p_user_id) s;
  v_role := COALESCE(v_role,'vendedor');

  RETURN QUERY
  SELECT
    m.cliente_codigo, m.a1_nome, m.a1_vend,
    m.a1_mun, m.a1_est, m.a1_end, m.a1_cep,
    m.status_real, m.urgencia_score,
    m.faturamento_alltime, m.ultimo_pedido, m.dias_sem_pedido,
    m.porte_efetivo, g.lat, g.lng
  FROM castor_client_metrics_v2 m
  LEFT JOIN castor_geocode_cache g
    ON g.scope = 'municipio'
   AND g.query_key = upper(coalesce(m.a1_mun,'')) || '|' || upper(coalesce(m.a1_est,''))
   AND g.ok
  WHERE (v_role = 'admin' OR (
          (v_vend IS NULL OR m.a1_vend = v_vend)
          AND (v_est IS NULL OR upper(coalesce(m.a1_est,'')) = ANY(v_est))
          AND (v_cid IS NULL OR upper(coalesce(m.a1_mun,'')) = ANY(v_cid))
        ))
    AND (p_uf     IS NULL OR upper(coalesce(m.a1_est,'')) = upper(p_uf))
    AND (p_cidade IS NULL OR upper(coalesce(m.a1_mun,'')) = upper(p_cidade))
    AND CASE p_mode
          WHEN 'reactivation' THEN m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
          WHEN 'prospect_skip' THEN m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
          ELSE TRUE
        END
    AND m.pedidos_alltime >= 1
  -- ordena: primeiro os com geocode (melhor experiência de roteiro),
  -- depois os sem geocode — ambos por urgência desc / faturamento desc.
  ORDER BY (g.lat IS NULL AND g.lng IS NULL),
           m.urgencia_score DESC NULLS LAST,
           m.faturamento_alltime DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit,12), 30));
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_candidates(UUID,TEXT,TEXT,TEXT,INT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

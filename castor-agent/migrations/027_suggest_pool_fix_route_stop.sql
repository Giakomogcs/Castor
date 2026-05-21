-- file: 027_suggest_pool_fix_route_stop.sql
-- tier: A
-- purpose:
--   Corrige castor_admin_suggest_pool (migração 021) que referenciava a tabela
--   inexistente "castor_route_stop". As paradas dos roteiros salvos vivem como
--   JSONB em castor_route_saved.stops (cf. 011_routes_saved.sql). Esse bug fazia
--   a RPC quebrar com 'relation "castor_route_stop" does not exist' e o front
--   exibir "Sem sugestões para este vendedor / Falha ao buscar sugestões".
--
--   Mantém TODA a lógica de buckets/escopo (A/B/C) da 021 — só troca o cálculo
--   de v_open_codes para iterar stops via jsonb_array_elements.
--
-- depends: 011, 021
-- reversible: yes (basta reaplicar 021)
-- IDEMPOTENTE.

BEGIN;

CREATE OR REPLACE FUNCTION castor_admin_suggest_pool(
  p_caller         UUID,
  p_target_user_id UUID,
  p_exclude_codes  TEXT[] DEFAULT NULL,
  p_limit          INT    DEFAULT 30
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_vend       TEXT;
  v_est        TEXT[];
  v_cid        TEXT[];
  v_role       TEXT;
  v_open_codes TEXT[];
  v_rows       JSONB;
  v_lim        INT;
  v_scope_used TEXT;
  v_n_react INT := 0; v_n_prosp INT := 0; v_n_ativo INT := 0;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_target_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target_user_id obrigatorio');
  END IF;

  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_target_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target nao existe');
  END IF;
  IF v_role = 'inactive' THEN
    RETURN jsonb_build_object('ok',false,'error','target inativo');
  END IF;

  SELECT s.vendor_code, s.estados, s.cidades
    INTO v_vend, v_est, v_cid
  FROM castor_user_scope(p_target_user_id) s;

  -- Normaliza: trata array vazio como "sem filtro"
  IF v_est IS NOT NULL AND array_length(v_est, 1) IS NULL THEN v_est := NULL; END IF;
  IF v_cid IS NOT NULL AND array_length(v_cid, 1) IS NULL THEN v_cid := NULL; END IF;
  IF v_vend IS NOT NULL AND btrim(v_vend) = '' THEN v_vend := NULL; END IF;

  -- Códigos já em roteiros abertos do target (não sugerir de novo).
  -- FIX: ler stops JSONB de castor_route_saved (não existe tabela castor_route_stop).
  SELECT COALESCE(array_agg(DISTINCT code), ARRAY[]::TEXT[])
    INTO v_open_codes
  FROM (
    SELECT NULLIF(btrim(st->>'cliente_codigo'), '') AS code
    FROM castor_route_saved r
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.stops, '[]'::jsonb)) AS st
    WHERE r.user_id = p_target_user_id
      AND r.status IN ('planejado','em_andamento')
  ) x
  WHERE code IS NOT NULL;

  v_lim := GREATEST(5, LEAST(COALESCE(p_limit, 30), 100));

  WITH base AS (
    SELECT m.*, g.lat AS gc_lat, g.lng AS gc_lng,
      CASE
        WHEN m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
             AND m.pedidos_alltime >= 1                          THEN 'reativacao'
        WHEN m.status_real = 'SEM_HISTORICO'
             OR m.pedidos_alltime = 0                            THEN 'prospect'
        WHEN m.status_real = 'ATIVO'
             AND m.porte_efetivo IN ('medio','grande')           THEN 'ativo_bom'
        ELSE NULL
      END AS bucket
    FROM castor_client_metrics_v2 m
    LEFT JOIN castor_geocode_cache g
      ON g.scope = 'municipio'
     AND g.query_key = upper(coalesce(m.a1_mun,'')) || '|' || upper(coalesce(m.a1_est,''))
     AND g.ok
    WHERE COALESCE(m.lifecycle_status, '') NOT IN ('encerrado','nao_interessado_permanente')
      AND (p_exclude_codes IS NULL OR NOT (m.cliente_codigo = ANY(p_exclude_codes)))
      AND NOT (m.cliente_codigo = ANY(v_open_codes))
  ),
  lvl_a AS (
    SELECT * FROM base
     WHERE bucket IS NOT NULL
       AND (v_vend IS NULL OR a1_vend = v_vend)
       AND (v_est  IS NULL OR upper(coalesce(a1_est,'')) = ANY(v_est))
       AND (v_cid  IS NULL OR upper(coalesce(a1_mun,'')) = ANY(v_cid))
  ),
  lvl_b AS (
    SELECT * FROM base
     WHERE bucket IS NOT NULL
       AND (v_est IS NULL OR upper(coalesce(a1_est,'')) = ANY(v_est))
       AND (v_cid IS NULL OR upper(coalesce(a1_mun,'')) = ANY(v_cid))
  ),
  lvl_c AS (
    SELECT * FROM base WHERE bucket IS NOT NULL
  ),
  picked AS (
    SELECT *, 'A'::text AS lvl FROM lvl_a
    UNION ALL
    SELECT *, 'B'::text FROM lvl_b WHERE NOT EXISTS (SELECT 1 FROM lvl_a)
    UNION ALL
    SELECT *, 'C'::text FROM lvl_c WHERE NOT EXISTS (SELECT 1 FROM lvl_a)
                                     AND NOT EXISTS (SELECT 1 FROM lvl_b)
  )
  SELECT jsonb_agg(row_obj ORDER BY bucket_rank, urg DESC NULLS LAST, fat DESC NULLS LAST),
         MAX(lvl)
    INTO v_rows, v_scope_used
  FROM (
    SELECT
      jsonb_build_object(
        'cliente_codigo',    cliente_codigo,
        'a1_nome',           a1_nome,
        'a1_vend',           a1_vend,
        'vendedor_nome',     vendedor_nome,
        'a1_end',            a1_end,
        'a1_cep',            a1_cep,
        'a1_mun',            a1_mun,
        'a1_est',            a1_est,
        'contato_nome',      contato_nome,
        'contato_tel',       contato_tel,
        'contato_whats',     contato_whats,
        'contato_email',     contato_email,
        'status_real',       status_real,
        'urgencia_score',    urgencia_score,
        'porte_efetivo',     porte_efetivo,
        'faturamento_alltime', faturamento_alltime,
        'ultimo_pedido',     ultimo_pedido,
        'dias_sem_pedido',   dias_sem_pedido,
        'bucket',            bucket,
        'lat',               gc_lat,
        'lng',               gc_lng,
        'has_geocode',       (gc_lat IS NOT NULL AND gc_lng IS NOT NULL),
        'missing_address',   (a1_end IS NULL OR btrim(a1_end) = ''),
        'missing_contact',   (COALESCE(NULLIF(btrim(contato_tel),''),
                                       NULLIF(btrim(contato_whats),''),
                                       NULLIF(btrim(contato_email),'')) IS NULL)
      ) AS row_obj,
      CASE bucket
        WHEN 'reativacao' THEN 1
        WHEN 'ativo_bom'  THEN 2
        WHEN 'prospect'   THEN 3
        ELSE 9
      END AS bucket_rank,
      urgencia_score AS urg,
      faturamento_alltime AS fat,
      bucket, lvl
    FROM picked
  ) ranked;

  IF v_rows IS NOT NULL AND jsonb_array_length(v_rows) > v_lim THEN
    SELECT jsonb_agg(value)
      INTO v_rows
      FROM (
        SELECT value
          FROM jsonb_array_elements(v_rows) WITH ORDINALITY t(value, ord)
         ORDER BY ord
         LIMIT v_lim
      ) sub;
  END IF;

  IF v_rows IS NOT NULL THEN
    SELECT
      COUNT(*) FILTER (WHERE (value->>'bucket') = 'reativacao'),
      COUNT(*) FILTER (WHERE (value->>'bucket') = 'prospect'),
      COUNT(*) FILTER (WHERE (value->>'bucket') = 'ativo_bom')
      INTO v_n_react, v_n_prosp, v_n_ativo
    FROM jsonb_array_elements(v_rows);
  END IF;

  RETURN jsonb_build_object(
    'ok',            true,
    'target_user_id',p_target_user_id,
    'vendor_code',   v_vend,
    'scope_estados', COALESCE(to_jsonb(v_est), 'null'::jsonb),
    'scope_cidades', COALESCE(to_jsonb(v_cid), 'null'::jsonb),
    'scope_used',    COALESCE(v_scope_used, 'none'),
    'pool',          COALESCE(v_rows, '[]'::jsonb),
    'pool_size',     COALESCE(jsonb_array_length(v_rows), 0),
    'by_bucket',     jsonb_build_object(
                       'reativacao', v_n_react,
                       'prospect',   v_n_prosp,
                       'ativo_bom',  v_n_ativo
                     ),
    'open_excluded', COALESCE(array_length(v_open_codes,1), 0)
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_suggest_pool(UUID, UUID, TEXT[], INT)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('027_suggest_pool_fix_route_stop') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

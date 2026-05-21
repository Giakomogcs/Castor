-- file: 013_admin_reassign_and_client_detail.sql
-- tier: A
-- purpose:
--   * castor_admin_route_reassign(p_caller, p_route_id, p_new_user_id):
--     permite que um admin transfira a posse de um roteiro salvo entre vendedores.
--   * castor_client_detail(p_user_id, p_cliente_codigo):
--     visão agregada de um cliente para o painel — dados-mestre, métricas, último
--     feedback, histórico completo de feedbacks e roteiros onde o cliente aparece.
--     Aplica o mesmo escopo admin/vendedor das outras RPCs.
--
-- depends: 001, 002, 004, 005, 010, 011
-- reversible: yes
-- IDEMPOTENTE.

BEGIN;

-- ============================================================
-- 1) Admin: reassign de roteiro
-- ============================================================
CREATE OR REPLACE FUNCTION castor_admin_route_reassign(
  p_caller       UUID,
  p_route_id     UUID,
  p_new_user_id  UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_caller_role TEXT;
  v_new_role    TEXT;
  v_exists      BOOLEAN;
BEGIN
  IF p_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'caller obrigatorio');
  END IF;
  IF p_route_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'route_id obrigatorio');
  END IF;
  IF p_new_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'new_user_id obrigatorio');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'role', 'vendedor')
    INTO v_caller_role
    FROM auth.users u
   WHERE u.id = p_caller;

  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden: admin-only');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'role', 'vendedor')
    INTO v_new_role
    FROM auth.users u
   WHERE u.id = p_new_user_id;

  IF v_new_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'new_user_id nao existe');
  END IF;

  SELECT EXISTS(SELECT 1 FROM castor_route_saved WHERE id = p_route_id)
    INTO v_exists;
  IF NOT v_exists THEN
    RETURN jsonb_build_object('ok', false, 'error', 'route_not_found');
  END IF;

  UPDATE castor_route_saved
     SET user_id = p_new_user_id,
         updated_at = NOW()
   WHERE id = p_route_id;

  RETURN jsonb_build_object('ok', true, 'route_id', p_route_id, 'new_user_id', p_new_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION castor_admin_route_reassign(UUID, UUID, UUID) TO authenticated, service_role;

-- ============================================================
-- 2) Detalhe consolidado do cliente (painel)
-- ============================================================
CREATE OR REPLACE FUNCTION castor_client_detail(
  p_user_id        UUID,
  p_cliente_codigo TEXT
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_scope        RECORD;
  v_client       JSONB;
  v_feedbacks    JSONB;
  v_routes       JSONB;
  v_visible      BOOLEAN;
  v_a1_vend      TEXT;
  v_a1_mun       TEXT;
  v_a1_est       TEXT;
BEGIN
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cliente_codigo obrigatorio');
  END IF;

  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);

  SELECT to_jsonb(m.*), m.a1_vend, m.a1_mun, m.a1_est
    INTO v_client, v_a1_vend, v_a1_mun, v_a1_est
    FROM castor_client_metrics_v2 m
   WHERE m.cliente_codigo = p_cliente_codigo
   LIMIT 1;

  IF v_client IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cliente nao encontrado');
  END IF;

  -- Aplica visibilidade: admin vê tudo; vendedor só vê se for dele e dentro do escopo geo.
  IF v_scope.role = 'admin' THEN
    v_visible := TRUE;
  ELSE
    v_visible := (
      (v_scope.vendor_code IS NULL OR v_a1_vend = v_scope.vendor_code)
      AND (v_scope.estados IS NULL OR upper(coalesce(v_a1_est, '')) = ANY(v_scope.estados))
      AND (v_scope.cidades IS NULL OR upper(coalesce(v_a1_mun, '')) = ANY(v_scope.cidades))
    );
  END IF;

  IF NOT v_visible THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(f.*) ORDER BY f.visited_at DESC), '[]'::jsonb)
    INTO v_feedbacks
    FROM (
      SELECT id, cliente_codigo, vendedor_user_id, vendedor_codigo,
             visited_at, outcome, custom_days, next_contact_at, notes, created_at
        FROM castor_visita_feedback
       WHERE cliente_codigo = p_cliente_codigo
       ORDER BY visited_at DESC
       LIMIT 50
    ) f;

  -- Roteiros onde o cliente aparece (jsonb stops contém cliente_codigo).
  -- Admin vê todos; vendedor só vê os seus.
  SELECT COALESCE(jsonb_agg(to_jsonb(r.*) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_routes
    FROM (
      SELECT r.id, r.name, r.source, r.status, r.total_km, r.maps_url,
             r.created_at, r.updated_at, r.completed_at, r.user_id,
             (SELECT u.raw_user_meta_data->>'full_name' FROM auth.users u WHERE u.id = r.user_id) AS user_name,
             (SELECT jsonb_array_length(r.stops)) AS stops_count
        FROM castor_route_saved r
       WHERE r.stops @> jsonb_build_array(jsonb_build_object('cliente_codigo', p_cliente_codigo))
         AND (v_scope.role = 'admin' OR r.user_id = p_user_id)
       ORDER BY r.created_at DESC
       LIMIT 20
    ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'client', v_client,
    'feedbacks', v_feedbacks,
    'routes', v_routes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION castor_client_detail(UUID, TEXT) TO authenticated, service_role;

-- ============================================================
-- 3) Métricas agregadas de roteiros (para painel admin)
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_metrics(
  p_user_id    UUID,
  p_days       INT DEFAULT 30
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_result   JSONB;
BEGIN
  SELECT COALESCE(u.raw_user_meta_data->>'role','vendedor') = 'admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  WITH base AS (
    SELECT r.*
      FROM castor_route_saved r
     WHERE r.created_at >= NOW() - (COALESCE(p_days, 30) || ' days')::interval
       AND (v_is_admin OR r.user_id = p_user_id)
  ),
  stops_flat AS (
    SELECT b.id, b.user_id, b.status,
           jsonb_array_elements(b.stops) AS stop
      FROM base b
  ),
  per_user AS (
    SELECT b.user_id,
           (SELECT u.raw_user_meta_data->>'full_name' FROM auth.users u WHERE u.id = b.user_id) AS user_name,
           COUNT(*)                                      AS routes,
           SUM(b.total_km)                               AS km,
           SUM(jsonb_array_length(b.stops))              AS stops_total,
           SUM(CASE WHEN b.status = 'concluido' THEN 1 ELSE 0 END) AS concluidos
      FROM base b
     GROUP BY b.user_id
  ),
  outcomes AS (
    SELECT (stop->>'outcome')::text AS outcome, COUNT(*) AS qt
      FROM stops_flat
     WHERE stop ? 'outcome'
     GROUP BY 1
  )
  SELECT jsonb_build_object(
    'total_routes',     (SELECT COUNT(*) FROM base),
    'total_km',         (SELECT COALESCE(SUM(total_km),0) FROM base),
    'total_stops',      (SELECT COALESCE(SUM(jsonb_array_length(stops)),0) FROM base),
    'by_status',        (SELECT COALESCE(jsonb_object_agg(status, c), '{}'::jsonb) FROM (SELECT status, COUNT(*) c FROM base GROUP BY status) s),
    'by_outcome',       (SELECT COALESCE(jsonb_object_agg(outcome, qt), '{}'::jsonb) FROM outcomes),
    'by_user',          (SELECT COALESCE(jsonb_agg(to_jsonb(p.*) ORDER BY p.routes DESC), '[]'::jsonb) FROM per_user p),
    'is_admin',         v_is_admin
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_route_metrics(UUID, INT) TO authenticated, service_role;

-- ============================================================
-- 4) Atualiza castor_route_list para incluir user_id + user_name
--    (admin precisa ver quem é dono de cada rota)
-- ============================================================
DROP FUNCTION IF EXISTS castor_route_list(UUID, BOOLEAN, INT);

CREATE OR REPLACE FUNCTION castor_route_list(
  p_user_id    UUID,
  p_only_open  BOOLEAN DEFAULT FALSE,
  p_limit      INT     DEFAULT 50
)
RETURNS TABLE(
  id UUID, name TEXT, source TEXT, status TEXT,
  total_km NUMERIC, stops_count INT, done_count INT,
  ai_rationale TEXT, maps_url TEXT,
  created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, completed_at TIMESTAMPTZ,
  user_id UUID, user_name TEXT
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_is_admin BOOLEAN;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  RETURN QUERY
  SELECT r.id, r.name, r.source, r.status,
         r.total_km,
         COALESCE(jsonb_array_length(r.stops),0)::INT AS stops_count,
         (SELECT COUNT(*)::INT FROM jsonb_array_elements(r.stops) s
            WHERE (s->>'outcome') IS NOT NULL) AS done_count,
         r.ai_rationale, r.maps_url,
         r.created_at, r.updated_at, r.completed_at,
         r.user_id,
         (SELECT u.raw_user_meta_data->>'full_name' FROM auth.users u WHERE u.id = r.user_id) AS user_name
    FROM castor_route_saved r
   WHERE (v_is_admin OR r.user_id = p_user_id)
     AND (NOT p_only_open OR r.status IN ('planejado','em_andamento'))
   ORDER BY r.created_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_list(UUID,BOOLEAN,INT) TO authenticated, service_role;

-- ============================================================
-- 5) Detalhe de uma rota salva (com stops completos)
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_detail(
  p_user_id  UUID,
  p_route_id UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_row      castor_route_saved%ROWTYPE;
  v_owner    JSONB;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'route_not_found');
  END IF;

  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT to_jsonb(u.*) INTO v_owner
    FROM (SELECT id, email, raw_user_meta_data->>'full_name' AS full_name
            FROM auth.users WHERE id = v_row.user_id) u;

  RETURN jsonb_build_object(
    'ok', true,
    'route', jsonb_build_object(
      'id', v_row.id,
      'name', v_row.name,
      'source', v_row.source,
      'status', v_row.status,
      'total_km', v_row.total_km,
      'origin_lat', v_row.origin_lat,
      'origin_lng', v_row.origin_lng,
      'ai_rationale', v_row.ai_rationale,
      'maps_url', v_row.maps_url,
      'stops', v_row.stops,
      'stops_count', COALESCE(jsonb_array_length(v_row.stops), 0),
      'done_count', (SELECT COUNT(*)::INT FROM jsonb_array_elements(v_row.stops) s WHERE (s->>'outcome') IS NOT NULL),
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at,
      'completed_at', v_row.completed_at,
      'user_id', v_row.user_id,
      'owner', v_owner
    )
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_route_detail(UUID, UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version) VALUES ('013_admin_reassign_and_client_detail') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

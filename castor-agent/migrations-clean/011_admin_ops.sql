-- file: 011_admin_ops.sql
-- tier: A
-- purpose: Operações administrativas avançadas — offboard de vendedor, atribuição manual de tarefas,
--   pool de sugestões para um vendedor, card/route reassign, follow-up clear/transfer,
--   listagem de "tarefas órfãs" (interactions sem route) para vendedor e admin.
-- depends: 001, 004, 006, 007, 008, 010
-- IDEMPOTENTE.

BEGIN;

CREATE OR REPLACE FUNCTION castor_admin_vendor_offboard(
  p_caller       UUID,
  p_old_user_id  UUID,
  p_targets      UUID[],
  p_mode         TEXT,
  p_disable_old  BOOLEAN DEFAULT false
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_target UUID;
  v_i INT := 0;
  v_n INT;
  v_routes_moved INT := 0;
  v_inter_moved  INT := 0;
  v_feed_moved   INT := 0;
  r RECORD;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_old_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','old_user_id obrigatorio');
  END IF;
  IF p_old_user_id = p_caller THEN
    RETURN jsonb_build_object('ok',false,'error','nao_pode_offboard_proprio');
  END IF;
  IF p_targets IS NULL OR array_length(p_targets,1) IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','targets vazio');
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('single','round_robin') THEN
    RETURN jsonb_build_object('ok',false,'error','mode invalido');
  END IF;

  FOREACH v_target IN ARRAY p_targets LOOP
    IF v_target = p_old_user_id THEN
      RETURN jsonb_build_object('ok',false,'error','target_igual_ao_old');
    END IF;
    IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id = v_target) THEN
      RETURN jsonb_build_object('ok',false,'error','target_inexistente','user_id', v_target);
    END IF;
  END LOOP;

  v_n := array_length(p_targets, 1);

  FOR r IN
    SELECT id FROM castor_route_saved
     WHERE user_id = p_old_user_id
       AND status IN ('planejado','em_andamento')
     ORDER BY created_at
  LOOP
    IF p_mode = 'single' THEN
      v_target := p_targets[1];
    ELSE
      v_target := p_targets[(v_i % v_n) + 1];
      v_i := v_i + 1;
    END IF;
    UPDATE castor_route_saved
       SET user_id = v_target, updated_at = NOW()
     WHERE id = r.id;
    v_routes_moved := v_routes_moved + 1;
  END LOOP;

  v_i := 0;
  FOR r IN
    SELECT id FROM castor_client_interactions
     WHERE vendedor_user_id = p_old_user_id
       AND next_contact_at IS NOT NULL
       AND next_contact_at >= CURRENT_DATE
       AND (outcome IS NULL OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'))
     ORDER BY next_contact_at
  LOOP
    IF p_mode = 'single' THEN
      v_target := p_targets[1];
    ELSE
      v_target := p_targets[(v_i % v_n) + 1];
      v_i := v_i + 1;
    END IF;
    UPDATE castor_client_interactions
       SET vendedor_user_id = v_target,
           vendedor_codigo  = (SELECT codigo FROM castor_vendor_user WHERE user_id = v_target)
     WHERE id = r.id;
    v_inter_moved := v_inter_moved + 1;
  END LOOP;

  v_i := 0;
  FOR r IN
    SELECT id FROM castor_visita_feedback
     WHERE vendedor_user_id = p_old_user_id
       AND next_contact_at IS NOT NULL
       AND next_contact_at >= CURRENT_DATE
       AND (outcome IS NULL OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'))
     ORDER BY next_contact_at
  LOOP
    IF p_mode = 'single' THEN
      v_target := p_targets[1];
    ELSE
      v_target := p_targets[(v_i % v_n) + 1];
      v_i := v_i + 1;
    END IF;
    UPDATE castor_visita_feedback
       SET vendedor_user_id = v_target,
           vendedor_codigo  = (SELECT codigo FROM castor_vendor_user WHERE user_id = v_target)
     WHERE id = r.id;
    v_feed_moved := v_feed_moved + 1;
  END LOOP;

  IF p_disable_old THEN
    UPDATE auth.users
       SET raw_user_meta_data = COALESCE(raw_user_meta_data,'{}'::jsonb)
                                 || jsonb_build_object(
                                      'role','inactive',
                                      'offboarded_at', NOW(),
                                      'offboarded_by', p_caller::text
                                    ),
           updated_at = NOW()
     WHERE id = p_old_user_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'old_user_id', p_old_user_id,
    'mode', p_mode,
    'targets', to_jsonb(p_targets),
    'routes_moved', v_routes_moved,
    'interactions_moved', v_inter_moved,
    'feedbacks_moved', v_feed_moved,
    'disabled_old', p_disable_old
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_admin_task_assign(
  p_caller          UUID,
  p_target_user_id  UUID,
  p_cliente_codigo  TEXT,
  p_next_contact_at DATE,
  p_next_action     TEXT,
  p_notes           TEXT,
  p_route_id        UUID DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_codigo TEXT;
  v_row    castor_client_interactions%ROWTYPE;
  v_role   TEXT;
  v_existing castor_client_interactions%ROWTYPE;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_target_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target_user_id obrigatorio');
  END IF;
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok',false,'error','cliente_codigo obrigatorio');
  END IF;
  IF p_next_contact_at IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','next_contact_at obrigatorio');
  END IF;
  IF p_next_contact_at < CURRENT_DATE THEN
    RETURN jsonb_build_object('ok',false,'error','next_contact_at no passado');
  END IF;

  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_target_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target nao existe');
  END IF;
  IF v_role = 'inactive' THEN
    RETURN jsonb_build_object('ok',false,'error','target inativo');
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT * INTO v_existing FROM castor_client_interactions
     WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object('ok',true,'data',to_jsonb(v_existing),'idempotent',true);
    END IF;
  END IF;

  SELECT codigo INTO v_codigo FROM castor_vendor_user WHERE user_id = p_target_user_id;

  INSERT INTO castor_client_interactions(
    cliente_codigo, vendedor_user_id, vendedor_codigo, route_id,
    interaction_type, outcome, notes, next_contact_at, next_action,
    idempotency_key
  ) VALUES (
    p_cliente_codigo, p_target_user_id, v_codigo, p_route_id,
    'outro',
    NULL,
    NULLIF(btrim(COALESCE(p_notes,'') ||
                 CASE WHEN p_notes IS NULL THEN '' ELSE E'\n' END ||
                 '[Tarefa lançada pelo admin]'), ''),
    p_next_contact_at,
    NULLIF(btrim(p_next_action),''),
    NULLIF(p_idempotency_key,'')
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(v_row));
END; $$;

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

  IF v_est IS NOT NULL AND array_length(v_est, 1) IS NULL THEN v_est := NULL; END IF;
  IF v_cid IS NOT NULL AND array_length(v_cid, 1) IS NULL THEN v_cid := NULL; END IF;
  IF v_vend IS NOT NULL AND btrim(v_vend) = '' THEN v_vend := NULL; END IF;

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

CREATE OR REPLACE FUNCTION castor_admin_card_reassign(
  p_caller         UUID,
  p_route_id       UUID,
  p_cliente_codigo TEXT,
  p_new_user_id    UUID
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_src      castor_route_saved%ROWTYPE;
  v_dst      castor_route_saved%ROWTYPE;
  v_stop     JSONB;
  v_new_src  JSONB := '[]'::jsonb;
  v_elem     JSONB;
  v_role     TEXT;
  v_known    TEXT[];
  v_max_seq  INT := 0;
  v_merged   JSONB;
  v_dst_id   UUID;
  v_seq      INT := 0;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_route_id IS NULL OR p_cliente_codigo IS NULL OR p_new_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','parametros obrigatorios');
  END IF;

  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_new_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','destino_inexistente');
  END IF;
  IF v_role = 'admin' THEN
    RETURN jsonb_build_object('ok',false,'error','destino_admin_nao_permitido');
  END IF;
  IF v_role = 'inactive' THEN
    RETURN jsonb_build_object('ok',false,'error','destino_inativo');
  END IF;

  SELECT * INTO v_src FROM castor_route_saved WHERE id = p_route_id FOR UPDATE;
  IF v_src.id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;

  IF v_src.user_id = p_new_user_id THEN
    RETURN jsonb_build_object('ok',true,'noop',true,'reason','mesmo_vendedor');
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_src.stops,'[]'::jsonb)) LOOP
    IF (v_elem->>'cliente_codigo') = p_cliente_codigo AND v_stop IS NULL THEN
      v_stop := v_elem;
    ELSE
      v_seq := v_seq + 1;
      v_new_src := v_new_src || jsonb_build_array(jsonb_set(v_elem, '{seq}', to_jsonb(v_seq), TRUE));
    END IF;
  END LOOP;

  IF v_stop IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','stop_not_found_in_route');
  END IF;

  IF jsonb_array_length(v_new_src) = 0 THEN
    UPDATE castor_route_saved
       SET status = 'cancelado',
           updated_at = NOW(),
           ai_rationale = COALESCE(ai_rationale,'') ||
             E'\n---\n[023] Última parada reatribuída ao vendedor '||p_new_user_id::text||' em '||NOW()::text
     WHERE id = v_src.id;
  ELSE
    UPDATE castor_route_saved
       SET stops      = v_new_src,
           maps_url   = castor_route_build_maps_url(v_src.origin_lat, v_src.origin_lng, v_new_src),
           updated_at = NOW(),
           ai_rationale = COALESCE(ai_rationale,'') ||
             E'\n---\n[023] Parada '||p_cliente_codigo||' reatribuída ao vendedor '||p_new_user_id::text||' em '||NOW()::text
     WHERE id = v_src.id;
  END IF;

  SELECT * INTO v_dst
    FROM castor_route_saved
   WHERE user_id = p_new_user_id
     AND status IN ('planejado','em_andamento')
   ORDER BY created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF v_dst.id IS NULL THEN
    v_merged := jsonb_build_array(jsonb_set(v_stop, '{seq}', to_jsonb(1), TRUE));
    INSERT INTO castor_route_saved(
      user_id, name, source, stops, total_km,
      origin_lat, origin_lng, ai_rationale, maps_url, status
    ) VALUES (
      p_new_user_id,
      'Roteiro do dia '||to_char(NOW(),'DD/MM'),
      'mixed',
      v_merged,
      0,
      v_src.origin_lat, v_src.origin_lng,
      '[023] Parada reatribuída pelo admin a partir do roteiro '||v_src.id::text,
      castor_route_build_maps_url(v_src.origin_lat, v_src.origin_lng, v_merged),
      'planejado'
    ) RETURNING id INTO v_dst_id;
  ELSE
    SELECT COALESCE(array_agg(s->>'cliente_codigo'), ARRAY[]::TEXT[])
      INTO v_known
      FROM jsonb_array_elements(COALESCE(v_dst.stops,'[]'::jsonb)) s;

    IF p_cliente_codigo = ANY(v_known) THEN
      v_dst_id := v_dst.id;
    ELSE
      SELECT COALESCE(MAX((s->>'seq')::INT), 0)
        INTO v_max_seq
        FROM jsonb_array_elements(COALESCE(v_dst.stops,'[]'::jsonb)) s;
      v_merged := COALESCE(v_dst.stops,'[]'::jsonb) || jsonb_build_array(
        jsonb_set(v_stop, '{seq}', to_jsonb(v_max_seq + 1), TRUE)
      );
      UPDATE castor_route_saved
         SET stops      = v_merged,
             maps_url   = castor_route_build_maps_url(v_dst.origin_lat, v_dst.origin_lng, v_merged),
             updated_at = NOW(),
             ai_rationale = COALESCE(ai_rationale,'') ||
               E'\n---\n[023] Parada '||p_cliente_codigo||' adicionada via reassign do admin em '||NOW()::text,
             source     = 'mixed'
       WHERE id = v_dst.id;
      v_dst_id := v_dst.id;
    END IF;
  END IF;

  UPDATE castor_client_interactions
     SET vendedor_user_id = p_new_user_id,
         vendedor_codigo  = (SELECT codigo FROM castor_vendor_user WHERE user_id = p_new_user_id)
   WHERE cliente_codigo = p_cliente_codigo
     AND vendedor_user_id = v_src.user_id
     AND (outcome IS NULL OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'))
     AND (next_contact_at IS NULL OR next_contact_at >= CURRENT_DATE);

  RETURN jsonb_build_object(
    'ok', true,
    'source_route_id', v_src.id,
    'source_cancelled', jsonb_array_length(v_new_src) = 0,
    'dest_route_id', v_dst_id,
    'cliente_codigo', p_cliente_codigo,
    'new_user_id', p_new_user_id
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_admin_route_move(
  p_caller       UUID,
  p_route_id     UUID,
  p_new_user_id  UUID
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_src       castor_route_saved%ROWTYPE;
  v_dst       castor_route_saved%ROWTYPE;
  v_role      TEXT;
  v_known     TEXT[];
  v_max_seq   INT := 0;
  v_merged    JSONB;
  v_elem      JSONB;
  v_old_user  UUID;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_route_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','route_id obrigatorio');
  END IF;

  SELECT * INTO v_src FROM castor_route_saved WHERE id = p_route_id FOR UPDATE;
  IF v_src.id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF v_src.status NOT IN ('planejado','em_andamento') THEN
    RETURN jsonb_build_object('ok',false,'error','route_nao_aberta');
  END IF;

  v_old_user := v_src.user_id;

  IF p_new_user_id IS NULL THEN
    IF v_old_user IS NULL THEN
      RETURN jsonb_build_object('ok',true,'noop',true,'reason','ja_sem_vendedor');
    END IF;
    UPDATE castor_route_saved
       SET user_id = NULL,
           updated_at = NOW(),
           ai_rationale = COALESCE(ai_rationale,'') ||
             E'\n---\n[023] Roteiro desatribuído pelo admin em '||NOW()::text||' (era '||v_old_user::text||')'
     WHERE id = v_src.id;
    RETURN jsonb_build_object(
      'ok', true, 'mode','unassign',
      'route_id', v_src.id, 'previous_user_id', v_old_user
    );
  END IF;

  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_new_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','destino_inexistente');
  END IF;
  IF v_role = 'admin' THEN
    RETURN jsonb_build_object('ok',false,'error','destino_admin_nao_permitido');
  END IF;
  IF v_role = 'inactive' THEN
    RETURN jsonb_build_object('ok',false,'error','destino_inativo');
  END IF;
  IF v_old_user = p_new_user_id THEN
    RETURN jsonb_build_object('ok',true,'noop',true,'reason','mesmo_vendedor');
  END IF;

  SELECT * INTO v_dst
    FROM castor_route_saved
   WHERE user_id = p_new_user_id
     AND status IN ('planejado','em_andamento')
     AND id <> v_src.id
   ORDER BY created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF v_dst.id IS NULL THEN
    UPDATE castor_route_saved
       SET user_id = p_new_user_id,
           updated_at = NOW(),
           ai_rationale = COALESCE(ai_rationale,'') ||
             E'\n---\n[023] Roteiro movido pelo admin para '||p_new_user_id::text||' em '||NOW()::text
     WHERE id = v_src.id;

    IF v_old_user IS NOT NULL THEN
      UPDATE castor_client_interactions
         SET vendedor_user_id = p_new_user_id,
             vendedor_codigo  = (SELECT codigo FROM castor_vendor_user WHERE user_id = p_new_user_id)
       WHERE vendedor_user_id = v_old_user
         AND cliente_codigo IN (
              SELECT (s->>'cliente_codigo') FROM jsonb_array_elements(COALESCE(v_src.stops,'[]'::jsonb)) s
         )
         AND (outcome IS NULL OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'))
         AND (next_contact_at IS NULL OR next_contact_at >= CURRENT_DATE);
    END IF;

    RETURN jsonb_build_object(
      'ok', true, 'mode','move',
      'route_id', v_src.id, 'new_user_id', p_new_user_id,
      'previous_user_id', v_old_user, 'merged', FALSE
    );
  END IF;

  SELECT COALESCE(array_agg(s->>'cliente_codigo'), ARRAY[]::TEXT[])
    INTO v_known
    FROM jsonb_array_elements(COALESCE(v_dst.stops,'[]'::jsonb)) s;
  SELECT COALESCE(MAX((s->>'seq')::INT), 0)
    INTO v_max_seq
    FROM jsonb_array_elements(COALESCE(v_dst.stops,'[]'::jsonb)) s;

  v_merged := COALESCE(v_dst.stops,'[]'::jsonb);
  FOR v_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_src.stops,'[]'::jsonb)) LOOP
    IF (v_elem->>'cliente_codigo') IS NULL THEN CONTINUE; END IF;
    IF (v_elem->>'cliente_codigo') = ANY(v_known) THEN CONTINUE; END IF;
    v_max_seq := v_max_seq + 1;
    v_merged := v_merged || jsonb_build_array(jsonb_set(v_elem, '{seq}', to_jsonb(v_max_seq), TRUE));
    v_known := array_append(v_known, v_elem->>'cliente_codigo');
  END LOOP;

  UPDATE castor_route_saved
     SET stops      = v_merged,
         total_km   = COALESCE(v_dst.total_km,0) + COALESCE(v_src.total_km,0),
         maps_url   = castor_route_build_maps_url(
                        COALESCE(v_dst.origin_lat, v_src.origin_lat),
                        COALESCE(v_dst.origin_lng, v_src.origin_lng),
                        v_merged),
         source     = 'mixed',
         updated_at = NOW(),
         ai_rationale = COALESCE(ai_rationale,'') ||
           E'\n---\n[023] Mesclado com roteiro '||v_src.id::text||' (admin) em '||NOW()::text
   WHERE id = v_dst.id;

  UPDATE castor_route_saved
     SET status = 'cancelado',
         updated_at = NOW(),
         ai_rationale = COALESCE(ai_rationale,'') ||
           E'\n---\n[023] Conteúdo migrado para roteiro '||v_dst.id::text||' (admin) em '||NOW()::text
   WHERE id = v_src.id;

  IF v_old_user IS NOT NULL THEN
    UPDATE castor_client_interactions
       SET vendedor_user_id = p_new_user_id,
           vendedor_codigo  = (SELECT codigo FROM castor_vendor_user WHERE user_id = p_new_user_id)
     WHERE vendedor_user_id = v_old_user
       AND cliente_codigo IN (
            SELECT (s->>'cliente_codigo') FROM jsonb_array_elements(COALESCE(v_src.stops,'[]'::jsonb)) s
       )
       AND (outcome IS NULL OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'))
       AND (next_contact_at IS NULL OR next_contact_at >= CURRENT_DATE);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'mode','move',
    'route_id', v_dst.id, 'new_user_id', p_new_user_id,
    'previous_user_id', v_old_user, 'merged', TRUE,
    'cancelled_route_id', v_src.id
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_admin_followup_clear_by_user(
  p_caller         UUID,
  p_target_user_id UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_cleared INT := 0;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_target_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target_user_id obrigatorio');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_target_user_id) THEN
    RETURN jsonb_build_object('ok',false,'error','target_inexistente');
  END IF;

  UPDATE castor_client_interactions
     SET next_contact_at = NULL
   WHERE vendedor_user_id = p_target_user_id
     AND next_contact_at IS NOT NULL
     AND (outcome IS NULL
          OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'));
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',              true,
    'target_user_id',  p_target_user_id,
    'cleared',         v_cleared
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_admin_followup_transfer(
  p_caller          UUID,
  p_target_user_id  UUID,
  p_cliente_codigo  TEXT,
  p_new_user_id     UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_role        TEXT;
  v_new_codigo  TEXT;
  v_moved       INT := 0;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_target_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target_user_id obrigatorio');
  END IF;
  IF p_new_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','new_user_id obrigatorio');
  END IF;
  IF p_target_user_id = p_new_user_id THEN
    RETURN jsonb_build_object('ok',true,'noop',true,'reason','mesmo_vendedor');
  END IF;
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok',false,'error','cliente_codigo obrigatorio');
  END IF;

  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_new_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','destino_inexistente');
  END IF;
  IF v_role = 'admin' THEN
    RETURN jsonb_build_object('ok',false,'error','destino_admin_nao_permitido');
  END IF;
  IF v_role = 'inactive' THEN
    RETURN jsonb_build_object('ok',false,'error','destino_inativo');
  END IF;

  SELECT codigo INTO v_new_codigo
    FROM castor_vendor_user WHERE user_id = p_new_user_id;

  UPDATE castor_client_interactions
     SET vendedor_user_id = p_new_user_id,
         vendedor_codigo  = v_new_codigo
   WHERE vendedor_user_id = p_target_user_id
     AND cliente_codigo  = p_cliente_codigo
     AND (outcome IS NULL
          OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'));
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',                  true,
    'cliente_codigo',      p_cliente_codigo,
    'previous_user_id',    p_target_user_id,
    'new_user_id',         p_new_user_id,
    'interactions_moved',  v_moved
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_vendor_orphan_tasks(p_caller UUID)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_routes    JSONB := '[]'::jsonb;
  v_details   JSONB := '{}'::jsonb;
  v_stops     JSONB;
  v_count     INT;
  v_owner     JSONB;
  v_pseudo_id TEXT;
  v_user_name TEXT;
  v_email     TEXT;
BEGIN
  IF p_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'full_name',
                  u.raw_user_meta_data->>'name',
                  u.email),
         u.email
    INTO v_user_name, v_email
    FROM auth.users u
   WHERE u.id = p_caller;

  SELECT COALESCE(jsonb_agg(stop_obj ORDER BY stop_obj->>'next_contact_at' NULLS LAST), '[]'::jsonb),
         COUNT(*)::INT
    INTO v_stops, v_count
    FROM (
      SELECT jsonb_build_object(
               'cliente_codigo',  t.cliente_codigo,
               'name',            COALESCE(t.cliente_nome, t.cliente_codigo),
               'mun',             t.municipio,
               'uf',              t.uf,
               'a1_mun',          t.municipio,
               'a1_est',          t.uf,
               'outcome',         t.outcome,
               'interaction_type', t.interaction_type,
               'notes',           t.notes,
               'next_contact_at',
                 CASE WHEN t.next_contact_at IS NOT NULL
                      THEN to_char(t.next_contact_at, 'YYYY-MM-DD')
                      ELSE NULL END,
               'next_action',     t.next_action,
               'visited_at',      t.occurred_at,
               '_orphan_task',    true,
               '_interaction_id', t.id
             ) AS stop_obj
        FROM (
          SELECT DISTINCT ON (i2.cliente_codigo)
                 i2.id, i2.cliente_codigo, i2.outcome, i2.interaction_type,
                 i2.notes, i2.next_contact_at, i2.next_action, i2.occurred_at,
                 m.a1_nome AS cliente_nome,
                 m.a1_mun  AS municipio,
                 m.a1_est  AS uf
            FROM castor_client_interactions i2
            LEFT JOIN castor_client_metrics_v2 m ON m.cliente_codigo = i2.cliente_codigo
           WHERE i2.vendedor_user_id = p_caller
             AND i2.route_id IS NULL
           ORDER BY i2.cliente_codigo, i2.occurred_at DESC
        ) t
       WHERE t.outcome IS NULL
          OR t.outcome IN ('voltar_depois','aguardando_resposta','pedido_em_negociacao','sem_contato')
    ) sub;

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'data', jsonb_build_object('routes', '[]'::jsonb, 'details', '{}'::jsonb)
    );
  END IF;

  v_pseudo_id := 'orphan:' || p_caller::text;
  v_owner := jsonb_build_object(
    'id',        p_caller,
    'email',     v_email,
    'full_name', v_user_name
  );

  v_routes := jsonb_build_array(jsonb_build_object(
    'id',           v_pseudo_id,
    'name',         '📋 Tarefas avulsas',
    'source',       'vendor_orphan_tasks',
    'status',       'planejado',
    'total_km',     0,
    'stops_count',  v_count,
    'done_count',   0,
    'ai_rationale', NULL,
    'maps_url',     NULL,
    'created_at',   NOW(),
    'updated_at',   NOW(),
    'completed_at', NULL,
    'user_id',      p_caller,
    'user_name',    v_user_name,
    '_orphan',      true
  ));

  v_details := jsonb_build_object(v_pseudo_id, jsonb_build_object(
    'id',          v_pseudo_id,
    'name',        '📋 Tarefas avulsas',
    'status',      'planejado',
    'user_id',     p_caller,
    'owner',       v_owner,
    'stops',       v_stops,
    'stops_count', v_count,
    'done_count',  0,
    '_orphan',     true
  ));

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object('routes', v_routes, 'details', v_details)
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_admin_orphan_tasks(p_caller UUID)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_routes  JSONB := '[]'::jsonb;
  v_details JSONB := '{}'::jsonb;
  v_vendor  RECORD;
  v_stops   JSONB;
  v_count   INT;
  v_owner   JSONB;
  v_pseudo_id TEXT;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  FOR v_vendor IN
    SELECT i.vendedor_user_id AS uid,
           COALESCE(u.raw_user_meta_data->>'full_name',
                    u.raw_user_meta_data->>'name',
                    u.email) AS user_name,
           u.email AS email
      FROM castor_client_interactions i
      LEFT JOIN auth.users u ON u.id = i.vendedor_user_id
     WHERE i.route_id IS NULL
       AND i.vendedor_user_id IS NOT NULL
       AND COALESCE(u.raw_user_meta_data->>'role','vendedor') <> 'admin'
     GROUP BY i.vendedor_user_id, u.email, u.raw_user_meta_data
  LOOP
    SELECT COALESCE(jsonb_agg(stop_obj ORDER BY stop_obj->>'next_contact_at' NULLS LAST), '[]'::jsonb),
           COUNT(*)::INT
      INTO v_stops, v_count
      FROM (
        SELECT jsonb_build_object(
                 'cliente_codigo', t.cliente_codigo,
                 'name',           COALESCE(t.cliente_nome, t.cliente_codigo),
                 'mun',            t.municipio,
                 'uf',             t.uf,
                 'a1_mun',         t.municipio,
                 'a1_est',         t.uf,
                 'outcome',        t.outcome,
                 'interaction_type', t.interaction_type,
                 'notes',          t.notes,
                 'next_contact_at',
                   CASE WHEN t.next_contact_at IS NOT NULL
                        THEN to_char(t.next_contact_at,'YYYY-MM-DD')
                        ELSE NULL END,
                 'next_action',    t.next_action,
                 'visited_at',     t.occurred_at,
                 '_orphan_task',   true,
                 '_interaction_id', t.id
               ) AS stop_obj
          FROM (
            SELECT DISTINCT ON (i2.cliente_codigo)
                   i2.id, i2.cliente_codigo, i2.outcome, i2.interaction_type,
                   i2.notes, i2.next_contact_at, i2.next_action, i2.occurred_at,
                   m.a1_nome AS cliente_nome,
                   m.a1_mun  AS municipio,
                   m.a1_est  AS uf
              FROM castor_client_interactions i2
              LEFT JOIN castor_client_metrics_v2 m ON m.cliente_codigo = i2.cliente_codigo
             WHERE i2.vendedor_user_id = v_vendor.uid
               AND i2.route_id IS NULL
             ORDER BY i2.cliente_codigo, i2.occurred_at DESC
          ) t
         WHERE t.outcome IS NULL
            OR t.outcome IN ('voltar_depois','aguardando_resposta','pedido_em_negociacao','sem_contato')
      ) sub;

    IF v_count = 0 THEN CONTINUE; END IF;

    v_pseudo_id := 'orphan:' || v_vendor.uid::text;
    v_owner := jsonb_build_object(
      'id', v_vendor.uid,
      'email', v_vendor.email,
      'full_name', v_vendor.user_name
    );

    v_routes := v_routes || jsonb_build_array(jsonb_build_object(
      'id',           v_pseudo_id,
      'name',         '📋 Tarefas avulsas — ' || COALESCE(v_vendor.user_name, v_vendor.email, v_vendor.uid::text),
      'source',       'admin_orphan_tasks',
      'status',       'planejado',
      'total_km',     0,
      'stops_count',  v_count,
      'done_count',   0,
      'ai_rationale', NULL,
      'maps_url',     NULL,
      'created_at',   NOW(),
      'updated_at',   NOW(),
      'completed_at', NULL,
      'user_id',      v_vendor.uid,
      'user_name',    v_vendor.user_name,
      '_orphan',      true
    ));

    v_details := v_details || jsonb_build_object(v_pseudo_id, jsonb_build_object(
      'id',          v_pseudo_id,
      'name',        '📋 Tarefas avulsas — ' || COALESCE(v_vendor.user_name, v_vendor.email, v_vendor.uid::text),
      'status',      'planejado',
      'user_id',     v_vendor.uid,
      'owner',       v_owner,
      'stops',       v_stops,
      'stops_count', v_count,
      'done_count',  0,
      '_orphan',     true
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'routes',  v_routes,
      'details', v_details
    )
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_vendor_offboard(UUID, UUID, UUID[], TEXT, BOOLEAN) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_task_assign(UUID, UUID, TEXT, DATE, TEXT, TEXT, UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_suggest_pool(UUID, UUID, TEXT[], INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_card_reassign(UUID, UUID, TEXT, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_route_move(UUID, UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_followup_clear_by_user(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_followup_transfer(UUID, UUID, TEXT, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_vendor_orphan_tasks(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_orphan_tasks(UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version)
VALUES ('011_admin_ops') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP FUNCTION IF EXISTS castor_admin_orphan_tasks(UUID);
-- DROP FUNCTION IF EXISTS castor_vendor_orphan_tasks(UUID);
-- DROP FUNCTION IF EXISTS castor_admin_followup_transfer(UUID, UUID, TEXT, UUID);
-- DROP FUNCTION IF EXISTS castor_admin_followup_clear_by_user(UUID, UUID);
-- DROP FUNCTION IF EXISTS castor_admin_route_move(UUID, UUID, UUID);
-- DROP FUNCTION IF EXISTS castor_admin_card_reassign(UUID, UUID, TEXT, UUID);
-- DROP FUNCTION IF EXISTS castor_admin_suggest_pool(UUID, UUID, TEXT[], INT);
-- DROP FUNCTION IF EXISTS castor_admin_task_assign(UUID, UUID, TEXT, DATE, TEXT, TEXT, UUID, TEXT);
-- DROP FUNCTION IF EXISTS castor_admin_vendor_offboard(UUID, UUID, UUID[], TEXT, BOOLEAN);
-- COMMIT;

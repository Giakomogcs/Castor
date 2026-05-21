-- ============================================================
-- 023 — Admin observa e gerencia; nunca atua como vendedor.
-- ------------------------------------------------------------
-- Regras:
--   (a) Admin NÃO pode ser dono de roteiro nem responder cards.
--       `castor_route_save_unified` rejeita p_user_id de role='admin'.
--   (b) Admin pode REATRIBUIR um único card (parada) de um roteiro
--       para outro vendedor sem mover o roteiro inteiro — abre/append
--       no roteiro aberto do destino (cria se não houver) e remove a
--       parada do roteiro de origem. Se o roteiro de origem ficar
--       vazio, ele é cancelado (preserva histórico).
--
-- Depende: 011, 013, 016, 019 (castor_assert_admin), 022.
-- Idempotente. Não usa CASCADE. Não toca auth.users (exceto SELECT role).
-- ============================================================

BEGIN;

-- ============================================================
-- 1) Bloqueia admin como dono de roteiro
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_save_unified(
  p_user_id      UUID,
  p_name         TEXT,
  p_source       TEXT,
  p_stops        JSONB,
  p_total_km     NUMERIC,
  p_origin_lat   DOUBLE PRECISION,
  p_origin_lng   DOUBLE PRECISION,
  p_ai_rationale TEXT,
  p_maps_url     TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_existing castor_route_saved%ROWTYPE;
  v_id       UUID;
  v_merged   JSONB;
  v_known    TEXT[];
  v_max_seq  INT := 0;
  v_elem     JSONB;
  v_origin_lat DOUBLE PRECISION;
  v_origin_lng DOUBLE PRECISION;
  v_total_km NUMERIC;
  v_appended BOOLEAN := FALSE;
  v_count_new INT := 0;
  v_role     TEXT;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'user_id obrigatorio'; END IF;
  IF p_stops IS NULL OR jsonb_array_length(p_stops) = 0 THEN
    RAISE EXCEPTION 'stops vazio';
  END IF;

  -- (NOVO) Admin nunca é dono de roteiro — só observa/gerencia
  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_user_id;
  IF v_role = 'admin' THEN
    RAISE EXCEPTION 'admin_nao_pode_ter_roteiro: use castor_admin_task_assign / castor_admin_card_reassign'
      USING ERRCODE='42501';
  END IF;
  IF v_role = 'inactive' THEN
    RAISE EXCEPTION 'usuario_inativo' USING ERRCODE='42501';
  END IF;

  -- procura rota ABERTA do vendedor (a mais recente)
  SELECT * INTO v_existing
    FROM castor_route_saved
   WHERE user_id = p_user_id
     AND status IN ('planejado','em_andamento')
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_existing.id IS NULL THEN
    INSERT INTO castor_route_saved(
      user_id, name, source, stops, total_km,
      origin_lat, origin_lng, ai_rationale, maps_url
    )
    VALUES (
      p_user_id,
      COALESCE(NULLIF(btrim(p_name),''), 'Roteiro do dia '||to_char(NOW(),'DD/MM')),
      COALESCE(p_source,'manual'),
      COALESCE(p_stops,'[]'::jsonb),
      p_total_km,
      p_origin_lat, p_origin_lng, p_ai_rationale, p_maps_url
    )
    RETURNING id INTO v_id;
    RETURN jsonb_build_object(
      'route_id', v_id,
      'appended', FALSE,
      'added_count', jsonb_array_length(COALESCE(p_stops,'[]'::jsonb))
    );
  END IF;

  v_appended := TRUE;
  v_id := v_existing.id;

  SELECT COALESCE(array_agg(s->>'cliente_codigo'), ARRAY[]::TEXT[])
    INTO v_known
    FROM jsonb_array_elements(COALESCE(v_existing.stops,'[]'::jsonb)) s;

  SELECT COALESCE(MAX((s->>'seq')::INT), 0)
    INTO v_max_seq
    FROM jsonb_array_elements(COALESCE(v_existing.stops,'[]'::jsonb)) s;

  v_merged := COALESCE(v_existing.stops,'[]'::jsonb);

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_stops) LOOP
    IF (v_elem->>'cliente_codigo') IS NULL THEN CONTINUE; END IF;
    IF (v_elem->>'cliente_codigo') = ANY(v_known) THEN CONTINUE; END IF;
    v_max_seq := v_max_seq + 1;
    v_count_new := v_count_new + 1;
    v_merged := v_merged || jsonb_build_array(
      jsonb_set(v_elem, '{seq}', to_jsonb(v_max_seq), TRUE)
    );
    v_known := array_append(v_known, v_elem->>'cliente_codigo');
  END LOOP;

  v_origin_lat := COALESCE(v_existing.origin_lat, p_origin_lat);
  v_origin_lng := COALESCE(v_existing.origin_lng, p_origin_lng);
  v_total_km   := COALESCE(v_existing.total_km,0) + COALESCE(p_total_km,0);

  UPDATE castor_route_saved
     SET stops      = v_merged,
         total_km   = v_total_km,
         origin_lat = v_origin_lat,
         origin_lng = v_origin_lng,
         maps_url   = castor_route_build_maps_url(v_origin_lat, v_origin_lng, v_merged),
         ai_rationale = CASE
            WHEN p_ai_rationale IS NULL OR btrim(p_ai_rationale) = '' THEN v_existing.ai_rationale
            WHEN v_existing.ai_rationale IS NULL THEN p_ai_rationale
            ELSE v_existing.ai_rationale || E'\n---\n' || p_ai_rationale
         END,
         source     = CASE
            WHEN v_existing.source = COALESCE(p_source,'manual') THEN v_existing.source
            ELSE 'mixed'
         END,
         status     = CASE WHEN v_existing.status = 'concluido' THEN 'planejado' ELSE v_existing.status END,
         updated_at = NOW()
   WHERE id = v_existing.id;

  RETURN jsonb_build_object(
    'route_id', v_id,
    'appended', TRUE,
    'added_count', v_count_new,
    'total_stops', jsonb_array_length(v_merged)
  );
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_save_unified(UUID,TEXT,TEXT,JSONB,NUMERIC,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT) TO authenticated, service_role;


-- ============================================================
-- 2) Admin: reatribui UMA parada (não o roteiro inteiro)
-- ------------------------------------------------------------
-- Remove a parada do roteiro origem; se o destino tem roteiro aberto,
-- faz append (com dedupe por cliente_codigo); senão cria novo roteiro
-- aberto para o destino contendo só essa parada.
-- ============================================================
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
  v_renum    JSONB := '[]'::jsonb;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_route_id IS NULL OR p_cliente_codigo IS NULL OR p_new_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','parametros obrigatorios');
  END IF;

  -- valida destino
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

  -- pega o roteiro de origem
  SELECT * INTO v_src FROM castor_route_saved WHERE id = p_route_id FOR UPDATE;
  IF v_src.id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;

  -- ninguém-pra-ninguém é no-op
  IF v_src.user_id = p_new_user_id THEN
    RETURN jsonb_build_object('ok',true,'noop',true,'reason','mesmo_vendedor');
  END IF;

  -- localiza a parada e separa do restante
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

  -- atualiza ou cancela o roteiro de origem
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

  -- procura roteiro aberto do destino
  SELECT * INTO v_dst
    FROM castor_route_saved
   WHERE user_id = p_new_user_id
     AND status IN ('planejado','em_andamento')
   ORDER BY created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF v_dst.id IS NULL THEN
    -- cria roteiro novo para o destino (1 parada)
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
    -- dedupe e append
    SELECT COALESCE(array_agg(s->>'cliente_codigo'), ARRAY[]::TEXT[])
      INTO v_known
      FROM jsonb_array_elements(COALESCE(v_dst.stops,'[]'::jsonb)) s;

    IF p_cliente_codigo = ANY(v_known) THEN
      -- destino já tinha esse cliente → considera ok sem duplicar
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
             source     = CASE WHEN v_dst.source = 'mixed' THEN 'mixed' ELSE 'mixed' END
       WHERE id = v_dst.id;
      v_dst_id := v_dst.id;
    END IF;
  END IF;

  -- replica também o vendedor responsável nas interações abertas desse cliente
  -- (não muda histórico passado — só pendências/próximos contatos)
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

GRANT EXECUTE ON FUNCTION castor_admin_card_reassign(UUID, UUID, TEXT, UUID)
  TO authenticated, service_role;


-- ============================================================
-- 3) Admin: mover OU desatribuir o ROTEIRO INTEIRO
-- ------------------------------------------------------------
-- Se p_new_user_id é NULL → "desatribuir": user_id = NULL, status segue
--   aberto (planejado/em_andamento) para o admin distribuir card-a-card.
-- Se p_new_user_id é um vendedor:
--   - Se o destino NÃO tem rota aberta → simplesmente troca o user_id.
--   - Se o destino JÁ tem rota aberta → MESCLA: faz append (dedupe) na rota
--     aberta do destino e cancela a rota de origem. Respeita o índice
--     único parcial (1 rota aberta por vendedor) criado em 022.
-- Interações futuras desse cliente×vendedor antigo seguem o novo dono.
-- ============================================================
CREATE OR REPLACE FUNCTION castor_admin_route_move(
  p_caller       UUID,
  p_route_id     UUID,
  p_new_user_id  UUID   -- NULL = desatribuir
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

  -- Caso 1: DESATRIBUIR
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

  -- Caso 2: MOVER para vendedor
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
    -- destino sem rota aberta → troca direta (respeita índice único)
    UPDATE castor_route_saved
       SET user_id = p_new_user_id,
           updated_at = NOW(),
           ai_rationale = COALESCE(ai_rationale,'') ||
             E'\n---\n[023] Roteiro movido pelo admin para '||p_new_user_id::text||' em '||NOW()::text
     WHERE id = v_src.id;

    -- transfere pendências (interações futuras) do vendedor antigo
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

  -- destino já tem rota aberta → MESCLAR no destino e cancelar origem
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

GRANT EXECUTE ON FUNCTION castor_admin_route_move(UUID, UUID, UUID)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('023_admin_card_reassign_and_blocks') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

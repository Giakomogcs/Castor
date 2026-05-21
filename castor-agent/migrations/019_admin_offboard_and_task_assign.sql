-- file: 019_admin_offboard_and_task_assign.sql
-- tier: A
-- purpose:
--   * castor_admin_vendor_offboard(caller, old_user_id, targets, mode, disable_old):
--       Transfere todas as tasks ABERTAS de um vendedor que sai da empresa
--       para um ou mais vendedores que ficam, sem perder histórico.
--       O que conta como "task aberta":
--         - castor_route_saved com status IN ('planejado','em_andamento')
--         - castor_client_interactions com next_contact_at >= CURRENT_DATE
--           e outcome NÃO terminal (i.e. ainda esperando ação)
--         - castor_visita_feedback com next_contact_at >= CURRENT_DATE
--       Históricos passados (occurred_at < hoje) NÃO mudam de dono — preserva
--       a verdade do que cada vendedor fez. Apenas as pendências futuras viram
--       responsabilidade do novo dono.
--       Modos:
--         - 'single'           : todas as tasks vão para targets[0]
--         - 'round_robin'      : distribui em rodízio entre targets
--       Quando disable_old=true: marca o vendedor antigo como inativo
--       (raw_user_meta_data->>'role' = 'inactive') — admin pode chamar
--       castor_admin_delete_user em seguida sem deixar tasks órfãs.
--
--   * castor_admin_task_assign(caller, target_user_id, cliente_codigo,
--                              next_contact_at, next_action, notes):
--       Admin lança uma tarefa para um vendedor específico. Por baixo, cria
--       uma castor_client_interactions com outcome NULL (= "a fazer") e
--       next_contact_at = data planejada. Aparece no kanban do vendedor.
--
-- depends: 001, 002, 004, 005, 011, 013, 015
-- reversible: yes (DROP FUNCTION nas duas)
-- IDEMPOTENTE.

BEGIN;

-- ============================================================
-- Helper: checa role do caller (mesma lógica das outras RPCs)
-- ============================================================
CREATE OR REPLACE FUNCTION castor_assert_admin(p_caller UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_role TEXT;
BEGIN
  IF p_caller IS NULL THEN
    RAISE EXCEPTION 'caller obrigatorio' USING ERRCODE='22023';
  END IF;
  SELECT COALESCE(u.raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users u WHERE u.id = p_caller;
  IF v_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'forbidden: admin-only' USING ERRCODE='42501';
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION castor_assert_admin(UUID) TO authenticated, service_role;


-- ============================================================
-- 1) Vendor offboard — transfere tasks abertas em massa
-- ============================================================
CREATE OR REPLACE FUNCTION castor_admin_vendor_offboard(
  p_caller       UUID,
  p_old_user_id  UUID,
  p_targets      UUID[],         -- lista de vendedores que assumem
  p_mode         TEXT,           -- 'single' | 'round_robin'
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

  -- Valida que cada target existe e não é o próprio old
  FOREACH v_target IN ARRAY p_targets LOOP
    IF v_target = p_old_user_id THEN
      RETURN jsonb_build_object('ok',false,'error','target_igual_ao_old');
    END IF;
    IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id = v_target) THEN
      RETURN jsonb_build_object('ok',false,'error','target_inexistente','user_id', v_target);
    END IF;
  END LOOP;

  v_n := array_length(p_targets, 1);

  -- 1a) Roteiros abertos
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

  -- 1b) Interações futuras (pendências reais)
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

  -- 1c) Feedbacks futuros (compatibilidade com snapshot)
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

  -- 1d) Desativa o vendedor antigo se solicitado (não exclui — admin decide depois)
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

GRANT EXECUTE ON FUNCTION castor_admin_vendor_offboard(UUID, UUID, UUID[], TEXT, BOOLEAN)
  TO authenticated, service_role;


-- ============================================================
-- 2) Admin: lançar tarefa avulsa para um vendedor
-- ============================================================
-- Cria uma castor_client_interactions com outcome=NULL ("a fazer") e
-- next_contact_at = data planejada. O kanban do vendedor classifica isso
-- como "A fazer" na coluna correspondente (ver KAN_COLS no front).
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

  -- Idempotência: se já houver um lançamento com a mesma key, retorna o existente
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
    'outro',                                          -- placeholder; a interação real virá quando o vendedor agir
    NULL,                                             -- outcome NULL = "a fazer"
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

GRANT EXECUTE ON FUNCTION castor_admin_task_assign(UUID, UUID, TEXT, DATE, TEXT, TEXT, UUID, TEXT)
  TO authenticated, service_role;


COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('019_admin_offboard_and_task_assign') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

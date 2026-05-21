-- 026_admin_followup_admin_actions.sql
-- ============================================================
-- Objetivo
--   Admin não tinha como mexer em follow-ups órfãos: cards no
--   sidebar "Próximos contatos" que não pertencem a nenhum roteiro
--   (ficaram pra trás, vendedor saiu, roteiro foi apagado, etc.).
--
--   Adiciona duas RPCs admin-only:
--
--   1) castor_admin_followup_clear_by_user(caller, target_user_id)
--      Zera next_contact_at de TODAS as pendências futuras (>= hoje)
--      do vendedor target, com outcome não-terminal. Histórico
--      (occurred_at, outcome, notes) preservado. É o "reset de
--      agenda do vendedor".
--
--   2) castor_admin_followup_transfer(caller, target_user_id,
--                                      cliente_codigo, new_user_id)
--      Transfere o follow-up daquele cliente do vendedor X para o Y.
--      Mesma regra do reassign de roteiro (castor_admin_route_move):
--      só atualiza interações com outcome não-terminal e
--      next_contact_at >= hoje. Atualiza vendedor_codigo via
--      castor_vendor_user.
--
--   IDEMPOTENTE.
-- ============================================================

BEGIN;

-- ============================================================
-- 1) Reset de agenda do vendedor
-- ============================================================
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
     -- Limpa TUDO que ainda está pendente, incluindo atrasados
     -- (next_contact_at < hoje). Atrasado é o caso mais comum
     -- de "limpar agenda" — não fazia sentido deixar de fora.
     AND (outcome IS NULL
          OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'));
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',              true,
    'target_user_id',  p_target_user_id,
    'cleared',         v_cleared
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_followup_clear_by_user(UUID, UUID)
  TO authenticated, service_role;


-- ============================================================
-- 2) Transferir follow-up de um cliente para outro vendedor
-- ============================================================
CREATE OR REPLACE FUNCTION castor_admin_followup_transfer(
  p_caller          UUID,
  p_target_user_id  UUID,    -- dono atual do follow-up
  p_cliente_codigo  TEXT,
  p_new_user_id     UUID     -- novo dono
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
  -- Sem filtro por next_contact_at: queremos transferir tudo que ainda
  -- está pendente daquele cliente, incluindo follow-ups atrasados.
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',                  true,
    'cliente_codigo',      p_cliente_codigo,
    'previous_user_id',    p_target_user_id,
    'new_user_id',         p_new_user_id,
    'interactions_moved',  v_moved
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_followup_transfer(UUID, UUID, TEXT, UUID)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('026_admin_followup_admin_actions')
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

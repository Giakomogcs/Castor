-- file: 014_route_edit_delete.sql
-- tier: A
-- purpose:
--   * castor_route_stop_remove(p_user_id, p_route_id, p_cliente_codigo):
--     remove uma parada do JSONB stops do roteiro, recalcula stops_count e status.
--   * castor_route_delete(p_user_id, p_route_id):
--     apaga o roteiro inteiro. Vendedor só apaga o próprio; admin apaga qualquer.
-- depends_on: 011_routes_saved.sql, 013_admin_reassign_and_client_detail.sql
-- safe_to_rerun: yes (CREATE OR REPLACE)

-- ============================================================
-- 1) Remover parada do roteiro
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_stop_remove(
  p_user_id        UUID,
  p_route_id       UUID,
  p_cliente_codigo TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row      castor_route_saved%ROWTYPE;
  v_new      JSONB := '[]'::JSONB;
  v_elem     JSONB;
  v_open     INT := 0;
  v_done     INT := 0;
  v_total    INT := 0;
  v_is_admin BOOLEAN;
  v_removed  BOOLEAN := false;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok',false,'error','forbidden');
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_row.stops) LOOP
    IF (v_elem->>'cliente_codigo') = p_cliente_codigo THEN
      v_removed := true;
      CONTINUE; -- pula essa parada
    END IF;
    v_total := v_total + 1;
    IF (v_elem->>'outcome') IS NOT NULL THEN v_done := v_done + 1; END IF;
    v_new := v_new || jsonb_build_array(v_elem);
  END LOOP;

  IF NOT v_removed THEN
    RETURN jsonb_build_object('ok',false,'error','stop_not_found');
  END IF;

  v_open := v_total - v_done;

  UPDATE castor_route_saved SET
    stops  = v_new,
    status = CASE
               WHEN v_total = 0         THEN 'cancelado'
               WHEN v_done  = 0         THEN 'planejado'
               WHEN v_open  = 0         THEN 'concluido'
               ELSE 'em_andamento'
             END,
    completed_at = CASE WHEN v_total > 0 AND v_open = 0 THEN NOW() ELSE NULL END
   WHERE id = p_route_id;

  RETURN jsonb_build_object('ok',true,'route_id',p_route_id,'total',v_total,'done',v_done);
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_stop_remove(UUID,UUID,TEXT) TO authenticated, service_role;

-- ============================================================
-- 2) Apagar roteiro inteiro
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_delete(
  p_user_id  UUID,
  p_route_id UUID
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row      castor_route_saved%ROWTYPE;
  v_is_admin BOOLEAN;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok',false,'error','forbidden');
  END IF;

  DELETE FROM castor_route_saved WHERE id = p_route_id;
  RETURN jsonb_build_object('ok',true,'route_id',p_route_id);
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_delete(UUID,UUID) TO authenticated, service_role;

-- ============================================================
-- migration bookkeeping
-- ============================================================
INSERT INTO castor_schema_migrations(version)
VALUES ('014_route_edit_delete')
ON CONFLICT (version) DO NOTHING;

NOTIFY pgrst, 'reload schema';

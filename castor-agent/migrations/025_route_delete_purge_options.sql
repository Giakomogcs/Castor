-- 025_route_delete_purge_options.sql
-- ============================================================
-- Objetivo
--   Estende castor_route_delete com flags explícitas. O DEFAULT mudou
--   em relação à v014: agora apagar um roteiro TAMBÉM zera os próximos
--   contatos pendentes daquele vendedor para os clientes que estavam
--   no roteiro. Sem isso, follow-ups ficavam órfãos (apareciam no
--   sidebar "Próximos contatos" do vendedor sem roteiro nenhum onde
--   "cair" — a fila de kanban só existe dentro de um roteiro).
--
--   Modos suportados:
--     * route_only      → apaga apenas castor_route_saved.
--                         Histórico + próximos contatos preservados.
--                         Caso raro: você quer regenerar o roteiro
--                         com os mesmos clientes mantendo a agenda.
--     * route_followups → apaga roteiro + zera next_contact_at das
--                         interações pendentes (>= hoje, outcome
--                         não-terminal) do dono do roteiro nesses
--                         clientes. **DEFAULT.** Histórico/timeline
--                         (occurred_at, outcome, notes) preservados.
--     * route_history   → apaga roteiro + DELETE de TODAS as interações
--                         daquele vendedor com aqueles clientes.
--                         Destrutivo; não dá pra desfazer.
--
--   Reassign (castor_admin_route_move) NÃO usa esta função — ele já
--   transfere as pendências para o novo vendedor (ver migration 023).
--
--   IDEMPOTENTE. Mantém a assinatura antiga (2 args) chamando a nova
--   com mode='route_followups' (default novo).
-- ============================================================

BEGIN;

-- ============================================================
-- 1) Versão nova com 3 args (UUID, UUID, TEXT mode)
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_delete(
  p_user_id   UUID,
  p_route_id  UUID,
  p_mode      TEXT      -- 'route_only' | 'route_followups' | 'route_history'
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row              castor_route_saved%ROWTYPE;
  v_is_admin         BOOLEAN;
  v_codes            TEXT[];
  v_followups_zeroed INT := 0;
  v_history_deleted  INT := 0;
  v_mode             TEXT := COALESCE(NULLIF(btrim(p_mode),''),'route_followups');
BEGIN
  IF v_mode NOT IN ('route_only','route_followups','route_history') THEN
    RETURN jsonb_build_object('ok',false,'error','mode_invalido');
  END IF;

  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok',false,'error','forbidden');
  END IF;

  -- Extrai os códigos de cliente do JSONB stops do roteiro.
  SELECT COALESCE(array_agg(DISTINCT s->>'cliente_codigo'), '{}')
    INTO v_codes
    FROM jsonb_array_elements(COALESCE(v_row.stops,'[]'::jsonb)) s
   WHERE s->>'cliente_codigo' IS NOT NULL
     AND btrim(s->>'cliente_codigo') <> '';

  -- route_history: apaga TODAS as interações do dono p/ esses clientes.
  -- (Implícito: zera follow-ups, já que a linha some.)
  IF v_mode = 'route_history' AND array_length(v_codes,1) IS NOT NULL THEN
    DELETE FROM castor_client_interactions
     WHERE vendedor_user_id = v_row.user_id
       AND cliente_codigo  = ANY(v_codes);
    GET DIAGNOSTICS v_history_deleted = ROW_COUNT;

  -- route_followups (DEFAULT): zera só o agendamento futuro, mantém timeline.
  ELSIF v_mode = 'route_followups' AND array_length(v_codes,1) IS NOT NULL THEN
    UPDATE castor_client_interactions
       SET next_contact_at = NULL
     WHERE vendedor_user_id = v_row.user_id
       AND cliente_codigo  = ANY(v_codes)
       AND next_contact_at IS NOT NULL
       AND next_contact_at >= CURRENT_DATE
       AND (outcome IS NULL
            OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'));
    GET DIAGNOSTICS v_followups_zeroed = ROW_COUNT;

  -- route_only: nada a fazer aqui.
  END IF;

  DELETE FROM castor_route_saved WHERE id = p_route_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'mode',              v_mode,
    'route_id',          p_route_id,
    'clients_in_route',  COALESCE(array_length(v_codes,1),0),
    'followups_zeroed',  v_followups_zeroed,
    'history_deleted',   v_history_deleted
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_route_delete(UUID,UUID,TEXT)
  TO authenticated, service_role;

-- ============================================================
-- 2) Compat: assinatura antiga (2 args) → mode='route_followups'
--    Qualquer caller legado que ainda chame só com (user, route)
--    passa a limpar follow-ups por default — alinhado com o
--    novo comportamento esperado.
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_delete(
  p_user_id  UUID,
  p_route_id UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
  RETURN castor_route_delete(p_user_id, p_route_id, 'route_followups');
END; $$;

GRANT EXECUTE ON FUNCTION castor_route_delete(UUID,UUID)
  TO authenticated, service_role;

-- ============================================================
-- 3) Cleanup: se uma versão BOOLEAN/BOOLEAN existir de tentativa
--    intermediária, derruba (idempotente).
-- ============================================================
DROP FUNCTION IF EXISTS castor_route_delete(UUID,UUID,BOOLEAN,BOOLEAN);

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('025_route_delete_purge_options')
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

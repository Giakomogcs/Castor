-- file: 030_admin_orphan_tasks.sql
-- tier: A
-- purpose:
--   No painel "Gestão de Roteiros" o admin via apenas castor_route_saved.
--   As tarefas avulsas que ele atribui via "Sugestões IA → enviar para
--   vendedor" caem em castor_client_interactions com route_id NULL
--   (outcome=NULL = "a fazer"). Elas apareciam só na sidebar de follow-ups.
--
--   Esta migração cria castor_admin_orphan_tasks(caller) que retorna esses
--   itens agrupados em PSEUDO-ROTAS por vendedor, no formato que
--   castor_route_list / castor_route_detail produzem. O front faz merge
--   para que o kanban admin mostre os cards "A fazer/Hoje/Atrasado/etc."
--   de cada vendedor mesmo quando não há um castor_route_saved real.
--
--   IDs sintéticos: 'orphan:<vendor_user_id>' para permitir o front
--   diferenciar e bloquear ações de edição de rota (são tasks soltas).
--
-- depends: 015 (interactions), 011/027/029 (route helpers), 002 (auth)
-- reversible: yes (DROP FUNCTION)
-- IDEMPOTENTE.

BEGIN;

DROP FUNCTION IF EXISTS castor_admin_orphan_tasks(UUID);

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

  -- Loop por vendedor com tasks órfãs (route_id NULL) e em aberto.
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
       -- abertos: outcome NULL ou não-terminal, com agendamento no futuro
       -- ou sem agendamento (a fazer).
       AND (i.outcome IS NULL
            OR i.outcome IN ('voltar_depois','aguardando_resposta','pedido_em_negociacao'))
     GROUP BY i.vendedor_user_id, u.email, u.raw_user_meta_data
  LOOP
    -- Para cada vendedor, pega a interaction mais recente por cliente
    -- (DISTINCT ON cliente_codigo) e monta um stop sintético.
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
               AND (i2.outcome IS NULL
                    OR i2.outcome IN ('voltar_depois','aguardando_resposta','pedido_em_negociacao'))
             ORDER BY i2.cliente_codigo, i2.occurred_at DESC
          ) t
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

GRANT EXECUTE ON FUNCTION castor_admin_orphan_tasks(UUID) TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('030_admin_orphan_tasks') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

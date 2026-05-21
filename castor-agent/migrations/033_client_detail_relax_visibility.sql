-- file: 033_client_detail_relax_visibility.sql
-- tier: A
-- purpose:
--   Bug: ao clicar em "ℹ Detalhes" de um card no kanban (ou em um item da
--   sidebar de follow-ups) o front mostra "Erro ao carregar detalhes:
--   forbidden". Acontece quando o cliente NÃO casa com o escopo geo do
--   vendedor OU não está atribuído ao a1_vend dele em protheus — caso
--   típico de tarefas avulsas que o admin redirecionou via
--   "Sugestões IA → enviar para vendedor" e tarefas reassinadas.
--
--   A 013 derivava `v_visible` apenas de castor_user_scope (a1_vend +
--   estados + cidades). Mas se o vendedor:
--     • tem uma castor_client_interaction com aquele cliente, OU
--     • aparece como dono de uma castor_route_saved que contém o
--       cliente, OU
--     • é o vendedor atribuído em castor_client_status_override,
--   então ele LEGITIMAMENTE precisa abrir o detalhe (responder o card,
--   ver histórico do cliente, etc.).
--
-- Fix:
--   Mantém a regra original como caminho rápido e ADICIONA fallbacks
--   por interação / rota salva / override. Admin segue vendo tudo.
--
-- depends: 013 (castor_client_detail), 015 (castor_client_interactions),
--          011 (castor_route_saved)
-- reversible: yes (re-aplique 013 para reverter o filtro original)
-- IDEMPOTENTE.

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
  v_has_link     BOOLEAN;
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

  -- Visibilidade
  IF v_scope.role = 'admin' THEN
    v_visible := TRUE;
  ELSE
    v_visible := (
      (v_scope.vendor_code IS NULL OR v_a1_vend = v_scope.vendor_code)
      AND (v_scope.estados IS NULL OR upper(coalesce(v_a1_est, '')) = ANY(v_scope.estados))
      AND (v_scope.cidades IS NULL OR upper(coalesce(v_a1_mun, '')) = ANY(v_scope.cidades))
    );

    -- Fallback: vendedor pode abrir o detalhe quando há vínculo explícito
    -- com o cliente — interação registrada, rota salva, ou override de
    -- status atribuído a ele. Isso destrava tarefas avulsas (admin →
    -- vendedor) e reassigns que cruzam a1_vend / escopo geo.
    IF NOT v_visible THEN
      SELECT EXISTS (
               SELECT 1 FROM castor_client_interactions i
                WHERE i.cliente_codigo = p_cliente_codigo
                  AND i.vendedor_user_id = p_user_id
             )
          OR EXISTS (
               SELECT 1 FROM castor_route_saved r
                WHERE r.user_id = p_user_id
                  AND r.stops @> jsonb_build_array(jsonb_build_object('cliente_codigo', p_cliente_codigo))
             )
          OR EXISTS (
               SELECT 1 FROM castor_visita_feedback f
                WHERE f.cliente_codigo = p_cliente_codigo
                  AND f.vendedor_user_id = p_user_id
             )
        INTO v_has_link;

      -- Override de status (se a tabela existir nesta instalação)
      IF NOT v_has_link THEN
        BEGIN
          EXECUTE 'SELECT EXISTS (SELECT 1 FROM castor_client_status_override o '
               || 'WHERE o.cliente_codigo = $1 AND o.assigned_user_id = $2)'
            INTO v_has_link
            USING p_cliente_codigo, p_user_id;
        EXCEPTION
          WHEN undefined_table THEN v_has_link := FALSE;
          WHEN undefined_column THEN v_has_link := FALSE;
        END;
      END IF;

      IF v_has_link THEN
        v_visible := TRUE;
      END IF;
    END IF;
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

INSERT INTO castor_schema_migrations(version)
VALUES ('033_client_detail_relax_visibility') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

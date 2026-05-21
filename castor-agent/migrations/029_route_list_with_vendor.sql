-- file: 029_route_list_with_vendor.sql
-- tier: A
-- purpose:
--   Adiciona user_id e user_name ao retorno de castor_route_list para que o
--   admin consiga, no painel "Gestão de Roteiros", filtrar e visualizar o
--   kanban por vendedor. Antes da migração o front recebia r0.user_id = NULL
--   e o filtro "Vendedor: todos" não funcionava (todos os cards apareciam
--   como "⚠️ Sem vendedor").
--
--   IMPORTANTE: a assinatura volta no ROW (RETURNS TABLE) muda — adicionamos
--   2 colunas no fim. n8n e front leem por nome de campo (não por posição),
--   então é compatível com chamadores existentes.
--
-- depends: 011, 027
-- reversible: yes (DROP FUNCTION + reaplicar 011)
-- IDEMPOTENTE.

BEGIN;

-- Antes de redefinir, dropa a versão antiga (RETURNS TABLE não permite REPLACE
-- com mudança de colunas).
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
         COALESCE(
           u.raw_user_meta_data->>'full_name',
           u.raw_user_meta_data->>'name',
           u.email,
           NULL
         ) AS user_name
    FROM castor_route_saved r
    LEFT JOIN auth.users u ON u.id = r.user_id
   WHERE (v_is_admin OR r.user_id = p_user_id)
     AND (NOT p_only_open OR r.status IN ('planejado','em_andamento'))
   ORDER BY r.created_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
END; $$;

GRANT EXECUTE ON FUNCTION castor_route_list(UUID,BOOLEAN,INT) TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('029_route_list_with_vendor') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- file: 020_admin_suggest_pool.sql
-- tier: A
-- purpose:
--   * castor_admin_suggest_pool(caller, target_user_id, exclude_codes, p_limit):
--       Lista um POOL (até p_limit, default 30) de clientes candidatos a serem
--       sugeridos ao vendedor `target_user_id`. Diferente de castor_route_candidates:
--         - NÃO exige geocode (LEFT JOIN; devolve has_geocode boolean).
--         - Inclui contato (telefone/whats/email) e flag missing_address/missing_contact
--           para o front orientar o admin a preencher antes de enviar.
--         - Escopo segue o vendedor ESCOLHIDO (não o admin), via castor_user_scope.
--         - Exclui clientes que JÁ estão em roteiro aberto do mesmo vendedor.
--       O front mostra os 5 primeiros; ao "descartar" um, pega o próximo do pool.
--
-- depends: 004, 010, 011, 015, 019
-- reversible: yes (DROP FUNCTION)
-- IDEMPOTENTE.

BEGIN;

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
  v_vend  TEXT;
  v_est   TEXT[];
  v_cid   TEXT[];
  v_role  TEXT;
  v_open_codes TEXT[];
  v_rows  JSONB;
  v_lim   INT;
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

  -- Códigos já em roteiros abertos do target (não sugerir de novo)
  SELECT COALESCE(array_agg(DISTINCT s.cliente_codigo), ARRAY[]::TEXT[])
    INTO v_open_codes
  FROM castor_route_stop s
  JOIN castor_route_saved r ON r.id = s.route_id
  WHERE r.user_id = p_target_user_id
    AND r.status IN ('planejado','em_andamento')
    AND s.cliente_codigo IS NOT NULL;

  v_lim := GREATEST(5, LEAST(COALESCE(p_limit, 30), 100));

  SELECT jsonb_agg(t.row ORDER BY (t.row->>'urgencia_score')::INT DESC NULLS LAST,
                                  (t.row->>'faturamento_alltime')::NUMERIC DESC NULLS LAST)
    INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'cliente_codigo',    m.cliente_codigo,
      'a1_nome',           m.a1_nome,
      'a1_vend',           m.a1_vend,
      'vendedor_nome',     m.vendedor_nome,
      'a1_end',            m.a1_end,
      'a1_cep',            m.a1_cep,
      'a1_mun',            m.a1_mun,
      'a1_est',            m.a1_est,
      'contato_nome',      m.contato_nome,
      'contato_tel',       m.contato_tel,
      'contato_whats',     m.contato_whats,
      'contato_email',     m.contato_email,
      'status_real',       m.status_real,
      'urgencia_score',    m.urgencia_score,
      'porte_efetivo',     m.porte_efetivo,
      'faturamento_alltime', m.faturamento_alltime,
      'ultimo_pedido',     m.ultimo_pedido,
      'dias_sem_pedido',   m.dias_sem_pedido,
      'lat',               g.lat,
      'lng',               g.lng,
      'has_geocode',       (g.lat IS NOT NULL AND g.lng IS NOT NULL),
      'missing_address',   (m.a1_end IS NULL OR btrim(m.a1_end) = ''),
      'missing_contact',   (COALESCE(NULLIF(btrim(m.contato_tel),''),
                                     NULLIF(btrim(m.contato_whats),''),
                                     NULLIF(btrim(m.contato_email),'')) IS NULL)
    ) AS row
    FROM castor_client_metrics_v2 m
    LEFT JOIN castor_geocode_cache g
      ON g.scope = 'municipio'
     AND g.query_key = upper(coalesce(m.a1_mun,'')) || '|' || upper(coalesce(m.a1_est,''))
     AND g.ok
    WHERE m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
      AND m.pedidos_alltime >= 1
      AND (v_vend IS NULL OR m.a1_vend = v_vend)
      AND (v_est  IS NULL OR upper(coalesce(m.a1_est,'')) = ANY(v_est))
      AND (v_cid  IS NULL OR upper(coalesce(m.a1_mun,'')) = ANY(v_cid))
      AND (p_exclude_codes IS NULL OR NOT (m.cliente_codigo = ANY(p_exclude_codes)))
      AND NOT (m.cliente_codigo = ANY(v_open_codes))
    ORDER BY m.urgencia_score DESC NULLS LAST, m.faturamento_alltime DESC NULLS LAST
    LIMIT v_lim
  ) t;

  RETURN jsonb_build_object(
    'ok',            true,
    'target_user_id',p_target_user_id,
    'vendor_code',   v_vend,
    'pool',          COALESCE(v_rows, '[]'::jsonb),
    'pool_size',     COALESCE(jsonb_array_length(v_rows), 0),
    'open_excluded', COALESCE(array_length(v_open_codes,1), 0)
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_suggest_pool(UUID, UUID, TEXT[], INT)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('020_admin_suggest_pool') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

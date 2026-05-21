-- file: 015_interactions_and_override.sql
-- tier: A
-- purpose:
--   * castor_client_address_override: endereço/contato manual por cliente
--     (preenchido quando SC5010 não tem L.E: parseável). Override é usado
--     no roteiro e em qualquer outra leitura via view castor_client_address.
--   * castor_client_interactions: timeline completa de contatos (visita,
--     telefone, whatsapp, e-mail, reunião) com outcome + agendamento do
--     próximo contato. Substitui em UX (mas não apaga) castor_visita_feedback.
--   * Outcome universe ampliado para: visitou, sem_contato, convertido,
--     voltar_depois, negativo, aguardando_resposta, pedido_em_negociacao,
--     nao_existe_mais, nao_interessado_permanente.
--   * RPCs: address-override CRUD, interaction add/list, pending-followups,
--     client_status_set, route_update_stop v2 (interaction_type + next_contact).
-- depends_on: 005, 010, 011, 013, 014
-- safe_to_rerun: yes (CREATE OR REPLACE / IF NOT EXISTS)

BEGIN;

-- ============================================================
-- 0) Constantes (valores aceitos) — registradas como CHECK constraints
-- ============================================================

-- 0.1 Amplia outcomes aceitos em castor_visita_feedback
ALTER TABLE castor_visita_feedback DROP CONSTRAINT IF EXISTS castor_visita_feedback_outcome_check;
ALTER TABLE castor_visita_feedback
  ADD CONSTRAINT castor_visita_feedback_outcome_check CHECK (
    outcome IN (
      'visitou','sem_contato','convertido','voltar_depois','negativo',
      'aguardando_resposta','pedido_em_negociacao',
      'nao_existe_mais','nao_interessado_permanente'
    )
  );

-- 0.2 Amplia a função que registra feedback (idem CHECK no IF interno)
CREATE OR REPLACE FUNCTION castor_register_visit_feedback(
  p_cliente_codigo   TEXT,
  p_outcome          TEXT,
  p_custom_days      INT  DEFAULT NULL,
  p_notes            TEXT DEFAULT NULL,
  p_idempotency_key  TEXT DEFAULT NULL
)
RETURNS castor_visita_feedback
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_codigo   TEXT;
  v_days     INT;
  v_next     DATE;
  v_existing castor_visita_feedback;
  v_row      castor_visita_feedback;
  v_allowed  TEXT[] := ARRAY[
    'visitou','sem_contato','convertido','voltar_depois','negativo',
    'aguardando_resposta','pedido_em_negociacao',
    'nao_existe_mais','nao_interessado_permanente'
  ];
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Não autenticado.' USING ERRCODE = '42501';
  END IF;
  IF NOT (p_outcome = ANY(v_allowed)) THEN
    RAISE EXCEPTION 'Outcome inválido: %', p_outcome USING ERRCODE = '22023';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT * INTO v_existing FROM castor_visita_feedback WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN v_existing;
    END IF;
  END IF;

  SELECT codigo INTO v_codigo FROM castor_vendor_user WHERE user_id = v_user_id;

  -- Outcomes "fim-de-vida" e "convertido" não agendam próximo contato
  IF p_outcome IN ('convertido','nao_existe_mais','nao_interessado_permanente') THEN
    v_next := NULL;
  ELSE
    v_days := COALESCE(p_custom_days, 20);
    IF v_days < 1 OR v_days > 365 THEN
      RAISE EXCEPTION 'custom_days fora do intervalo (1-365).' USING ERRCODE = '22023';
    END IF;
    v_next := (NOW() + (v_days || ' days')::INTERVAL)::DATE;
  END IF;

  INSERT INTO castor_visita_feedback(
    cliente_codigo, vendedor_user_id, vendedor_codigo, visited_at,
    outcome, custom_days, next_contact_at, notes, idempotency_key
  )
  VALUES (
    p_cliente_codigo, v_user_id, v_codigo, NOW(),
    p_outcome, p_custom_days, v_next, p_notes, p_idempotency_key
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;
GRANT EXECUTE ON FUNCTION castor_register_visit_feedback(TEXT, TEXT, INT, TEXT, TEXT) TO authenticated;

-- ============================================================
-- 1) OVERRIDE de endereço/contato por cliente
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_client_address_override (
  cliente_codigo   TEXT PRIMARY KEY,
  endereco         TEXT,
  cep              TEXT,
  municipio        TEXT,
  uf               TEXT,
  contato_nome     TEXT,
  contato_tel      TEXT,
  contato_email    TEXT,
  contato_whats    TEXT,
  lifecycle_status TEXT CHECK (lifecycle_status IN (
    'ativo','encerrado','nao_interessado_permanente'
  )),
  notes            TEXT,
  updated_by       UUID,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_client_address_override_mun_idx ON castor_client_address_override(uf, municipio);
CREATE INDEX IF NOT EXISTS castor_client_address_override_life_idx ON castor_client_address_override(lifecycle_status);

CREATE OR REPLACE FUNCTION castor_client_address_override_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS castor_client_address_override_touch_trg ON castor_client_address_override;
CREATE TRIGGER castor_client_address_override_touch_trg
  BEFORE UPDATE ON castor_client_address_override
  FOR EACH ROW EXECUTE FUNCTION castor_client_address_override_touch();

-- 1.1 Substitui a view castor_client_address — agora prefere o override.
DROP VIEW IF EXISTS castor_client_address CASCADE;
CREATE VIEW castor_client_address AS
WITH ranked AS (
  SELECT (c5_cliente || COALESCE(c5_loja,'')) AS cliente_codigo,
         c5_end, c5_cep, c5_mun, c5_uf, c5_emissao,
         ROW_NUMBER() OVER (
           PARTITION BY (c5_cliente || COALESCE(c5_loja,''))
           ORDER BY (c5_uf IS NOT NULL) DESC, c5_emissao DESC NULLS LAST
         ) AS rn
    FROM castor_src_sc5010
   WHERE c5_cliente IS NOT NULL AND c5_cliente <> ''
),
sc5 AS (
  SELECT cliente_codigo, c5_end AS endereco, c5_cep AS cep, c5_mun AS municipio, c5_uf AS uf
    FROM ranked WHERE rn = 1
)
SELECT
  COALESCE(o.cliente_codigo, sc5.cliente_codigo) AS cliente_codigo,
  COALESCE(NULLIF(btrim(o.endereco),''),  sc5.endereco)  AS endereco,
  COALESCE(NULLIF(btrim(o.cep),''),       sc5.cep)       AS cep,
  COALESCE(NULLIF(btrim(o.municipio),''), sc5.municipio) AS municipio,
  COALESCE(NULLIF(btrim(o.uf),''),        sc5.uf)        AS uf,
  -- meta extra (não estava antes — quem consumir pode ignorar)
  o.contato_nome,
  o.contato_tel,
  o.contato_whats,
  o.contato_email,
  o.lifecycle_status,
  CASE WHEN o.cliente_codigo IS NOT NULL THEN 'override'
       WHEN sc5.endereco IS NOT NULL OR sc5.municipio IS NOT NULL THEN 'sc5010'
       ELSE NULL END AS endereco_source
FROM sc5
FULL OUTER JOIN castor_client_address_override o
  ON o.cliente_codigo = sc5.cliente_codigo;

-- recriar castor_client_metrics_v2 pois usamos CASCADE acima.
-- Ela depende de castor_client_address. Reaproveita definição original (010).
CREATE OR REPLACE VIEW castor_client_metrics_v2 AS
SELECT
  d.cliente_codigo,
  d.a1_cod,
  d.a1_loja,
  d.a1_nome,
  d.a1_vend,
  v.a3_nome      AS vendedor_nome,
  v.a3_nreduz    AS vendedor_nreduz,
  addr.endereco  AS a1_end,
  addr.cep       AS a1_cep,
  addr.municipio AS a1_mun,
  addr.uf        AS a1_est,
  addr.endereco_source,
  addr.lifecycle_status,
  COALESCE(f12.faturamento_12m, 0)   AS faturamento_12m,
  COALESCE(f12.pedidos_12m, 0)       AS pedidos_12m,
  COALESCE(f12.ticket_medio_12m, 0)  AS ticket_medio_12m,
  COALESCE(fa.faturamento_alltime, 0)  AS faturamento_alltime,
  COALESCE(fa.pedidos_alltime, 0)      AS pedidos_alltime,
  COALESCE(fa.ticket_medio_alltime, 0) AS ticket_medio_alltime,
  fa.primeira_nota,
  fa.ultima_nota,
  fa.primeiro_pedido,
  fa.ultimo_pedido,
  fa.ultima_atividade,
  CASE WHEN fa.ultima_atividade IS NOT NULL
       THEN (CURRENT_DATE - fa.ultima_atividade)::INT
       ELSE NULL END AS dias_sem_atividade,
  CASE WHEN fa.ultimo_pedido IS NOT NULL
       THEN (CURRENT_DATE - fa.ultimo_pedido)::INT
       ELSE NULL END AS dias_sem_pedido,
  CASE
    WHEN addr.lifecycle_status = 'encerrado'                       THEN 'ENCERRADO'
    WHEN addr.lifecycle_status = 'nao_interessado_permanente'      THEN 'NAO_INTERESSADO'
    WHEN fa.ultima_atividade IS NULL                               THEN 'SEM_HISTORICO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '90 days')  THEN 'ATIVO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '180 days') THEN 'EM_RISCO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '365 days') THEN 'REATIVAR'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '730 days') THEN 'INATIVO'
    ELSE 'DORMENTE'
  END AS status_real,
  CASE
    WHEN COALESCE(f12.ticket_medio_12m,0) > 0 THEN
      CASE WHEN f12.ticket_medio_12m < 3000  THEN 'pequeno'
           WHEN f12.ticket_medio_12m <= 10000 THEN 'medio'
           ELSE 'grande' END
    WHEN COALESCE(fa.ticket_medio_alltime,0) > 0 THEN
      CASE WHEN fa.ticket_medio_alltime < 3000  THEN 'pequeno'
           WHEN fa.ticket_medio_alltime <= 10000 THEN 'medio'
           ELSE 'grande' END
    ELSE 'desconhecido'
  END AS porte_efetivo,
  CASE
    WHEN COALESCE(f12.ticket_medio_12m,0)     > 0 THEN 'historico_12m'
    WHEN COALESCE(fa.ticket_medio_alltime,0)  > 0 THEN 'historico_alltime'
    ELSE 'sem_dados'
  END AS porte_origem,
  -- urgência: 0-100 (atividade recente = alto risco se sumiu)
  LEAST(100, GREATEST(0,
    COALESCE((CURRENT_DATE - fa.ultima_atividade)::INT / 4, 0)
    + CASE WHEN COALESCE(fa.faturamento_alltime,0) > 50000 THEN 10 ELSE 0 END
  ))::INT AS urgencia_score,
  addr.contato_nome,
  addr.contato_tel,
  addr.contato_whats,
  addr.contato_email
FROM castor_clientes_derived_v2 d
LEFT JOIN castor_client_address addr ON addr.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_metrics_alltime fa  ON fa.cliente_codigo  = d.cliente_codigo
LEFT JOIN castor_client_metrics f12  ON f12.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_src_sa3010 v        ON v.a3_cod = d.a1_vend;

-- 1.2 RPCs do override
CREATE OR REPLACE FUNCTION castor_client_address_override_set(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_endereco       TEXT,
  p_cep            TEXT,
  p_municipio      TEXT,
  p_uf             TEXT,
  p_contato_nome   TEXT,
  p_contato_tel    TEXT,
  p_contato_email  TEXT,
  p_contato_whats  TEXT,
  p_notes          TEXT,
  p_lifecycle      TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_row castor_client_address_override%ROWTYPE;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','unauthenticated');
  END IF;
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok',false,'error','cliente_codigo_required');
  END IF;

  INSERT INTO castor_client_address_override(
    cliente_codigo, endereco, cep, municipio, uf,
    contato_nome, contato_tel, contato_email, contato_whats,
    notes, lifecycle_status, updated_by
  )
  VALUES (
    p_cliente_codigo,
    NULLIF(btrim(p_endereco),''),
    NULLIF(regexp_replace(coalesce(p_cep,''),'\D','','g'),''),
    NULLIF(btrim(upper(p_municipio)),''),
    NULLIF(btrim(upper(p_uf)),''),
    NULLIF(btrim(p_contato_nome),''),
    NULLIF(btrim(p_contato_tel),''),
    NULLIF(btrim(p_contato_email),''),
    NULLIF(btrim(p_contato_whats),''),
    NULLIF(btrim(p_notes),''),
    NULLIF(btrim(p_lifecycle),''),
    p_user_id
  )
  ON CONFLICT (cliente_codigo) DO UPDATE SET
    endereco         = COALESCE(NULLIF(btrim(EXCLUDED.endereco),''),         castor_client_address_override.endereco),
    cep              = COALESCE(NULLIF(EXCLUDED.cep,''),                     castor_client_address_override.cep),
    municipio        = COALESCE(NULLIF(EXCLUDED.municipio,''),               castor_client_address_override.municipio),
    uf               = COALESCE(NULLIF(EXCLUDED.uf,''),                      castor_client_address_override.uf),
    contato_nome     = COALESCE(NULLIF(EXCLUDED.contato_nome,''),            castor_client_address_override.contato_nome),
    contato_tel      = COALESCE(NULLIF(EXCLUDED.contato_tel,''),             castor_client_address_override.contato_tel),
    contato_email    = COALESCE(NULLIF(EXCLUDED.contato_email,''),           castor_client_address_override.contato_email),
    contato_whats    = COALESCE(NULLIF(EXCLUDED.contato_whats,''),           castor_client_address_override.contato_whats),
    notes            = COALESCE(NULLIF(EXCLUDED.notes,''),                   castor_client_address_override.notes),
    lifecycle_status = COALESCE(NULLIF(EXCLUDED.lifecycle_status,''),        castor_client_address_override.lifecycle_status),
    updated_by       = EXCLUDED.updated_by
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok',true,'data', to_jsonb(v_row));
END; $$;
GRANT EXECUTE ON FUNCTION castor_client_address_override_set(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION castor_client_address_override_get(
  p_cliente_codigo TEXT
) RETURNS castor_client_address_override
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql AS $$
  SELECT * FROM castor_client_address_override WHERE cliente_codigo = p_cliente_codigo;
$$;
GRANT EXECUTE ON FUNCTION castor_client_address_override_get(TEXT) TO authenticated, service_role;

-- 1.3 Atalho: setar lifecycle (encerrado / nao_interessado_permanente / ativo)
CREATE OR REPLACE FUNCTION castor_client_status_set(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_lifecycle      TEXT,
  p_notes          TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','unauthenticated');
  END IF;
  IF p_lifecycle NOT IN ('ativo','encerrado','nao_interessado_permanente') THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_lifecycle');
  END IF;

  INSERT INTO castor_client_address_override(cliente_codigo, lifecycle_status, notes, updated_by)
  VALUES (p_cliente_codigo, p_lifecycle, NULLIF(btrim(p_notes),''), p_user_id)
  ON CONFLICT (cliente_codigo) DO UPDATE SET
    lifecycle_status = EXCLUDED.lifecycle_status,
    notes            = COALESCE(EXCLUDED.notes, castor_client_address_override.notes),
    updated_by       = EXCLUDED.updated_by;

  RETURN jsonb_build_object('ok',true,'cliente_codigo',p_cliente_codigo,'lifecycle',p_lifecycle);
END; $$;
GRANT EXECUTE ON FUNCTION castor_client_status_set(UUID,TEXT,TEXT,TEXT) TO authenticated, service_role;

-- ============================================================
-- 2) TIMELINE de interações
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_client_interactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_codigo   TEXT NOT NULL,
  vendedor_user_id UUID,
  vendedor_codigo  TEXT,
  route_id         UUID,                                                    -- sem FK para evitar cascade indireto
  interaction_type TEXT NOT NULL CHECK (interaction_type IN (
    'visita_presencial','telefone','whatsapp','email','reuniao_online','outro'
  )),
  outcome          TEXT CHECK (outcome IN (
    'visitou','sem_contato','convertido','voltar_depois','negativo',
    'aguardando_resposta','pedido_em_negociacao',
    'nao_existe_mais','nao_interessado_permanente'
  )),
  notes            TEXT,
  occurred_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  next_contact_at  DATE,
  next_action      TEXT,
  idempotency_key  TEXT UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_client_interactions_cli_idx     ON castor_client_interactions(cliente_codigo, occurred_at DESC);
CREATE INDEX IF NOT EXISTS castor_client_interactions_user_idx    ON castor_client_interactions(vendedor_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS castor_client_interactions_next_idx    ON castor_client_interactions(next_contact_at)
  WHERE next_contact_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS castor_client_interactions_route_idx   ON castor_client_interactions(route_id)
  WHERE route_id IS NOT NULL;

-- 2.1 Adicionar uma interação
CREATE OR REPLACE FUNCTION castor_client_interaction_add(
  p_user_id          UUID,
  p_cliente_codigo   TEXT,
  p_interaction_type TEXT,
  p_outcome          TEXT,
  p_notes            TEXT,
  p_next_contact_at  DATE,
  p_next_days        INT,
  p_next_action      TEXT,
  p_route_id         UUID,
  p_idempotency_key  TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row        castor_client_interactions%ROWTYPE;
  v_codigo     TEXT;
  v_next       DATE;
  v_existing   castor_client_interactions%ROWTYPE;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','unauthenticated');
  END IF;
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok',false,'error','cliente_codigo_required');
  END IF;
  IF p_interaction_type IS NULL OR p_interaction_type NOT IN (
    'visita_presencial','telefone','whatsapp','email','reuniao_online','outro'
  ) THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_interaction_type');
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT * INTO v_existing FROM castor_client_interactions WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object('ok',true,'data',to_jsonb(v_existing),'idempotent',true);
    END IF;
  END IF;

  SELECT codigo INTO v_codigo FROM castor_vendor_user WHERE user_id = p_user_id;

  -- Resolve next_contact_at: datepicker tem prioridade, senão calcula a partir de next_days.
  IF p_next_contact_at IS NOT NULL THEN
    v_next := p_next_contact_at;
  ELSIF p_next_days IS NOT NULL AND p_next_days BETWEEN 1 AND 365 THEN
    v_next := (CURRENT_DATE + (p_next_days || ' days')::INTERVAL)::DATE;
  ELSE
    v_next := NULL;
  END IF;

  -- Outcomes definitivos não agendam
  IF p_outcome IN ('convertido','nao_existe_mais','nao_interessado_permanente') THEN
    v_next := NULL;
  END IF;

  INSERT INTO castor_client_interactions(
    cliente_codigo, vendedor_user_id, vendedor_codigo, route_id,
    interaction_type, outcome, notes, next_contact_at, next_action,
    idempotency_key
  ) VALUES (
    p_cliente_codigo, p_user_id, v_codigo, p_route_id,
    p_interaction_type, NULLIF(p_outcome,''), NULLIF(btrim(p_notes),''),
    v_next, NULLIF(btrim(p_next_action),''),
    NULLIF(p_idempotency_key,'')
  )
  RETURNING * INTO v_row;

  -- Espelha em castor_visita_feedback para compatibilidade com snapshot/agendamento existente
  IF v_row.outcome IS NOT NULL THEN
    BEGIN
      INSERT INTO castor_visita_feedback(
        cliente_codigo, vendedor_user_id, vendedor_codigo, visited_at,
        outcome, custom_days, next_contact_at, notes, idempotency_key
      ) VALUES (
        v_row.cliente_codigo, v_row.vendedor_user_id, v_row.vendedor_codigo, v_row.occurred_at,
        v_row.outcome, p_next_days, v_row.next_contact_at, v_row.notes,
        'interaction:' || v_row.id::TEXT
      );
    EXCEPTION WHEN unique_violation THEN
      -- já existe, ignora
      NULL;
    END;
  END IF;

  -- Se outcome encerra cliente, aplica lifecycle no override
  IF p_outcome = 'nao_existe_mais' THEN
    PERFORM castor_client_status_set(p_user_id, p_cliente_codigo, 'encerrado', p_notes);
  ELSIF p_outcome = 'nao_interessado_permanente' THEN
    PERFORM castor_client_status_set(p_user_id, p_cliente_codigo, 'nao_interessado_permanente', p_notes);
  END IF;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(v_row));
END; $$;
GRANT EXECUTE ON FUNCTION castor_client_interaction_add(UUID,TEXT,TEXT,TEXT,TEXT,DATE,INT,TEXT,UUID,TEXT) TO authenticated, service_role;

-- 2.2 Listar interações de um cliente
CREATE OR REPLACE FUNCTION castor_client_interaction_list(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_limit          INT
) RETURNS TABLE(
  id UUID, cliente_codigo TEXT, vendedor_user_id UUID, vendedor_nome TEXT,
  route_id UUID, interaction_type TEXT, outcome TEXT,
  notes TEXT, occurred_at TIMESTAMPTZ, next_contact_at DATE, next_action TEXT
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE v_is_admin BOOLEAN;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  RETURN QUERY
  SELECT i.id, i.cliente_codigo, i.vendedor_user_id,
         COALESCE((u.raw_user_meta_data->>'name'), u.email) AS vendedor_nome,
         i.route_id, i.interaction_type, i.outcome,
         i.notes, i.occurred_at, i.next_contact_at, i.next_action
    FROM castor_client_interactions i
    LEFT JOIN auth.users u ON u.id = i.vendedor_user_id
   WHERE i.cliente_codigo = p_cliente_codigo
     AND (v_is_admin OR i.vendedor_user_id = p_user_id)
   ORDER BY i.occurred_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
END; $$;
GRANT EXECUTE ON FUNCTION castor_client_interaction_list(UUID,TEXT,INT) TO authenticated, service_role;

-- 2.3 Follow-ups pendentes do vendedor (ou todos, se admin)
CREATE OR REPLACE FUNCTION castor_client_pending_followups(
  p_user_id     UUID,
  p_days_ahead  INT,         -- janela futura (0=apenas vencidos+hoje)
  p_limit       INT
) RETURNS TABLE(
  cliente_codigo  TEXT,
  cliente_nome    TEXT,
  municipio       TEXT,
  uf              TEXT,
  contato_tel     TEXT,
  contato_whats   TEXT,
  contato_email   TEXT,
  next_contact_at DATE,
  dias_para       INT,
  last_outcome    TEXT,
  last_type       TEXT,
  last_notes      TEXT,
  vendedor_user_id UUID
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_is_admin BOOLEAN;
  v_cap_date DATE;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  v_cap_date := CURRENT_DATE + (GREATEST(0, COALESCE(p_days_ahead,0)) || ' days')::INTERVAL;

  RETURN QUERY
  WITH last_per_client AS (
    SELECT DISTINCT ON (cliente_codigo)
           cliente_codigo, vendedor_user_id, interaction_type, outcome, notes,
           next_contact_at, occurred_at
      FROM castor_client_interactions
     WHERE next_contact_at IS NOT NULL
     ORDER BY cliente_codigo, occurred_at DESC
  )
  SELECT
    l.cliente_codigo,
    m.a1_nome,
    m.a1_mun,
    m.a1_est,
    m.contato_tel,
    m.contato_whats,
    m.contato_email,
    l.next_contact_at,
    (l.next_contact_at - CURRENT_DATE)::INT AS dias_para,
    l.outcome,
    l.interaction_type,
    l.notes,
    l.vendedor_user_id
  FROM last_per_client l
  LEFT JOIN castor_client_metrics_v2 m ON m.cliente_codigo = l.cliente_codigo
  WHERE l.next_contact_at <= v_cap_date
    AND (v_is_admin OR l.vendedor_user_id = p_user_id)
    AND COALESCE(m.lifecycle_status,'ativo') NOT IN ('encerrado','nao_interessado_permanente')
  ORDER BY l.next_contact_at ASC NULLS LAST
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit,100), 500));
END; $$;
GRANT EXECUTE ON FUNCTION castor_client_pending_followups(UUID,INT,INT) TO authenticated, service_role;

-- ============================================================
-- 3) castor_route_update_stop v2: adiciona interaction_type + next_contact_at
--    Compatível com chamada antiga (sem os campos novos) graças aos defaults.
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_update_stop(
  p_user_id          UUID,
  p_route_id         UUID,
  p_cliente_codigo   TEXT,
  p_outcome          TEXT,
  p_notes            TEXT,
  p_custom_days      INT,
  p_interaction_type TEXT DEFAULT NULL,
  p_next_contact_at  DATE DEFAULT NULL,
  p_next_action      TEXT DEFAULT NULL
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row     castor_route_saved%ROWTYPE;
  v_new     JSONB := '[]'::JSONB;
  v_elem    JSONB;
  v_open    INT := 0;
  v_done    INT := 0;
  v_total   INT := 0;
  v_is_admin BOOLEAN;
  v_itype   TEXT;
  v_next    DATE;
  v_allowed TEXT[] := ARRAY[
    'visitou','sem_contato','convertido','voltar_depois','negativo',
    'aguardando_resposta','pedido_em_negociacao',
    'nao_existe_mais','nao_interessado_permanente'
  ];
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
  IF p_outcome IS NOT NULL AND NOT (p_outcome = ANY(v_allowed)) THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_outcome');
  END IF;

  -- Resolve interaction_type (default: visita_presencial; e-mail/whatsapp/etc passados explícitos).
  v_itype := COALESCE(NULLIF(btrim(p_interaction_type),''), 'visita_presencial');
  IF v_itype NOT IN ('visita_presencial','telefone','whatsapp','email','reuniao_online','outro') THEN
    v_itype := 'visita_presencial';
  END IF;

  -- Resolve next_contact_at
  IF p_next_contact_at IS NOT NULL THEN
    v_next := p_next_contact_at;
  ELSIF p_custom_days IS NOT NULL AND p_custom_days BETWEEN 1 AND 365 THEN
    v_next := (CURRENT_DATE + (p_custom_days || ' days')::INTERVAL)::DATE;
  ELSE
    v_next := NULL;
  END IF;
  IF p_outcome IN ('convertido','nao_existe_mais','nao_interessado_permanente') THEN
    v_next := NULL;
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_row.stops) LOOP
    v_total := v_total + 1;
    IF (v_elem->>'cliente_codigo') = p_cliente_codigo THEN
      IF p_outcome IS NULL THEN
        v_elem := v_elem - 'outcome' - 'visited_at' - 'notes' - 'interaction_type' - 'next_contact_at' - 'next_action';
      ELSE
        v_elem := v_elem
          || jsonb_build_object(
               'outcome',          p_outcome,
               'visited_at',       NOW(),
               'interaction_type', v_itype
             )
          || (CASE WHEN p_notes IS NOT NULL AND btrim(p_notes) <> ''
                    THEN jsonb_build_object('notes', p_notes) ELSE '{}'::jsonb END)
          || (CASE WHEN v_next IS NOT NULL
                    THEN jsonb_build_object('next_contact_at', to_char(v_next,'YYYY-MM-DD')) ELSE '{}'::jsonb END)
          || (CASE WHEN p_next_action IS NOT NULL AND btrim(p_next_action) <> ''
                    THEN jsonb_build_object('next_action', p_next_action) ELSE '{}'::jsonb END);
      END IF;
    END IF;
    IF (v_elem->>'outcome') IS NOT NULL THEN v_done := v_done + 1; END IF;
    v_new := v_new || jsonb_build_array(v_elem);
  END LOOP;

  v_open := v_total - v_done;

  UPDATE castor_route_saved SET
    stops        = v_new,
    status       = CASE
                     WHEN v_done = 0 THEN 'planejado'
                     WHEN v_open = 0 THEN 'concluido'
                     ELSE 'em_andamento'
                   END,
    completed_at = CASE WHEN v_open = 0 THEN NOW() ELSE NULL END
   WHERE id = p_route_id;

  -- Grava também na timeline rica de interações (idempotente via idempotency_key).
  IF p_outcome IS NOT NULL THEN
    PERFORM castor_client_interaction_add(
      p_user_id, p_cliente_codigo, v_itype, p_outcome,
      p_notes, v_next, NULL, p_next_action,
      p_route_id, 'route:' || p_route_id::TEXT || ':' || p_cliente_codigo
    );
  END IF;

  RETURN jsonb_build_object('ok',true,'route_id',p_route_id,'done',v_done,'total',v_total);
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_update_stop(UUID,UUID,TEXT,TEXT,TEXT,INT,TEXT,DATE,TEXT) TO authenticated, service_role;

-- ============================================================
-- 4) Detecção de mudanças após nova ingestão (para a IA narrar)
--    Comparar último valor por cliente vs snapshot anterior.
--    Implementação leve: usa castor_metrics_alltime.computed_at + um
--    snapshot_diff calculado on-demand (sem materializar histórico).
-- ============================================================
CREATE OR REPLACE FUNCTION castor_client_recent_changes(
  p_user_id     UUID,
  p_since_hours INT,
  p_limit       INT
) RETURNS TABLE(
  cliente_codigo  TEXT,
  cliente_nome    TEXT,
  ultima_atividade DATE,
  faturamento_alltime NUMERIC,
  status_real     TEXT,
  changed_at      TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE v_is_admin BOOLEAN; v_scope_vend TEXT;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;
  SELECT vendor_code INTO v_scope_vend FROM castor_user_scope(p_user_id);

  RETURN QUERY
  SELECT m.cliente_codigo, m.a1_nome, m.ultima_atividade,
         m.faturamento_alltime, m.status_real, fa.computed_at
    FROM castor_client_metrics_v2 m
    JOIN castor_metrics_alltime fa ON fa.cliente_codigo = m.cliente_codigo
   WHERE fa.computed_at >= NOW() - (GREATEST(1, COALESCE(p_since_hours,24)) || ' hours')::INTERVAL
     AND (v_is_admin OR v_scope_vend IS NULL OR m.a1_vend = v_scope_vend)
   ORDER BY fa.computed_at DESC, m.faturamento_alltime DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,30), 200));
END; $$;
GRANT EXECUTE ON FUNCTION castor_client_recent_changes(UUID,INT,INT) TO authenticated, service_role;

-- ============================================================
INSERT INTO castor_schema_migrations(version)
VALUES ('015_interactions_and_override')
ON CONFLICT (version) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

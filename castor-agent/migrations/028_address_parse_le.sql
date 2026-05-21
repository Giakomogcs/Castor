-- file: 028_address_parse_le.sql
-- tier: A
-- purpose:
--   Corrige endereços vindos como "PEDIDO 180948-43 PEDIDO SC3 5530837"
--   no painel de sugestões. Em SC5010 o campo c5_end NÃO é o endereço do
--   cliente — é a observação do pedido. O endereço REAL do local de entrega
--   está embutido prefixado por "L.E: " e termina em "PEDIDO XXXXXX".
--
--   Exemplos reais (extraídos de SC5010.csv):
--     "L.E: R CALIXTO 180 CEP:08330450 SAO PAULO-SP   PEDIDO 000015"
--     "L.E: RUA SETE DE SETEMBRO 112 CEP:89110000 GASPAR-SC   PEDIDO 000016"
--
--   Esta migração:
--     1) Cria função imutável castor_parse_le(text) que extrai
--        endereco/cep/municipio/uf do bloco "L.E: ... PEDIDO".
--     2) Recria castor_client_address aplicando o parser quando o c5_end
--        contém "L.E:". Se não contém, mantém c5_mun/c5_uf/c5_cep originais
--        (alguns pedidos antigos podem usar a coluna nativa).
--     3) Recria castor_client_metrics_v2 (CASCADE removeu).
--     4) IGNORA endereços que ainda contenham só "PEDIDO" (sem L.E:),
--        evitando que apareçam como endereço falso.
--
-- depends: 011, 015, 021, 027
-- reversible: drop function + reaplicar 015
-- IDEMPOTENTE.

BEGIN;

-- ============================================================
-- 1) Parser do bloco "L.E:"
-- ============================================================
-- castor_parse_le já existe em 011 (extrai apenas endereço cru). Vamos criar
-- castor_parse_le_full que devolve endereco/cep/municipio/uf separados.
CREATE OR REPLACE FUNCTION castor_parse_le_full(p_text TEXT)
RETURNS TABLE(endereco TEXT, cep TEXT, municipio TEXT, uf TEXT)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_block TEXT;
  v_cep   TEXT;
  v_mun   TEXT;
  v_uf    TEXT;
  v_end   TEXT;
  v_after_cep TEXT;
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN;
  END IF;

  -- Captura o trecho entre "L.E:" e "PEDIDO" (ou fim).
  v_block := substring(upper(p_text)
    FROM '(?:L\.?\s*E\s*\.?\s*:?)\s*(.+?)(?:\s+PEDIDO\b|$)');

  IF v_block IS NULL OR btrim(v_block) = '' THEN
    RETURN;
  END IF;

  -- CEP: 8 dígitos.
  v_cep := substring(v_block FROM 'CEP\s*:?\s*([0-9]{8})');
  IF v_cep IS NULL THEN
    v_cep := substring(v_block FROM '([0-9]{5}-?[0-9]{3})');
    IF v_cep IS NOT NULL THEN
      v_cep := regexp_replace(v_cep, '\D', '', 'g');
    END IF;
  END IF;

  -- Após o CEP costuma vir "MUNICIPIO-UF". Captura "X-Y" no fim.
  v_after_cep := v_block;
  IF v_cep IS NOT NULL THEN
    v_after_cep := regexp_replace(v_after_cep, 'CEP\s*:?\s*' || v_cep, '', 'g');
  END IF;
  v_mun := substring(v_after_cep FROM '([A-ZÇÁÉÍÓÚÂÊÔÃÕÀ\.\s]{3,})\-([A-Z]{2})\s*$');
  v_uf  := substring(v_after_cep FROM '\-([A-Z]{2})\s*$');
  IF v_mun IS NOT NULL THEN v_mun := btrim(v_mun); END IF;

  -- Endereço = tudo antes de "CEP:" (ou antes de "MUN-UF" se não tiver CEP).
  v_end := v_block;
  v_end := regexp_replace(v_end, '\s*CEP\s*:?\s*[0-9]{8}\b.*$', '', 'g');
  v_end := regexp_replace(v_end, '\s*[0-9]{5}-?[0-9]{3}\b.*$', '', 'g');
  -- Se não encontrou CEP nem o split funcionou, tenta cortar antes do "MUN-UF" final.
  IF v_end = v_block AND v_uf IS NOT NULL THEN
    v_end := regexp_replace(v_end, '\s*[A-ZÇÁÉÍÓÚÂÊÔÃÕÀ\.\s]{3,}\-[A-Z]{2}\s*$', '', 'g');
  END IF;
  v_end := btrim(v_end);
  IF v_end = '' THEN v_end := NULL; END IF;

  endereco  := v_end;
  cep       := v_cep;
  municipio := v_mun;
  uf        := v_uf;
  RETURN NEXT;
END; $$;

GRANT EXECUTE ON FUNCTION castor_parse_le_full(TEXT) TO authenticated, service_role;

-- ============================================================
-- 2) Recria castor_client_address usando o parser
-- ============================================================
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
parsed AS (
  SELECT
    r.cliente_codigo,
    r.c5_end, r.c5_cep, r.c5_mun, r.c5_uf,
    le.endereco  AS le_end,
    le.cep       AS le_cep,
    le.municipio AS le_mun,
    le.uf        AS le_uf
  FROM ranked r
  LEFT JOIN LATERAL castor_parse_le_full(r.c5_end) le ON true
  WHERE r.rn = 1
),
sc5 AS (
  SELECT
    cliente_codigo,
    -- Endereço: prioriza L.E:, senão usa c5_end SE não contiver "PEDIDO"
    -- (descarta lixo tipo "PEDIDO 180948-43 PEDIDO SC3 5530837").
    COALESCE(
      NULLIF(btrim(le_end), ''),
      CASE
        WHEN c5_end IS NOT NULL
          AND upper(c5_end) NOT LIKE '%PEDIDO%'
          AND upper(c5_end) NOT LIKE '%ORDEM DE COMPRA%'
          AND upper(c5_end) NOT LIKE '%OC %'
          AND length(btrim(c5_end)) >= 8
        THEN btrim(c5_end)
        ELSE NULL
      END
    ) AS endereco,
    COALESCE(NULLIF(btrim(le_cep),''), NULLIF(btrim(c5_cep),'')) AS cep,
    COALESCE(NULLIF(btrim(le_mun),''), NULLIF(btrim(c5_mun),'')) AS municipio,
    COALESCE(NULLIF(btrim(le_uf),''),  NULLIF(btrim(c5_uf),''))  AS uf
  FROM parsed
)
SELECT
  COALESCE(o.cliente_codigo, sc5.cliente_codigo) AS cliente_codigo,
  COALESCE(NULLIF(btrim(o.endereco),''),  sc5.endereco)  AS endereco,
  COALESCE(NULLIF(btrim(o.cep),''),       sc5.cep)       AS cep,
  COALESCE(NULLIF(btrim(o.municipio),''), sc5.municipio) AS municipio,
  COALESCE(NULLIF(btrim(o.uf),''),        sc5.uf)        AS uf,
  o.contato_nome,
  o.contato_tel,
  o.contato_whats,
  o.contato_email,
  o.lifecycle_status,
  CASE WHEN o.cliente_codigo IS NOT NULL THEN 'override'
       WHEN sc5.endereco IS NOT NULL OR sc5.municipio IS NOT NULL THEN 'sc5010_le'
       ELSE NULL END AS endereco_source
FROM sc5
FULL OUTER JOIN castor_client_address_override o
  ON o.cliente_codigo = sc5.cliente_codigo;

-- ============================================================
-- 3) Recria castor_client_metrics_v2 (foi removida pelo CASCADE)
--    Reaproveita exatamente a definição de 015_interactions_and_override.sql.
-- ============================================================
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

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('028_address_parse_le') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

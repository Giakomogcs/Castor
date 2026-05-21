// Adiciona 4 tools no Castor-Agent-IA.json (Fase 4 das interactions).
// Idempotente: pula se já existir node com o mesmo nome.
const fs = require('fs');
const path = require('path');
const WF_PATH = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Agent-IA.json');
const wf = JSON.parse(fs.readFileSync(WF_PATH, 'utf8'));

const PG_CRED = { id: 'jFjeYH6Nt3aRNkoM', name: 'Supabase_database' };
const X = 19808; // mesma coluna das ferramentas de subflow inferiores
let Y = 13136;   // abaixo da linha existente (12944)

function makeTool(name, description, query, replacement) {
  return {
    parameters: {
      descriptionType: 'manual',
      toolDescription: description,
      operation: 'executeQuery',
      query,
      options: { queryReplacement: replacement }
    },
    type: 'n8n-nodes-base.postgresTool',
    typeVersion: 2.5,
    position: [X, Y],
    id: name + '-id-0000',
    name,
    credentials: { postgres: PG_CRED }
  };
}

const tools = [
  {
    name: 'get_pending_followups',
    description: `Lista clientes com FOLLOW-UP agendado (próximo contato registrado) — vencidos, de hoje e da janela futura indicada. Já respeita o scope do vendedor (admin vê tudo; vendedor vê apenas o que ele mesmo agendou). USE WHEN o usuário pergunta 'o que tenho pra hoje', 'quem está atrasado', 'agenda da semana', 'follow-ups vencidos', 'meus contatos pendentes'.

Parâmetros (passe como JSON string em "$1"):
{"user_id":"<UUID>","days_ahead":7,"limit":50}

- user_id: obrigatório (do CONTEXTO DO USUÁRIO).
- days_ahead: 0 = só vencidos+hoje; 7 padrão; máx 365.
- limit: 1-500 (default 50).

Devolve: cliente_codigo, cliente_nome, municipio/uf, contato_tel/whats/email, next_contact_at, dias_para (negativo = atrasado), last_outcome, last_type, last_notes.`,
    query: `WITH p AS (SELECT $1::jsonb AS body)
SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) AS result
  FROM p, castor_client_pending_followups(
    (p.body->>'user_id')::uuid,
    COALESCE(NULLIF(p.body->>'days_ahead','')::int, 7),
    COALESCE(NULLIF(p.body->>'limit','')::int, 50)
  ) t;`,
    replacement: "={{ $fromAI('input', 'JSON string com {user_id, days_ahead?, limit?}.', 'string') }}"
  },
  {
    name: 'get_client_interactions',
    description: `Lista o HISTÓRICO COMPLETO de interações de um cliente (visitas, telefonemas, whatsapp, e-mails, reuniões), em ordem cronológica decrescente. Já respeita scope (vendedor só vê suas próprias; admin vê tudo). USE WHEN 'histórico do cliente X', 'todas as visitas e contatos com Y', 'o que rolou com Z nas últimas semanas'.

Parâmetros (JSON string em "$1"):
{"user_id":"<UUID>","cliente_codigo":"<A1_COD||A1_LOJA>","limit":30}

Devolve para cada interação: id, occurred_at, interaction_type (visita_presencial|telefone|whatsapp|email|reuniao_online|outro), outcome (visitou|sem_contato|aguardando_resposta|pedido_em_negociacao|convertido|voltar_depois|negativo|nao_existe_mais|nao_interessado_permanente|null), notes, next_contact_at, next_action, vendedor_nome.`,
    query: `WITH p AS (SELECT $1::jsonb AS body)
SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) AS result
  FROM p, castor_client_interaction_list(
    (p.body->>'user_id')::uuid,
    (p.body->>'cliente_codigo'),
    COALESCE(NULLIF(p.body->>'limit','')::int, 30)
  ) t;`,
    replacement: "={{ $fromAI('input', 'JSON string com {user_id, cliente_codigo, limit?}.', 'string') }}"
  },
  {
    name: 'schedule_next_contact',
    description: `Registra uma INTERAÇÃO com um cliente (visita, ligação, whatsapp, e-mail, reunião) e/ou AGENDA o próximo contato. USE WHEN o usuário diz 'liguei pro cliente X, ele pediu pra voltar dia 20/06', 'mandei whatsapp pro Y, sem resposta, vou tentar de novo em 7 dias', 'agenda visita pro Z daqui 30 dias'.

Parâmetros (JSON string em "$1"):
{
  "user_id":"<UUID obrigatório>",
  "cliente_codigo":"<obrigatório>",
  "interaction_type":"visita_presencial|telefone|whatsapp|email|reuniao_online|outro",
  "outcome":"visitou|sem_contato|aguardando_resposta|pedido_em_negociacao|convertido|voltar_depois|negativo|nao_existe_mais|nao_interessado_permanente" (opcional),
  "notes":"texto livre" (opcional),
  "next_contact_at":"YYYY-MM-DD" (opcional — data específica),
  "next_days": 7 (opcional — fallback se next_contact_at vazio),
  "next_action":"o que fazer no próximo contato" (opcional),
  "idempotency_key":"UUID v4 novo" (recomendado para evitar duplicidade)
}

Outcomes "convertido", "nao_existe_mais" e "nao_interessado_permanente" cancelam o próximo contato automaticamente. Os dois últimos também marcam o cliente como inativo permanente.`,
    query: `WITH p AS (SELECT $1::jsonb AS body)
SELECT castor_client_interaction_add(
  (p.body->>'user_id')::uuid,
  (p.body->>'cliente_codigo'),
  (p.body->>'interaction_type'),
  NULLIF(p.body->>'outcome',''),
  NULLIF(p.body->>'notes',''),
  NULLIF(p.body->>'next_contact_at','')::date,
  NULLIF(p.body->>'next_days','')::int,
  NULLIF(p.body->>'next_action',''),
  NULLIF(p.body->>'route_id','')::uuid,
  NULLIF(p.body->>'idempotency_key','')
) AS result FROM p;`,
    replacement: "={{ $fromAI('input', 'JSON string com {user_id, cliente_codigo, interaction_type, outcome?, notes?, next_contact_at?, next_days?, next_action?, idempotency_key?}.', 'string') }}"
  },
  {
    name: 'get_recent_data_changes',
    description: `Lista clientes cujas MÉTRICAS foram atualizadas recentemente (após nova ingestão de SF2010 / SC5010 via /castor-source-*). Use para narrar ao vendedor o que mudou desde a última conversa: faturamento subiu, status mudou, voltou a ter pedido, etc. USE WHEN 'o que mudou hoje', 'tem novidade?', 'algum cliente meu ficou ativo de novo?', 'rodou ingest, me dá o resumo'.

Parâmetros (JSON string em "$1"):
{"user_id":"<UUID>","since_hours":48,"limit":30}

since_hours = janela de horas desde computed_at (default 48). Devolve cliente_codigo, cliente_nome, ultima_atividade, faturamento_alltime, status_real (ATIVO|EM_RISCO|REATIVAR|INATIVO|DORMENTE|SEM_HISTORICO|ENCERRADO|NAO_INTERESSADO), changed_at.

NÃO INVENTE variações: só comente os campos que vieram. Se a lista estiver vazia, diga 'nenhuma atualização nas últimas X horas'.`,
    query: `WITH p AS (SELECT $1::jsonb AS body)
SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) AS result
  FROM p, castor_client_recent_changes(
    (p.body->>'user_id')::uuid,
    COALESCE(NULLIF(p.body->>'since_hours','')::int, 48),
    COALESCE(NULLIF(p.body->>'limit','')::int, 30)
  ) t;`,
    replacement: "={{ $fromAI('input', 'JSON string com {user_id, since_hours?, limit?}.', 'string') }}"
  }
];

let added = 0;
for (const t of tools) {
  if (wf.nodes.some(n => n.name === t.name)) {
    console.log('SKIP (exists):', t.name);
    continue;
  }
  const node = makeTool(t.name, t.description, t.query, t.replacement);
  wf.nodes.push(node);
  wf.connections[t.name] = { ai_tool: [[{ node: 'RAG AI Agent', type: 'ai_tool', index: 0 }]] };
  Y += 160;
  added++;
  console.log('ADDED:', t.name);
}

// Atualiza systemMessage do RAG AI Agent: adiciona seção das 4 novas tools.
const agent = wf.nodes.find(n => n.name === 'RAG AI Agent');
if (agent && agent.parameters && agent.parameters.options) {
  const sm = agent.parameters.options.systemMessage || '';
  const MARKER = '## FERRAMENTAS NOVAS — INTERAÇÕES & FOLLOW-UPS';
  if (!sm.includes(MARKER)) {
    const block = `\n\n=============================================\n${MARKER}\n\n11. **get_pending_followups** — clientes com próximo contato vencido + janela à frente. USE WHEN o usuário pergunta o que precisa fazer hoje/essa semana, quem está atrasado, follow-ups pendentes. NUNCA mostre follow-ups de outro vendedor — a tool já filtra; mas você NÃO deve mencionar agenda alheia mesmo que tenha visto via admin (privacidade).\n12. **get_client_interactions** — histórico cronológico de interações de UM cliente (visitas, telefonemas, whatsapp, e-mails). USE para responder \"o que rolou com o cliente X nos últimos meses\". Antes de chamar, peça o cliente_codigo se o usuário só deu nome.\n13. **schedule_next_contact** — registra interação E/OU agenda próximo contato. Use sempre que o usuário relatar contato (\"liguei\", \"mandei whats\", \"fui visitar\"). Inferir interaction_type (visita_presencial/telefone/whatsapp/email/reuniao_online). Se ele disse \"volto em N dias\" use next_days; se ele deu data, use next_contact_at (YYYY-MM-DD). SEMPRE gere idempotency_key UUID v4 novo. Confirme com \"✅ Interação registrada. Próximo contato: DD/MM/AAAA — <next_action>\".\n14. **get_recent_data_changes** — clientes com métricas atualizadas após ingestão recente de CSV (SF2010/SC5010). USE no início de sessão se o usuário perguntar \"o que tem de novo\", \"rodou ingest\", \"algum cliente meu voltou a comprar\". Comente apenas os campos retornados (status, faturamento_alltime, ultima_atividade). Se vazio: \"nenhuma atualização nas últimas X horas\".\n\nREGRA DE PRIVACIDADE: agenda/roteiros/interações de OUTRO vendedor são confidenciais. Mesmo papel=admin, NÃO compare nem narre a agenda de vendedor B para vendedor A. Se o usuário admin pedir \"como está o pipeline do vendedor X\", responda apenas em agregados (totais, médias), nunca nomes de clientes individuais agendados.\n\nINTERACTION TYPES e OUTCOMES (novos):\n- types: visita_presencial | telefone | whatsapp | email | reuniao_online | outro\n- outcomes: visitou | sem_contato | aguardando_resposta | pedido_em_negociacao | convertido | voltar_depois | negativo | nao_existe_mais | nao_interessado_permanente\n- \"nao_existe_mais\" e \"nao_interessado_permanente\" encerram o cliente (não voltam para fila de reativação).\n`;
    agent.parameters.options.systemMessage = sm + block;
    console.log('UPDATED: systemMessage with new tools section');
  } else {
    console.log('SKIP: systemMessage already has marker');
  }
}

fs.writeFileSync(WF_PATH, JSON.stringify(wf, null, 2));
console.log(`\nDone. added=${added}, total nodes=${wf.nodes.length}`);

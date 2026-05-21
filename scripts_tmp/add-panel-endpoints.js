// Adiciona endpoints novos ao Castor-Panel-API.json (fase 2 das interactions).
// Idempotente: se webhook path já existe, NÃO duplica.
const fs = require('fs');
const path = require('path');
const WF_PATH = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Panel-API.json');
const wf = JSON.parse(fs.readFileSync(WF_PATH, 'utf8'));

const PG_CRED = { id: 'jFjeYH6Nt3aRNkoM', name: 'Supabase_database' };
const CORS = { entries: [{ name: 'Access-Control-Allow-Origin', value: '*' }] };

function uid(prefix, n) { return `${prefix}-0000-0000-0000-${String(n).padStart(12, '0')}`; }

// --- 1) Atualizar Validate Update + PG: update stop para suportar campos novos ---
const validateUpdate = wf.nodes.find(n => n.name === 'Validate Update');
if (validateUpdate) {
  validateUpdate.parameters.jsCode = `const body = $json.body || $json;
const ALLOWED_OUTCOMES = ['visitou','sem_contato','convertido','voltar_depois','negativo','aguardando_resposta','pedido_em_negociacao','nao_existe_mais','nao_interessado_permanente'];
const ALLOWED_TYPES = ['visita_presencial','telefone','whatsapp','email','reuniao_online','outro'];
const out = {
  user_id: String(body.user_id || ''),
  route_id: String(body.route_id || ''),
  cliente_codigo: String(body.cliente_codigo || '').trim(),
  outcome: body.outcome ? String(body.outcome).trim() : null,
  notes: body.notes ? String(body.notes) : null,
  custom_days: (body.custom_days !== undefined && body.custom_days !== null && body.custom_days !== '') ? +body.custom_days : null,
  interaction_type: body.interaction_type ? String(body.interaction_type).trim() : null,
  next_contact_at: body.next_contact_at ? String(body.next_contact_at).trim() : null,
  next_action: body.next_action ? String(body.next_action) : null
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
if (!out.route_id) return [{ json: { ok:false, error:'route_id obrigatorio' } }];
if (!out.cliente_codigo) return [{ json: { ok:false, error:'cliente_codigo obrigatorio' } }];
if (out.outcome !== null && !ALLOWED_OUTCOMES.includes(out.outcome)) return [{ json: { ok:false, error:'outcome invalido' } }];
if (out.interaction_type !== null && !ALLOWED_TYPES.includes(out.interaction_type)) return [{ json: { ok:false, error:'interaction_type invalido' } }];
if (out.next_contact_at !== null && !/^\\d{4}-\\d{2}-\\d{2}$/.test(out.next_contact_at)) return [{ json: { ok:false, error:'next_contact_at deve ser YYYY-MM-DD' } }];
return [{ json: Object.assign({ ok:true }, out) }];`;
}

const pgUpdateStop = wf.nodes.find(n => n.name === 'PG: update stop');
if (pgUpdateStop) {
  pgUpdateStop.parameters.query = `SELECT to_jsonb(castor_route_update_stop(
  '{{ $json.user_id }}'::uuid,
  '{{ $json.route_id }}'::uuid,
  '{{ $json.cliente_codigo.replace(/'/g, "''") }}',
  {{ $json.outcome ? "'" + $json.outcome + "'" : 'NULL' }},
  {{ $json.notes ? "'" + $json.notes.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.custom_days === null ? 'NULL' : $json.custom_days }},
  {{ $json.interaction_type ? "'" + $json.interaction_type + "'" : 'NULL' }},
  {{ $json.next_contact_at ? "'" + $json.next_contact_at + "'::date" : 'NULL' }},
  {{ $json.next_action ? "'" + $json.next_action.replace(/'/g, "''") + "'" : 'NULL' }}
)) AS row;`;
}

// --- 2) Definição dos novos endpoints ---
const endpoints = [
  {
    key: 'addr-override',
    idPrefix: 'aov0',
    path: 'castor-panel-address-override',
    yBase: 2500,
    validate: `const body = $json.body || $json;
const out = {
  user_id: String(body.user_id || ''),
  cliente_codigo: String(body.cliente_codigo || '').trim(),
  endereco: body.endereco ? String(body.endereco) : null,
  cep: body.cep ? String(body.cep) : null,
  municipio: body.municipio ? String(body.municipio) : null,
  uf: body.uf ? String(body.uf) : null,
  contato_nome: body.contato_nome ? String(body.contato_nome) : null,
  contato_tel: body.contato_tel ? String(body.contato_tel) : null,
  contato_email: body.contato_email ? String(body.contato_email) : null,
  contato_whats: body.contato_whats ? String(body.contato_whats) : null,
  notes: body.notes ? String(body.notes) : null,
  lifecycle: body.lifecycle ? String(body.lifecycle) : null
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
if (!out.cliente_codigo) return [{ json: { ok:false, error:'cliente_codigo obrigatorio' } }];
if (out.lifecycle && !['ativo','encerrado','nao_interessado_permanente'].includes(out.lifecycle)) return [{ json: { ok:false, error:'lifecycle invalido' } }];
return [{ json: Object.assign({ ok:true }, out) }];`,
    query: `SELECT castor_client_address_override_set(
  '{{ $json.user_id }}'::uuid,
  '{{ $json.cliente_codigo.replace(/'/g, "''") }}',
  {{ $json.endereco ? "'" + $json.endereco.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.cep ? "'" + $json.cep.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.municipio ? "'" + $json.municipio.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.uf ? "'" + $json.uf.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.contato_nome ? "'" + $json.contato_nome.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.contato_tel ? "'" + $json.contato_tel.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.contato_email ? "'" + $json.contato_email.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.contato_whats ? "'" + $json.contato_whats.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.notes ? "'" + $json.notes.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.lifecycle ? "'" + $json.lifecycle + "'" : 'NULL' }}
) AS row;`
  },
  {
    key: 'client-status',
    idPrefix: 'cst0',
    path: 'castor-panel-client-status',
    yBase: 2800,
    validate: `const body = $json.body || $json;
const out = {
  user_id: String(body.user_id || ''),
  cliente_codigo: String(body.cliente_codigo || '').trim(),
  lifecycle: String(body.lifecycle || '').trim(),
  notes: body.notes ? String(body.notes) : null
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
if (!out.cliente_codigo) return [{ json: { ok:false, error:'cliente_codigo obrigatorio' } }];
if (!['ativo','encerrado','nao_interessado_permanente'].includes(out.lifecycle)) return [{ json: { ok:false, error:'lifecycle invalido' } }];
return [{ json: Object.assign({ ok:true }, out) }];`,
    query: `SELECT castor_client_status_set(
  '{{ $json.user_id }}'::uuid,
  '{{ $json.cliente_codigo.replace(/'/g, "''") }}',
  '{{ $json.lifecycle }}',
  {{ $json.notes ? "'" + $json.notes.replace(/'/g, "''") + "'" : 'NULL' }}
) AS row;`
  },
  {
    key: 'interaction-add',
    idPrefix: 'iad0',
    path: 'castor-panel-interaction-add',
    yBase: 3100,
    validate: `const body = $json.body || $json;
const ALLOWED_OUTCOMES = ['visitou','sem_contato','convertido','voltar_depois','negativo','aguardando_resposta','pedido_em_negociacao','nao_existe_mais','nao_interessado_permanente'];
const ALLOWED_TYPES = ['visita_presencial','telefone','whatsapp','email','reuniao_online','outro'];
const out = {
  user_id: String(body.user_id || ''),
  cliente_codigo: String(body.cliente_codigo || '').trim(),
  interaction_type: String(body.interaction_type || '').trim(),
  outcome: body.outcome ? String(body.outcome).trim() : null,
  notes: body.notes ? String(body.notes) : null,
  next_contact_at: body.next_contact_at ? String(body.next_contact_at).trim() : null,
  next_days: (body.next_days !== undefined && body.next_days !== null && body.next_days !== '') ? +body.next_days : null,
  next_action: body.next_action ? String(body.next_action) : null,
  route_id: body.route_id ? String(body.route_id) : null,
  idempotency_key: body.idempotency_key ? String(body.idempotency_key) : null
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
if (!out.cliente_codigo) return [{ json: { ok:false, error:'cliente_codigo obrigatorio' } }];
if (!ALLOWED_TYPES.includes(out.interaction_type)) return [{ json: { ok:false, error:'interaction_type invalido' } }];
if (out.outcome !== null && !ALLOWED_OUTCOMES.includes(out.outcome)) return [{ json: { ok:false, error:'outcome invalido' } }];
if (out.next_contact_at !== null && !/^\\d{4}-\\d{2}-\\d{2}$/.test(out.next_contact_at)) return [{ json: { ok:false, error:'next_contact_at deve ser YYYY-MM-DD' } }];
return [{ json: Object.assign({ ok:true }, out) }];`,
    query: `SELECT castor_client_interaction_add(
  '{{ $json.user_id }}'::uuid,
  '{{ $json.cliente_codigo.replace(/'/g, "''") }}',
  '{{ $json.interaction_type }}',
  {{ $json.outcome ? "'" + $json.outcome + "'" : 'NULL' }},
  {{ $json.notes ? "'" + $json.notes.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.next_contact_at ? "'" + $json.next_contact_at + "'::date" : 'NULL' }},
  {{ $json.next_days === null ? 'NULL' : $json.next_days }},
  {{ $json.next_action ? "'" + $json.next_action.replace(/'/g, "''") + "'" : 'NULL' }},
  {{ $json.route_id ? "'" + $json.route_id + "'::uuid" : 'NULL' }},
  {{ $json.idempotency_key ? "'" + $json.idempotency_key.replace(/'/g, "''") + "'" : 'NULL' }}
) AS row;`
  },
  {
    key: 'interaction-list',
    idPrefix: 'ils0',
    path: 'castor-panel-interaction-list',
    yBase: 3400,
    validate: `const body = $json.body || $json;
const out = {
  user_id: String(body.user_id || ''),
  cliente_codigo: String(body.cliente_codigo || '').trim(),
  limit: (body.limit !== undefined && body.limit !== null && body.limit !== '') ? +body.limit : 50
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
if (!out.cliente_codigo) return [{ json: { ok:false, error:'cliente_codigo obrigatorio' } }];
return [{ json: Object.assign({ ok:true }, out) }];`,
    query: `SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) AS row FROM castor_client_interaction_list(
  '{{ $json.user_id }}'::uuid,
  '{{ $json.cliente_codigo.replace(/'/g, "''") }}',
  {{ $json.limit }}
) t;`
  },
  {
    key: 'pending-followups',
    idPrefix: 'pfu0',
    path: 'castor-panel-pending-followups',
    yBase: 3700,
    validate: `const body = $json.body || $json;
const out = {
  user_id: String(body.user_id || ''),
  days_ahead: (body.days_ahead !== undefined && body.days_ahead !== null && body.days_ahead !== '') ? +body.days_ahead : 7,
  limit: (body.limit !== undefined && body.limit !== null && body.limit !== '') ? +body.limit : 100
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
return [{ json: Object.assign({ ok:true }, out) }];`,
    query: `SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) AS row FROM castor_client_pending_followups(
  '{{ $json.user_id }}'::uuid,
  {{ $json.days_ahead }},
  {{ $json.limit }}
) t;`
  },
  {
    key: 'recent-changes',
    idPrefix: 'rch0',
    path: 'castor-panel-recent-changes',
    yBase: 4000,
    validate: `const body = $json.body || $json;
const out = {
  user_id: String(body.user_id || ''),
  since_hours: (body.since_hours !== undefined && body.since_hours !== null && body.since_hours !== '') ? +body.since_hours : 48,
  limit: (body.limit !== undefined && body.limit !== null && body.limit !== '') ? +body.limit : 30
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
return [{ json: Object.assign({ ok:true }, out) }];`,
    query: `SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) AS row FROM castor_client_recent_changes(
  '{{ $json.user_id }}'::uuid,
  {{ $json.since_hours }},
  {{ $json.limit }}
) t;`
  }
];

let added = 0;
for (const ep of endpoints) {
  // skip if path already exists
  const exists = wf.nodes.some(n => n.type === 'n8n-nodes-base.webhook' && n.parameters && n.parameters.path === ep.path);
  if (exists) { console.log(`SKIP (exists): ${ep.path}`); continue; }

  const xCol = [0, 220, 440, 660, 880, 1100];
  const y = ep.yBase;

  const nWebhook = {
    parameters: { httpMethod: 'POST', path: ep.path, responseMode: 'responseNode', options: {} },
    id: uid(ep.idPrefix, 10), name: `Webhook - ${ep.key}`,
    type: 'n8n-nodes-base.webhook', typeVersion: 2.1, position: [xCol[0], y]
  };
  const nValidate = {
    parameters: { jsCode: ep.validate },
    id: uid(ep.idPrefix, 20), name: `Validate ${ep.key}`,
    type: 'n8n-nodes-base.code', typeVersion: 2, position: [xCol[1], y]
  };
  const nIf = {
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{
          id: ep.idPrefix + 'c1',
          leftValue: '={{ $json.ok }}',
          rightValue: true,
          operator: { type: 'boolean', operation: 'true', singleValue: true }
        }],
        combinator: 'and'
      },
      options: {}
    },
    id: uid(ep.idPrefix, 30), name: `${ep.key} valid?`,
    type: 'n8n-nodes-base.if', typeVersion: 2.3, position: [xCol[2], y]
  };
  const nPg = {
    parameters: { operation: 'executeQuery', query: ep.query, options: {} },
    id: uid(ep.idPrefix, 40), name: `PG: ${ep.key}`,
    type: 'n8n-nodes-base.postgres', typeVersion: 2.6, position: [xCol[3], y - 80],
    credentials: { postgres: PG_CRED }
  };
  const nWrap = {
    parameters: {
      jsCode: `const r = $input.first().json && ($input.first().json.row !== undefined ? $input.first().json.row : $input.first().json);
return [{ json: { ok:true, data:r, error:null } }];`
    },
    id: uid(ep.idPrefix, 50), name: `Wrap ${ep.key}`,
    type: 'n8n-nodes-base.code', typeVersion: 2, position: [xCol[4], y - 80]
  };
  const nOk = {
    parameters: {
      respondWith: 'json', responseBody: '={{ $json }}',
      options: { responseHeaders: CORS }
    },
    id: uid(ep.idPrefix, 60), name: `Respond ${ep.key} OK`,
    type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [xCol[5], y - 80]
  };
  const nErr = {
    parameters: {
      respondWith: 'json',
      responseBody: "={{ { ok:false, data:null, error: $json.error || 'invalid input' } }}",
      options: { responseCode: 400, responseHeaders: CORS }
    },
    id: uid(ep.idPrefix, 70), name: `Respond ${ep.key} Error`,
    type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [xCol[3], y + 140]
  };

  wf.nodes.push(nWebhook, nValidate, nIf, nPg, nWrap, nOk, nErr);

  wf.connections[nWebhook.name]  = { main: [[{ node: nValidate.name, type: 'main', index: 0 }]] };
  wf.connections[nValidate.name] = { main: [[{ node: nIf.name, type: 'main', index: 0 }]] };
  wf.connections[nIf.name]       = {
    main: [
      [{ node: nPg.name,  type: 'main', index: 0 }],
      [{ node: nErr.name, type: 'main', index: 0 }]
    ]
  };
  wf.connections[nPg.name]   = { main: [[{ node: nWrap.name, type: 'main', index: 0 }]] };
  wf.connections[nWrap.name] = { main: [[{ node: nOk.name,   type: 'main', index: 0 }]] };

  added++;
  console.log(`ADDED: ${ep.path}`);
}

fs.writeFileSync(WF_PATH, JSON.stringify(wf, null, 2));
console.log(`\nDone. added=${added}, total nodes=${wf.nodes.length}`);

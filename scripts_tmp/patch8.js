// Fix: change inputSource jsonSchema -> jsonExample in sub-workflow + add exclude_codes plumbing to Panel-API
const fs = require('fs');

// ---------- 1) Auto Route Builder sub-workflow ----------
const subPath = 'castor-agent/workspaces/[Castor] Sub-fluxo_ Auto Route Builder.json';
const sub = JSON.parse(fs.readFileSync(subPath, 'utf8'));
const trig = sub.nodes.find(n => n.name === 'When called');
if (!trig) throw new Error('trigger not found');
const example = {
  user_id: '',
  mode: 'reactivation',
  uf: '',
  cidade: '',
  max_stops: 8,
  origin_lat: -23.6884,
  origin_lng: -46.6178,
  name: '',
  exclude_codes: []
};
trig.parameters = {
  inputSource: 'jsonExample',
  jsonExample: JSON.stringify(example, null, 2)
};
fs.writeFileSync(subPath, JSON.stringify(sub, null, 2), 'utf8');
console.log('OK sub-workflow trigger updated');

// ---------- 2) Panel-API ----------
const apiPath = 'castor-agent/workspaces/Castor-Panel-API.json';
const api = JSON.parse(fs.readFileSync(apiPath, 'utf8'));

const val = api.nodes.find(n => n.name === 'Validate AI Route');
if (!val) throw new Error('Validate AI Route not found');
val.parameters.jsCode =
`const body = $json.body || $json;
let exclude_codes = [];
try {
  const raw = body.exclude_codes;
  const arr = Array.isArray(raw) ? raw : (typeof raw === 'string' ? JSON.parse(raw || '[]') : []);
  exclude_codes = (arr || []).map(c => String(c).trim()).filter(Boolean).slice(0, 200);
} catch (e) { exclude_codes = []; }
const out = {
  user_id: String(body.user_id || ''),
  mode: ['reactivation','mixed'].includes(body.mode) ? body.mode : 'reactivation',
  uf: body.uf ? String(body.uf).toUpperCase().slice(0,2) : null,
  cidade: body.cidade ? String(body.cidade) : null,
  max_stops: (Number.isFinite(+body.max_stops) && +body.max_stops > 0) ? Math.min(20, +body.max_stops) : 8,
  origin_lat: Number.isFinite(+body.origin_lat) ? +body.origin_lat : null,
  origin_lng: Number.isFinite(+body.origin_lng) ? +body.origin_lng : null,
  name: body.name ? String(body.name) : null,
  exclude_codes
};
if (!out.user_id) return [{ json: { ok:false, error:'user_id obrigatorio' } }];
return [{ json: Object.assign({ ok:true }, out) }];`;
console.log('OK Validate AI Route patched');

const exec = api.nodes.find(n => n.name === 'Execute Auto Route Builder');
if (!exec) throw new Error('Execute Auto Route Builder not found');
exec.parameters.workflowInputs.value.exclude_codes = '={{ $json.exclude_codes }}';
if (!exec.parameters.workflowInputs.schema.some(s => s.id === 'exclude_codes')) {
  exec.parameters.workflowInputs.schema.push({
    id: 'exclude_codes',
    displayName: 'exclude_codes',
    required: false,
    type: 'array',
    display: true
  });
}
console.log('OK Execute Auto Route Builder updated');

fs.writeFileSync(apiPath, JSON.stringify(api, null, 2), 'utf8');
console.log('OK Panel-API saved');

// Sanity parse
JSON.parse(fs.readFileSync(subPath, 'utf8'));
JSON.parse(fs.readFileSync(apiPath, 'utf8'));
console.log('both parse OK');

// Fase 5: insere "Notify cache purge" no Source-Manager entre PG: finish e Respond Finish.
// Faz POST fire-and-forget para /castor-panel-cache-purge. Idempotente.
const fs = require('fs');
const path = require('path');
const WF_PATH = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Source-Manager.json');
const wf = JSON.parse(fs.readFileSync(WF_PATH, 'utf8'));

const NODE_NAME = 'Notify cache purge';
if (wf.nodes.some(n => n.name === NODE_NAME)) {
  console.log('SKIP (exists):', NODE_NAME);
  process.exit(0);
}

// Descobre URL base do webhook castor-panel-cache-purge inspecionando o Panel-API export.
// Como não podemos hardcodar host, usamos o helper $env.WEBHOOK_URL do n8n.
// Em produção, ajustar no node via UI se necessário.

const httpNode = {
  parameters: {
    method: 'POST',
    url: "={{ $env.N8N_WEBHOOK_BASE ? $env.N8N_WEBHOOK_BASE.replace(/\\/$/,'') + '/webhook/castor-panel-cache-purge' : 'http://localhost:5678/webhook/castor-panel-cache-purge' }}",
    sendBody: true,
    bodyParameters: {
      parameters: [
        { name: 'reason', value: '=ingest:{{ $json.table || "unknown" }}' },
        { name: 'ingest_id', value: '={{ $json.ingest_id || "" }}' }
      ]
    },
    options: {
      timeout: 3000,
      response: { response: { neverError: true } }
    }
  },
  type: 'n8n-nodes-base.httpRequest',
  typeVersion: 4.2,
  position: [40128, 22900],
  id: 'c1b2c3d4-5555-4555-8555-555555555555',
  name: NODE_NAME,
  continueOnFail: true,
  alwaysOutputData: true
};

wf.nodes.push(httpNode);

// Redireciona PG: finish -> Notify cache purge -> Respond Finish
const oldConn = wf.connections['PG: finish'];
const respondTargets = (oldConn && oldConn.main && oldConn.main[0]) || [];
wf.connections['PG: finish'] = {
  main: [[{ node: NODE_NAME, type: 'main', index: 0 }]]
};
wf.connections[NODE_NAME] = {
  main: [respondTargets.length ? respondTargets : [{ node: 'Respond Finish', type: 'main', index: 0 }]]
};

fs.writeFileSync(WF_PATH, JSON.stringify(wf, null, 2));
console.log('ADDED:', NODE_NAME);
console.log('Redirected: PG: finish -> Notify cache purge -> Respond Finish');
console.log('NOTE: set env N8N_WEBHOOK_BASE on the n8n host (or edit the node URL) to point to the right webhook base.');

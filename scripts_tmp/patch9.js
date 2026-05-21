// Switch trigger to passthrough mode (safest; Validate node handles all sanitization)
const fs = require('fs');
const p = 'castor-agent/workspaces/[Castor] Sub-fluxo_ Auto Route Builder.json';
const w = JSON.parse(fs.readFileSync(p, 'utf8'));
const trig = w.nodes.find(n => n.name === 'When called');
trig.parameters = { inputSource: 'passthrough' };
fs.writeFileSync(p, JSON.stringify(w, null, 2), 'utf8');
console.log('OK passthrough set');
JSON.parse(fs.readFileSync(p, 'utf8'));
console.log('parse OK');

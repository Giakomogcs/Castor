const fs = require('fs');
const path = 'castor-agent/front-castor.html';
let s = fs.readFileSync(path, 'utf8');

const startNeedle = 'if (state.tab === "reactivation") return `Nenhum cliente';
const start = s.indexOf(startNeedle);
if (start < 0) { console.error('start not found'); process.exit(1); }
const endNeedle = '`Nenhum lead bate com o filtro atual';
const endIdx = s.indexOf(endNeedle, start);
if (endIdx < 0) { console.error('end not found'); process.exit(1); }
const closeIdx = s.indexOf('`;', endIdx) + 2;
const old = s.slice(start, closeIdx);

// Reuse the already-present text inside `old` to keep the special unicode chars intact.
// Just prepend the new "no scope" branch.
const prepend =
  'if (nc === 0 && (nl > 0 || nm > 0) && (state.tab === "reactivation" || state.tab === "active")) {\n' +
  '            return `Você não vê nenhum cliente nesta tab, mas a base já tem dados (${nl} leads · ${nm} municípios). Provavelmente seu <strong>território</strong> não está cadastrado no seu cadastro de usuário. Peça ao admin para abrir <em>Usuários → editar</em> e preencher os campos <code>estados</code> e <code>cidades</code> (ex.: <code>SP</code> e <code>Diadema</code>). Sem isso, só aparecem clientes do seu <code>vendor_code</code> do Protheus.`;\n' +
  '          }\n' +
  '          ';

if (s.includes('Você não vê nenhum cliente nesta tab')) {
  console.log('already patched');
  process.exit(0);
}

const out = s.slice(0, start) + prepend + s.slice(start);
fs.writeFileSync(path, out);
console.log('patched. old block length=', old.length, 'new size=', out.length);

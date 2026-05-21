const fs = require('fs');
const s = fs.readFileSync('castor-agent/front-castor.html','utf8');
const re = /<script(?:\s+[^>]*)?>([\s\S]*?)<\/script>/g;
let m, i = 0;
while ((m = re.exec(s))) {
  i++;
  const tag = m[0].slice(0, m[0].indexOf('>') + 1);
  if (/\bsrc=/.test(tag)) continue;
  const code = m[1];
  if (!code.trim()) continue;
  if (i !== 7) continue;
  try { new Function(code); }
  catch (e) {
    console.log('ERROR:', e.message);
    const lineMatch = e.message.match(/<anonymous>:(\d+)/);
    if (lineMatch) {
      const ln = +lineMatch[1] - 1;
      const lines = code.split('\n');
      for (let k = Math.max(0, ln - 5); k <= Math.min(lines.length - 1, ln + 5); k++) {
        console.log((k === ln ? '>> ' : '   ') + (k + 1) + ': ' + lines[k]);
      }
    }
  }
}

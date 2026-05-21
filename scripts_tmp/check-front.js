const s = require('fs').readFileSync('castor-agent/front-castor.html','utf8');
const re = /<script(?:\s+[^>]*)?>([\s\S]*?)<\/script>/g;
let m, i = 0, errs = 0;
while ((m = re.exec(s))) {
  i++;
  const tag = m[0].slice(0, m[0].indexOf('>') + 1);
  if (/\bsrc=/.test(tag)) continue;
  const code = m[1];
  if (!code.trim()) continue;
  try { new Function(code); }
  catch (e) {
    errs++;
    const before = s.slice(0, m.index);
    const startLine = before.split('\n').length;
    console.log('Block #' + i + ' (line ' + startLine + '): ' + e.message);
    const lineMatch = e.message.match(/<anonymous>:(\d+)/);
    if (lineMatch) {
      const lines = code.split('\n');
      const ln = +lineMatch[1] - 1;
      for (let k = Math.max(0, ln - 3); k <= Math.min(lines.length - 1, ln + 3); k++) {
        console.log((k === ln ? '>> ' : '   ') + (startLine + k - 1) + ': ' + lines[k]);
      }
    }
  }
}
console.log('total blocks:', i, 'errors:', errs);

const fs=require('fs');
const s=fs.readFileSync('castor-agent/front-castor.html','utf8');
// modal html
console.log('=== modal html @113552 ===');
console.log(s.substring(113552-100, 113552+3500));
console.log('\n\n=== openDetail @264112 ===');
console.log(s.substring(264112, 264112+5500));

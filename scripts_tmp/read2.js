const fs=require('fs');
const s=fs.readFileSync('castor-agent/front-castor.html','utf8');
console.log(s.substring(269600, 274500));

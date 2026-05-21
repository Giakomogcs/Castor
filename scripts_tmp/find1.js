const fs=require('fs');
const s=fs.readFileSync('castor-agent/front-castor.html','utf8');
function find(re){const r=new RegExp(re,'g');let m,o=[];while((m=r.exec(s))&&o.length<30)o.push(m.index);return o;}
console.log('openDetail def:',find('function openDetail').slice(0,5));
console.log('renderStops:',find('renderStops|renderStop\\b|stopsList|stopListEl').slice(0,15));
console.log('saveStop/outcome:',find('saveStop|updateStopOutcome|stopOutcome|outcome:\\s*outcome').slice(0,15));
console.log('savedRouteDetailModal html:',find('id="savedRouteDetailModal"').slice(0,5));
console.log('RoutesPanel def:',find('RoutesPanel\\s*=\\s*\\(').slice(0,3));

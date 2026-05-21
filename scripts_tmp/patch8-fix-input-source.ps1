$ErrorActionPreference = 'Stop'

# ---------- 1) Auto Route Builder sub-workflow: jsonSchema -> jsonExample ----------
$subPath = 'castor-agent\workspaces\[Castor] Sub-fluxo_ Auto Route Builder.json'
$sub = Get-Content $subPath -Raw | ConvertFrom-Json

$trig = $sub.nodes | Where-Object { $_.name -eq 'When called' }
if (-not $trig) { throw "trigger not found" }

# Remove old jsonSchema property and replace inputSource + add jsonExample
$exampleObj = [ordered]@{
  user_id      = ""
  mode         = "reactivation"
  uf           = ""
  cidade       = ""
  max_stops    = 8
  origin_lat   = -23.6884
  origin_lng   = -46.6178
  name         = ""
  exclude_codes = @()
}
$exampleStr = ($exampleObj | ConvertTo-Json -Depth 5 -Compress:$false)

$newParams = [ordered]@{
  inputSource = 'jsonExample'
  jsonExample = $exampleStr
}
$trig.parameters = [PSCustomObject]$newParams

$sub | ConvertTo-Json -Depth 100 | Set-Content $subPath -Encoding utf8
Write-Host "OK sub-workflow trigger updated"

# ---------- 2) Panel-API: add exclude_codes to Validate + executeWorkflow mapping ----------
$apiPath = 'castor-agent\workspaces\Castor-Panel-API.json'
$api = Get-Content $apiPath -Raw | ConvertFrom-Json

# 2a) Validate AI Route: include exclude_codes
$val = $api.nodes | Where-Object { $_.name -eq 'Validate AI Route' }
if (-not $val) { throw "Validate AI Route node not found" }
$newJs = @"
const body = `$json.body || `$json;
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
return [{ json: Object.assign({ ok:true }, out) }];
"@
$val.parameters.jsCode = $newJs
Write-Host "OK Validate AI Route patched"

# 2b) Execute Auto Route Builder: add exclude_codes mapping + schema entry
$exec = $api.nodes | Where-Object { $_.name -eq 'Execute Auto Route Builder' }
if (-not $exec) { throw "Execute Auto Route Builder not found" }

# Add to value
$exec.parameters.workflowInputs.value | Add-Member -NotePropertyName 'exclude_codes' -NotePropertyValue '={{ $json.exclude_codes }}' -Force

# Add to schema (array of objects)
$hasExcl = $false
foreach ($s in $exec.parameters.workflowInputs.schema) { if ($s.id -eq 'exclude_codes') { $hasExcl = $true } }
if (-not $hasExcl) {
  $newEntry = [PSCustomObject]@{
    id = 'exclude_codes'
    displayName = 'exclude_codes'
    required = $false
    type = 'array'
    display = $true
  }
  $exec.parameters.workflowInputs.schema = @($exec.parameters.workflowInputs.schema) + $newEntry
}
Write-Host "OK Execute Auto Route Builder mapping updated"

$api | ConvertTo-Json -Depth 100 | Set-Content $apiPath -Encoding utf8
Write-Host "OK Panel-API saved"

# Validate JSON parse
node -e "JSON.parse(require('fs').readFileSync('$($subPath.Replace('\','/'))','utf8')); console.log('sub-workflow ok')"
node -e "JSON.parse(require('fs').readFileSync('$($apiPath.Replace('\','/'))','utf8')); console.log('panel-api ok')"

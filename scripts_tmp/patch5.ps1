# Adds exclude_codes plumbing through Panel-API and Auto Route Builder.
$ErrorActionPreference = 'Stop'

$apiPath = 'castor-agent\workspaces\Castor-Panel-API.json'
$arbPath = 'castor-agent\workspaces\[Castor] Sub-fluxo_ Auto Route Builder.json'

# -------------------------- Panel-API --------------------------
$api = [System.IO.File]::ReadAllText($apiPath, [System.Text.Encoding]::UTF8)

# 1) Sanitize node for panel-ai-route (~line 911): include exclude_codes (array<string>).
$oldSan = "const out = {`n  user_id: String(body.user_id || ''),`n  mode: ['reactivation','mixed'].includes(body.mode) ? body.mode : 'reactivation',`n  uf: body.uf ? String(body.uf).toUpperCase().slice(0,2) : null,`n  cidade: body.cidade ? String(body.cidade) : null,`n  max_stops: (Number.isFinite(+body.max_stops) && +body.max_stops > 0) ? Math.min(20, +body.max_stops) : 8,`n  origin_lat: Number.isFinite(+body.origin_lat) ? +body.origin_lat : null,`n  origin_lng: Number.isFinite(+body.origin_lng) ? +body.origin_lng : null,`n  name: body.name ? String(body.name) : null`n};"
$newSan = "const out = {`n  user_id: String(body.user_id || ''),`n  mode: ['reactivation','mixed'].includes(body.mode) ? body.mode : 'reactivation',`n  uf: body.uf ? String(body.uf).toUpperCase().slice(0,2) : null,`n  cidade: body.cidade ? String(body.cidade) : null,`n  max_stops: (Number.isFinite(+body.max_stops) && +body.max_stops > 0) ? Math.min(20, +body.max_stops) : 8,`n  origin_lat: Number.isFinite(+body.origin_lat) ? +body.origin_lat : null,`n  origin_lng: Number.isFinite(+body.origin_lng) ? +body.origin_lng : null,`n  name: body.name ? String(body.name) : null,`n  exclude_codes: Array.isArray(body.exclude_codes) ? body.exclude_codes.map(c => String(c).trim()).filter(Boolean).slice(0, 200) : []`n};"
# JSON uses \n, not real LF. Convert.
$oldSanJ = $oldSan.Replace("`n","\n")
$newSanJ = $newSan.Replace("`n","\n")
if (-not $api.Contains($oldSanJ)) { Write-Error "panel-api sanitize needle not found"; exit 1 }
$api = $api.Replace($oldSanJ, $newSanJ)

# 2) Execute Auto Route Builder mapping: add exclude_codes input
$oldMap = '"name": "={{ $json.name }}"' + "`r`n          },`r`n          `"matchingColumns`": []"
$newMap = '"name": "={{ $json.name }}",' + "`r`n            `"exclude_codes`": `"={{ JSON.stringify($json.exclude_codes || []) }}`"" + "`r`n          },`r`n          `"matchingColumns`": []"
if (-not $api.Contains($oldMap)) { Write-Error "panel-api mapping needle not found"; exit 1 }
$cnt = ([regex]::Matches($api, [regex]::Escape($oldMap))).Count
if ($cnt -ne 1) { Write-Error "panel-api mapping not unique: $cnt"; exit 1 }
$api = $api.Replace($oldMap, $newMap)

# 3) Add schema entry for exclude_codes (after "name" entry).
$oldSchema = @'
            {
              "id": "name",
              "displayName": "name",
              "required": false,
              "type": "string",
              "display": true
            }
          ],
'@
$newSchema = @'
            {
              "id": "name",
              "displayName": "name",
              "required": false,
              "type": "string",
              "display": true
            },
            {
              "id": "exclude_codes",
              "displayName": "exclude_codes",
              "required": false,
              "type": "string",
              "display": true
            }
          ],
'@
$oldSchema = $oldSchema -replace "`r`n","`n" -replace "`n","`r`n"
$newSchema = $newSchema -replace "`r`n","`n" -replace "`n","`r`n"
$cnt = ([regex]::Matches($api, [regex]::Escape($oldSchema))).Count
if ($cnt -ne 1) { Write-Error "panel-api schema needle not unique: $cnt"; exit 1 }
$api = $api.Replace($oldSchema, $newSchema)

[System.IO.File]::WriteAllText($apiPath, $api, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "panel-api OK"

# -------------------------- Auto Route Builder --------------------------
$arb = [System.IO.File]::ReadAllText($arbPath, [System.Text.Encoding]::UTF8)

# 1) jsonSchema: add exclude_codes property.
$oldJsonSchema = '"name":{"type":"string","description":"nome opcional do roteiro salvo"}}}'
$newJsonSchema = '"name":{"type":"string","description":"nome opcional do roteiro salvo"},"exclude_codes":{"type":"array","items":{"type":"string"},"description":"lista de cliente_codigo a EXCLUIR da sugestão (já presentes em roteiros abertos do vendedor)"}}}'
if (-not $arb.Contains($oldJsonSchema)) { Write-Error "arb jsonSchema needle not found"; exit 1 }
$arb = $arb.Replace($oldJsonSchema, $newJsonSchema)

# 2) Validate node: parse and forward exclude_codes.
$oldVal = "const name = input.name ? String(input.name) : ('Roteiro IA ' + new Date().toLocaleDateString('pt-BR'));\nreturn [{ json: { ok:true, user_id, mode, uf, cid, max_stops, origin_lat, origin_lng, name } }];"
$newVal = "const name = input.name ? String(input.name) : ('Roteiro IA ' + new Date().toLocaleDateString('pt-BR'));\nlet exclude_codes = [];\ntry {\n  const raw = input.exclude_codes;\n  const arr = Array.isArray(raw) ? raw : (typeof raw === 'string' ? JSON.parse(raw || '[]') : []);\n  exclude_codes = (arr || []).map(c => String(c).trim()).filter(Boolean).slice(0, 200);\n} catch (e) { exclude_codes = []; }\nreturn [{ json: { ok:true, user_id, mode, uf, cid, max_stops, origin_lat, origin_lng, name, exclude_codes } }];"
if (-not $arb.Contains($oldVal)) { Write-Error "arb validate needle not found"; exit 1 }
$arb = $arb.Replace($oldVal, $newVal)

# 3) nearest-neighbor JS: filter rows by exclude_codes BEFORE selecting top max_stops.
# Find pattern: "const rows = ($input.first() && $input.first().json && $input.first().json.rows) || [];\nif (!rows.length) {"
$oldNN = "const rows = (\$input.first() && \$input.first().json && \$input.first().json.rows) || [];\nif (!rows.length) {"
$newNN = "let rows = (\$input.first() && \$input.first().json && \$input.first().json.rows) || [];\nconst _excl = new Set((ctx.exclude_codes || []).map(c => String(c)));\nif (_excl.size) {\n  rows = rows.filter(r => !_excl.has(String(r.cliente_codigo || r.code || '')));\n}\nif (!rows.length) {"
if (-not $arb.Contains($oldNN)) { Write-Error "arb nearest-neighbor needle not found"; exit 1 }
$arb = $arb.Replace($oldNN, $newNN)

[System.IO.File]::WriteAllText($arbPath, $arb, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "auto-route-builder OK"

# Validate JSON
$null = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($apiPath, [System.Text.Encoding]::UTF8))
$null = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($arbPath, [System.Text.Encoding]::UTF8))
Write-Host "JSON valid"

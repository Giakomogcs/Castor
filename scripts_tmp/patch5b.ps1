# Adds exclude_codes plumbing through Panel-API and Auto Route Builder.
# Both JSON files use LF (not CRLF), so all newline patterns here use \n.
$ErrorActionPreference = 'Stop'

function Apply-Replace {
    param([string]$Text, [string]$Old, [string]$New, [string]$Label, [int]$ExpectedCount = 1)
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne $ExpectedCount) {
        throw "[$Label] expected $ExpectedCount matches, found $count"
    }
    return $Text.Replace($Old, $New)
}

$apiPath = 'castor-agent\workspaces\Castor-Panel-API.json'
$arbPath = 'castor-agent\workspaces\[Castor] Sub-fluxo_ Auto Route Builder.json'

$LF = "`n"

# -------------------------- Panel-API --------------------------
$api = [System.IO.File]::ReadAllText($apiPath, [System.Text.Encoding]::UTF8)

# 1) Sanitize node: include exclude_codes (array<string>).
$oldSan = "const out = {\n  user_id: String(body.user_id || ''),\n  mode: ['reactivation','mixed'].includes(body.mode) ? body.mode : 'reactivation',\n  uf: body.uf ? String(body.uf).toUpperCase().slice(0,2) : null,\n  cidade: body.cidade ? String(body.cidade) : null,\n  max_stops: (Number.isFinite(+body.max_stops) && +body.max_stops > 0) ? Math.min(20, +body.max_stops) : 8,\n  origin_lat: Number.isFinite(+body.origin_lat) ? +body.origin_lat : null,\n  origin_lng: Number.isFinite(+body.origin_lng) ? +body.origin_lng : null,\n  name: body.name ? String(body.name) : null\n};"
$newSan = "const out = {\n  user_id: String(body.user_id || ''),\n  mode: ['reactivation','mixed'].includes(body.mode) ? body.mode : 'reactivation',\n  uf: body.uf ? String(body.uf).toUpperCase().slice(0,2) : null,\n  cidade: body.cidade ? String(body.cidade) : null,\n  max_stops: (Number.isFinite(+body.max_stops) && +body.max_stops > 0) ? Math.min(20, +body.max_stops) : 8,\n  origin_lat: Number.isFinite(+body.origin_lat) ? +body.origin_lat : null,\n  origin_lng: Number.isFinite(+body.origin_lng) ? +body.origin_lng : null,\n  name: body.name ? String(body.name) : null,\n  exclude_codes: Array.isArray(body.exclude_codes) ? body.exclude_codes.map(c => String(c).trim()).filter(Boolean).slice(0, 200) : []\n};"
$api = Apply-Replace -Text $api -Old $oldSan -New $newSan -Label 'panel-api/sanitize'

# 2) Execute Auto Route Builder mapping: add exclude_codes input
$oldMap = '"name": "={{ $json.name }}"' + $LF + '          },' + $LF + '          "matchingColumns": []'
$newMap = '"name": "={{ $json.name }}",' + $LF + '            "exclude_codes": "={{ JSON.stringify($json.exclude_codes || []) }}"' + $LF + '          },' + $LF + '          "matchingColumns": []'
$api = Apply-Replace -Text $api -Old $oldMap -New $newMap -Label 'panel-api/mapping'

# 3) Add schema entry for exclude_codes.
$oldSchema = '            {' + $LF + '              "id": "name",' + $LF + '              "displayName": "name",' + $LF + '              "required": false,' + $LF + '              "type": "string",' + $LF + '              "display": true' + $LF + '            }' + $LF + '          ],'
$newSchema = '            {' + $LF + '              "id": "name",' + $LF + '              "displayName": "name",' + $LF + '              "required": false,' + $LF + '              "type": "string",' + $LF + '              "display": true' + $LF + '            },' + $LF + '            {' + $LF + '              "id": "exclude_codes",' + $LF + '              "displayName": "exclude_codes",' + $LF + '              "required": false,' + $LF + '              "type": "string",' + $LF + '              "display": true' + $LF + '            }' + $LF + '          ],'
$api = Apply-Replace -Text $api -Old $oldSchema -New $newSchema -Label 'panel-api/schema'

[System.IO.File]::WriteAllText($apiPath, $api, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "panel-api OK"

# -------------------------- Auto Route Builder --------------------------
$arb = [System.IO.File]::ReadAllText($arbPath, [System.Text.Encoding]::UTF8)

# 1) jsonSchema: add exclude_codes property.
$oldJsonSchema = '"name":{"type":"string","description":"nome opcional do roteiro salvo"}}}'
$newJsonSchema = '"name":{"type":"string","description":"nome opcional do roteiro salvo"},"exclude_codes":{"type":"array","items":{"type":"string"},"description":"lista de cliente_codigo a EXCLUIR (já presentes em roteiros abertos do vendedor)"}}}'
$arb = Apply-Replace -Text $arb -Old $oldJsonSchema -New $newJsonSchema -Label 'arb/jsonSchema'

# 2) Validate node: parse and forward exclude_codes.
$oldVal = "const name = input.name ? String(input.name) : ('Roteiro IA ' + new Date().toLocaleDateString('pt-BR'));\nreturn [{ json: { ok:true, user_id, mode, uf, cid, max_stops, origin_lat, origin_lng, name } }];"
$newVal = "const name = input.name ? String(input.name) : ('Roteiro IA ' + new Date().toLocaleDateString('pt-BR'));\nlet exclude_codes = [];\ntry {\n  const raw = input.exclude_codes;\n  const arr = Array.isArray(raw) ? raw : (typeof raw === 'string' ? JSON.parse(raw || '[]') : []);\n  exclude_codes = (arr || []).map(c => String(c).trim()).filter(Boolean).slice(0, 200);\n} catch (e) { exclude_codes = []; }\nreturn [{ json: { ok:true, user_id, mode, uf, cid, max_stops, origin_lat, origin_lng, name, exclude_codes } }];"
$arb = Apply-Replace -Text $arb -Old $oldVal -New $newVal -Label 'arb/validate'

# 3) nearest-neighbor JS: filter rows by exclude_codes BEFORE selecting top max_stops.
$oldNN = "const rows = (`$input.first() && `$input.first().json && `$input.first().json.rows) || [];\nif (!rows.length) {"
$newNN = "let rows = (`$input.first() && `$input.first().json && `$input.first().json.rows) || [];\nconst _excl = new Set((ctx.exclude_codes || []).map(c => String(c)));\nif (_excl.size) {\n  rows = rows.filter(r => !_excl.has(String(r.cliente_codigo || r.code || '')));\n}\nif (!rows.length) {"
$arb = Apply-Replace -Text $arb -Old $oldNN -New $newNN -Label 'arb/nearest-neighbor'

[System.IO.File]::WriteAllText($arbPath, $arb, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "auto-route-builder OK"

# Validate JSON
try {
    $null = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($apiPath, [System.Text.Encoding]::UTF8))
    $null = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($arbPath, [System.Text.Encoding]::UTF8))
    Write-Host "JSON valid"
} catch {
    Write-Error "JSON invalid: $_"
    exit 1
}

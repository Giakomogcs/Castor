# Patch5c — fix the Auto Route Builder portion (needles needed escaped quotes for JSON-string content).
$ErrorActionPreference = 'Stop'

function Apply-Replace {
    param([string]$Text, [string]$Old, [string]$New, [string]$Label, [int]$ExpectedCount = 1)
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne $ExpectedCount) { throw "[$Label] expected $ExpectedCount, found $count" }
    return $Text.Replace($Old, $New)
}

$arbPath = 'castor-agent\workspaces\[Castor] Sub-fluxo_ Auto Route Builder.json'
$arb = [System.IO.File]::ReadAllText($arbPath, [System.Text.Encoding]::UTF8)

# 1) jsonSchema (JSON-escaped string)
$oldSchema = '\"name\":{\"type\":\"string\",\"description\":\"nome opcional do roteiro salvo\"}}}'
$newSchema = '\"name\":{\"type\":\"string\",\"description\":\"nome opcional do roteiro salvo\"},\"exclude_codes\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"cliente_codigo a EXCLUIR (já em roteiros abertos)\"}}}'
$arb = Apply-Replace -Text $arb -Old $oldSchema -New $newSchema -Label 'arb/jsonSchema'

# 2) Validate jsCode (JSON-escaped — uses \n literal sequence inside the JSON string).
$oldVal = 'const name = input.name ? String(input.name) : (''Roteiro IA '' + new Date().toLocaleDateString(''pt-BR''));\nreturn [{ json: { ok:true, user_id, mode, uf, cid, max_stops, origin_lat, origin_lng, name } }];'
$newVal = 'const name = input.name ? String(input.name) : (''Roteiro IA '' + new Date().toLocaleDateString(''pt-BR''));\nlet exclude_codes = [];\ntry {\n  const raw = input.exclude_codes;\n  const arr = Array.isArray(raw) ? raw : (typeof raw === ''string'' ? JSON.parse(raw || ''[]'') : []);\n  exclude_codes = (arr || []).map(c => String(c).trim()).filter(Boolean).slice(0, 200);\n} catch (e) { exclude_codes = []; }\nreturn [{ json: { ok:true, user_id, mode, uf, cid, max_stops, origin_lat, origin_lng, name, exclude_codes } }];'
$arb = Apply-Replace -Text $arb -Old $oldVal -New $newVal -Label 'arb/validate'

# 3) nearest-neighbor JS (also inside JSON string with \n literal).
$oldNN = 'const rows = ($input.first() && $input.first().json && $input.first().json.rows) || [];\nif (!rows.length) {'
$newNN = 'let rows = ($input.first() && $input.first().json && $input.first().json.rows) || [];\nconst _excl = new Set((ctx.exclude_codes || []).map(c => String(c)));\nif (_excl.size) {\n  rows = rows.filter(r => !_excl.has(String(r.cliente_codigo || r.code || '''')));\n}\nif (!rows.length) {'
$arb = Apply-Replace -Text $arb -Old $oldNN -New $newNN -Label 'arb/nearest-neighbor'

[System.IO.File]::WriteAllText($arbPath, $arb, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "auto-route-builder OK"

# Validate JSON
try {
    $null = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($arbPath, [System.Text.Encoding]::UTF8))
    Write-Host "JSON valid"
} catch {
    Write-Error "JSON invalid: $_"
    exit 1
}

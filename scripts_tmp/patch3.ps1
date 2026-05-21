$path='castor-agent\front-castor.html'
$txt=[System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

# 1) Inject the routeOpenBadge helper just before "function render() {" inside RoutesPanel.
$anchor = "        function render() {`r`n          const tbody = document.getElementById(`"routesTableBody`");"
$helper = @"
        // Tag visual: cliente já está em um roteiro aberto (kanban em aberto/andamento).
        // Usado para evitar "perder" o vendedor — ele vê na lista que aquele cliente
        // já tem tarefa pendente em outro lugar e não deve ser re-roteirizado.
        function routeOpenBadge(code) {
          try {
            const idx = window.MyRoutePage && window.MyRoutePage.openRouteIndex
              ? window.MyRoutePage.openRouteIndex() : null;
            if (!idx) return '';
            const hit = idx.get(String(code));
            if (!hit) return '';
            const isInProgress = hit.route_status === 'em_andamento';
            const color = isInProgress ? '#7c3aed' : '#0ea5e9';
            const label = isInProgress ? 'Em andamento' : 'Em aberto';
            const rid = String(hit.route_id || '').slice(-4);
            const next = hit.next_contact_at ? (' · 📅 ' + String(hit.next_contact_at).slice(0,10)) : '';
            const tip = 'Este cliente já está no seu kanban (roteiro R#' + rid + ' · ' + label + ')' + next + '. Não será re-sugerido pela IA.';
            return '<span class="route-open-tag" title="' + tip.replace(/"/g,'&quot;') + '" '
              + 'style="display:inline-flex;align-items:center;gap:3px;font-size:10px;font-weight:600;'
              + 'background:' + color + '14;color:' + color + ';border:1px solid ' + color + '55;'
              + 'border-radius:10px;padding:1px 7px;margin-right:6px;vertical-align:middle;white-space:nowrap">'
              + '🗂 R#' + rid + ' · ' + label + '</span>';
          } catch (e) { return ''; }
        }

        function render() {
          const tbody = document.getElementById(`"routesTableBody`");
"@
$helper = $helper -replace "`r`n","`n" -replace "`n","`r`n"
if (-not $txt.Contains($anchor)) { Write-Error "anchor not found"; exit 1 }
$cnt = ([regex]::Matches($txt, [regex]::Escape($anchor))).Count
if ($cnt -ne 1) { Write-Error "anchor not unique: $cnt"; exit 1 }
$txt = $txt.Replace($anchor, $helper)

# 2) Inject ${routeOpenBadge(code)} before the <strong> client-link in BOTH reactivation/active rows.
# Both rows are textually identical, so a global Replace catches both.
$oldRow = '<td><strong class="client-link" data-detail-code="${code}"'
$newRow = '<td>${routeOpenBadge(code)}<strong class="client-link" data-detail-code="${code}"'
$rowCnt = ([regex]::Matches($txt, [regex]::Escape($oldRow))).Count
if ($rowCnt -ne 2) { Write-Error "row needle count = $rowCnt (expected 2)"; exit 1 }
$txt = $txt.Replace($oldRow, $newRow)

[System.IO.File]::WriteAllText($path, $txt, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK final length:" $txt.Length

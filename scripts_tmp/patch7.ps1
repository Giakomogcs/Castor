$ErrorActionPreference = 'Stop'
function DoReplace { param([string]$T,[string]$O,[string]$N,[string]$L)
  $c = ([regex]::Matches($T, [regex]::Escape($O))).Count
  if ($c -ne 1) { throw "[$L] matches=$c" }
  return $T.Replace($O,$N)
}
$p = 'castor-agent\front-castor.html'
$t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)

# 1) Remove km from sidebar Roteiros widget
$o1 = '<div class="sb-card-meta">${stops} parada(s) · ${(r.total_km||0).toFixed(1)} km · ${fmtDateShort(r.created_at)}</div>'
$n1 = '<div class="sb-card-meta">${stops} parada(s) · ${fmtDateShort(r.created_at)}</div>'
$t = DoReplace $t $o1 $n1 'sidebar-km'

# 2a) Add Detalhes (ℹ) button to kan-card (savedRouteKanban)
$o2 = '              return `<div class="kan-card" data-idx="${idx}" data-code="${esc(s.cliente_codigo)}"' + "`n" + '                style="background:#fff;border:1px solid var(--border-color,#e5e5e5);border-left:3px solid ${col.color};border-radius:6px;padding:8px;cursor:pointer">' + "`n" + '                <div style="font-weight:600;font-size:0.82rem;line-height:1.2">${idx+1}. ${nm}</div>'
$n2 = '              return `<div class="kan-card" data-idx="${idx}" data-code="${esc(s.cliente_codigo)}"' + "`n" + '                style="background:#fff;border:1px solid var(--border-color,#e5e5e5);border-left:3px solid ${col.color};border-radius:6px;padding:8px;cursor:pointer;position:relative">' + "`n" + '                <button type="button" class="kan-detail-btn" data-code="${esc(s.cliente_codigo)}" title="Abrir detalhes do cliente"' + "`n" + '                  style="position:absolute;top:4px;right:4px;background:#fff;border:1px solid var(--border-color,#e5e5e5);border-radius:4px;padding:2px 6px;font-size:10px;cursor:pointer;color:var(--text-secondary);line-height:1;font-weight:600">ℹ Detalhes</button>' + "`n" + '                <div style="font-weight:600;font-size:0.82rem;line-height:1.2;padding-right:78px">${idx+1}. ${nm}</div>'
# Try CRLF variant
$o2_crlf = $o2 -replace "`n","`r`n"
$n2_crlf = $n2 -replace "`n","`r`n"
if ($t.Contains($o2_crlf)) { $t = $t.Replace($o2_crlf, $n2_crlf); Write-Host "kan-card CRLF" }
elseif ($t.Contains($o2)) { $t = $t.Replace($o2, $n2); Write-Host "kan-card LF" }
else { throw "kan-card needle not found" }

# 2b) Wire detail button BEFORE existing kan-card click handler
$o3 = '          // clique em card → volta pra lista naquele item em modo editar' + "`n" + '          el.querySelectorAll(''.kan-card'').forEach(card => {' + "`n" + '            card.addEventListener(''click'', () => {' + "`n" + '              const idx = +card.dataset.idx;'
$n3 = '          // botoes ℹ Detalhes: abrem o modal do cliente' + "`n" + '          el.querySelectorAll(''.kan-detail-btn'').forEach(btn => {' + "`n" + '            btn.addEventListener(''click'', (ev) => {' + "`n" + '              ev.stopPropagation();' + "`n" + '              const code = btn.dataset.code;' + "`n" + '              if (code && window.ClientDetail && typeof window.ClientDetail.open === ''function'') {' + "`n" + '                window.ClientDetail.open(code);' + "`n" + '              }' + "`n" + '            });' + "`n" + '          });' + "`n" + '          // clique em card → volta pra lista naquele item em modo editar' + "`n" + '          el.querySelectorAll(''.kan-card'').forEach(card => {' + "`n" + '            card.addEventListener(''click'', (ev) => {' + "`n" + '              if (ev.target.closest(''.kan-detail-btn'')) return;' + "`n" + '              const idx = +card.dataset.idx;'
$o3_crlf = $o3 -replace "`n","`r`n"
$n3_crlf = $n3 -replace "`n","`r`n"
if ($t.Contains($o3_crlf)) { $t = $t.Replace($o3_crlf, $n3_crlf); Write-Host "kan-card-wire CRLF" }
elseif ($t.Contains($o3)) { $t = $t.Replace($o3, $n3); Write-Host "kan-card-wire LF" }
else { throw "kan-card wire needle not found" }

# 3a) Add Detalhes button to .myr-card (Meu Roteiro)
$o4 = '                  <div style="font-size:10px;color:var(--text-secondary);white-space:nowrap" title="Roteiro de origem">${rtLabel}</div>' + "`n" + '                </div>' + "`n" + '                <div style="font-size:11px;color:var(--text-secondary);margin-top:2px">cod ${esc(s.cliente_codigo)}${mun?'' · ''+mun:''''}${uf?''/''+uf:''''}</div>'
$n4 = '                  <div style="display:flex;align-items:center;gap:4px;flex-shrink:0">' + "`n" + '                    <button type="button" class="myr-detail-btn" data-code="${esc(s.cliente_codigo)}" title="Abrir detalhes do cliente"' + "`n" + '                      onclick="event.stopPropagation()"' + "`n" + '                      style="background:#fff;border:1px solid var(--border-color,#e5e5e5);border-radius:4px;padding:1px 6px;font-size:10px;cursor:pointer;color:var(--text-secondary);line-height:1.2;font-weight:600;white-space:nowrap">ℹ Detalhes</button>' + "`n" + '                    <div style="font-size:10px;color:var(--text-secondary);white-space:nowrap" title="Roteiro de origem">${rtLabel}</div>' + "`n" + '                  </div>' + "`n" + '                </div>' + "`n" + '                <div style="font-size:11px;color:var(--text-secondary);margin-top:2px">cod ${esc(s.cliente_codigo)}${mun?'' · ''+mun:''''}${uf?''/''+uf:''''}</div>'
$o4_crlf = $o4 -replace "`n","`r`n"
$n4_crlf = $n4 -replace "`n","`r`n"
if ($t.Contains($o4_crlf)) { $t = $t.Replace($o4_crlf, $n4_crlf); Write-Host "myr-card CRLF" }
elseif ($t.Contains($o4)) { $t = $t.Replace($o4, $n4); Write-Host "myr-card LF" }
else { throw "myr-card needle not found" }

# 3b) Wire myr-detail-btn inside _wireCards
$o5 = '        function _wireCards() {' + "`n" + '          const el = $(''myRouteKanban'');' + "`n" + '          el.querySelectorAll(''.myr-card'').forEach(card => {'
$n5 = '        function _wireCards() {' + "`n" + '          const el = $(''myRouteKanban'');' + "`n" + '          el.querySelectorAll(''.myr-detail-btn'').forEach(btn => {' + "`n" + '            btn.addEventListener(''click'', (ev) => {' + "`n" + '              ev.stopPropagation();' + "`n" + '              const code = btn.dataset.code;' + "`n" + '              if (code && window.ClientDetail && typeof window.ClientDetail.open === ''function'') {' + "`n" + '                window.ClientDetail.open(code);' + "`n" + '              }' + "`n" + '            });' + "`n" + '          });' + "`n" + '          el.querySelectorAll(''.myr-card'').forEach(card => {'
$o5_crlf = $o5 -replace "`n","`r`n"
$n5_crlf = $n5 -replace "`n","`r`n"
if ($t.Contains($o5_crlf)) { $t = $t.Replace($o5_crlf, $n5_crlf); Write-Host "myr-wire CRLF" }
elseif ($t.Contains($o5)) { $t = $t.Replace($o5, $n5); Write-Host "myr-wire LF" }
else { throw "myr-wire needle not found" }

# 3c) myr-card click handler: ignore clicks on myr-detail-btn
$o6 = '            card.addEventListener(''click'', (ev) => {' + "`n" + '              if (ev.target.closest(''.myr-popover'')) return;' + "`n" + '              if (ev.target.closest(''.myr-sel'') || ev.target.tagName === ''LABEL'') return;'
$n6 = '            card.addEventListener(''click'', (ev) => {' + "`n" + '              if (ev.target.closest(''.myr-popover'')) return;' + "`n" + '              if (ev.target.closest(''.myr-detail-btn'')) return;' + "`n" + '              if (ev.target.closest(''.myr-sel'') || ev.target.tagName === ''LABEL'') return;'
$o6_crlf = $o6 -replace "`n","`r`n"
$n6_crlf = $n6 -replace "`n","`r`n"
if ($t.Contains($o6_crlf)) { $t = $t.Replace($o6_crlf, $n6_crlf); Write-Host "myr-click CRLF" }
elseif ($t.Contains($o6)) { $t = $t.Replace($o6, $n6); Write-Host "myr-click LF" }
else { throw "myr-click needle not found" }

[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK final length:" $t.Length

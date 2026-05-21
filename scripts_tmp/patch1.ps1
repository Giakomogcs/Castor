$path='castor-agent\front-castor.html'
$txt=[System.IO.File]::ReadAllText($path)
$old = "setTimeout(() => { if (document.querySelector('.routes-tab.active')?.dataset.tab === 'myroute') MyRoutePage.load(); }, 200);"
$new = @"
setTimeout(() => { if (document.querySelector('.routes-tab.active')?.dataset.tab === 'myroute') MyRoutePage.load(); }, 200);
      // Eager-load do índice de roteiros abertos (usado pela tag "🗂 No roteiro"
      // nas abas Reativação / Ativos), mesmo antes do usuário entrar na aba "Meu Roteiro".
      setTimeout(() => {
        try {
          if (!MyRoutePage._ensured) { MyRoutePage._ensured = true; MyRoutePage.load(); }
        } catch (e) {}
      }, 700);

      // ---------- Helpers públicos: índice de roteiros abertos por cliente ----------
      // Map<cliente_codigo, { route_id, route_status, outcome, name, next_contact_at }>
      // Inclui apenas paradas em roteiros 'planejado'/'em_andamento' cujo outcome NÃO
      // está resolvido (visitou/convertido/nao_existe_mais/nao_interessado_permanente).
      window.MyRoutePage.OPEN_ROUTE_STATUSES = new Set(['planejado','em_andamento']);
      window.MyRoutePage.RESOLVED_OUTCOMES   = new Set(['visitou','convertido','nao_existe_mais','nao_interessado_permanente']);
      window.MyRoutePage.openRouteIndex = function () {
        const idx = new Map();
        const stops = (window.MyRoutePage.peek && window.MyRoutePage.peek()) || [];
        stops.forEach(s => {
          const st = String(s._route_status || '').toLowerCase();
          if (!window.MyRoutePage.OPEN_ROUTE_STATUSES.has(st)) return;
          if (window.MyRoutePage.RESOLVED_OUTCOMES.has(s.outcome)) return;
          const code = String(s.cliente_codigo || '').trim();
          if (!code) return;
          idx.set(code, {
            route_id: s._route_id,
            route_status: st,
            outcome: s.outcome || null,
            name: s.name || null,
            next_contact_at: s.next_contact_at || null
          });
        });
        return idx;
      };
      window.MyRoutePage.openRouteCodes = function () {
        return Array.from(window.MyRoutePage.openRouteIndex().keys());
      };
"@
# normalize $new line endings to CRLF to match the file
$new = $new -replace "`r`n","`n" -replace "`n","`r`n"
if (-not $txt.Contains($old)) { Write-Error "needle not found"; exit 1 }
$matches_count = ([regex]::Matches($txt, [regex]::Escape($old))).Count
if ($matches_count -ne 1) { Write-Error "needle not unique: $matches_count"; exit 1 }
$txt2 = $txt.Replace($old, $new)
[System.IO.File]::WriteAllText($path, $txt2, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK new length:" $txt2.Length

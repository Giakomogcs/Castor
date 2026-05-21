$path='castor-agent\front-castor.html'
$txt=[System.IO.File]::ReadAllText($path)
$old = @"
          dq('myRouteSuggestBtn', 'click', async () => {
            // delega à IA route do RoutesPanel (modo reactivation, mantém roteiro ativo via unified)
            if (window.RoutesPanel && window.RoutesPanel.aiSuggestMore) {
              await window.RoutesPanel.aiSuggestMore();
            } else {
              toast('Use a aba Reativação para sugerir mais.');
            }
            load();
          });
"@
$old = $old -replace "`r`n","`n" -replace "`n","`r`n"
$new = @"
          dq('myRouteSuggestBtn', 'click', async () => {
            // Chama diretamente o endpoint da IA (modo reactivation).
            // O backend unificado APPEND-a na rota aberta do vendedor (ou cria uma nova).
            // Passamos exclude_codes para evitar re-sugerir clientes que já estão em
            // roteiros abertos (mesmo ciclo de tarefa pendente).
            const ctx = currentUserCtx();
            if (!ctx.id) { toast('Faça login antes de sugerir.'); return; }
            const btn = `$('myRouteSuggestBtn');
            const origHtml = btn ? btn.innerHTML : '';
            if (btn) {
              btn.disabled = true;
              btn.innerHTML = '<i data-lucide="loader-2" style="width:14px;height:14px;animation:spin 1s linear infinite"></i> Pensando…';
              if (window.lucide) try { window.lucide.createIcons(); } catch(e){}
            }
            try {
              const exclude_codes = (window.MyRoutePage && window.MyRoutePage.openRouteCodes)
                ? window.MyRoutePage.openRouteCodes() : [];
              const r = await fetch(PANEL_AI_ROUTE_URL, {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                  user_id: ctx.id,
                  mode: 'reactivation',
                  max_stops: 5,
                  exclude_codes
                })
              });
              const j = await (window.castorSafeJson ? window.castorSafeJson(r) : r.json());
              if (!r.ok || !j || j.ok === false) {
                throw new Error((j && j.error) || ('HTTP ' + r.status));
              }
              const d = j.data || {};
              if (d.appended) {
                toast('✓ +' + (d.added_count || 0) + ' cliente(s) sugerido(s)');
              } else if (d.route_id) {
                toast('✓ Novo roteiro criado com ' + ((d.stops||[]).length) + ' parada(s)');
              } else {
                toast('Sem novos clientes para sugerir agora.');
              }
              // refresh local e widgets vizinhos
              await load();
              try { window.RoutesSidebar && window.RoutesSidebar.refresh && window.RoutesSidebar.refresh(); } catch (e) {}
              try { if (window.RoutesPanel && window.RoutesPanel.prefetchSnapshot) window.RoutesPanel.prefetchSnapshot(); } catch (e) {}
            } catch (e) {
              toast('Falha ao sugerir: ' + (e.message || e));
            } finally {
              if (btn) {
                btn.disabled = false;
                btn.innerHTML = origHtml;
                if (window.lucide) try { window.lucide.createIcons(); } catch(e){}
              }
            }
          });
"@
$new = $new -replace "`r`n","`n" -replace "`n","`r`n"
if (-not $txt.Contains($old)) { Write-Error "needle not found"; exit 1 }
$matches_count = ([regex]::Matches($txt, [regex]::Escape($old))).Count
if ($matches_count -ne 1) { Write-Error "needle not unique: $matches_count"; exit 1 }
$txt2 = $txt.Replace($old, $new)
[System.IO.File]::WriteAllText($path, $txt2, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK new length:" $txt2.Length

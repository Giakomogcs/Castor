$path='castor-agent\front-castor.html'
$txt=[System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

# 1) MyRoutePage.render: dispatch event after build to allow RoutesPanel re-render the tags.
# Inject inside the render() function of MyRoutePage, just after _wireCards() / _updateGenerateBtn().
$anchor1 = "          _wireCards();`r`n          _updateGenerateBtn();`r`n        }"
$inject1 = @"
          _wireCards();
          _updateGenerateBtn();
          // Avisa outras abas (Reativação/Ativos) para re-renderizar tags "🗂 No roteiro".
          try { window.dispatchEvent(new CustomEvent('castor:myroute-updated')); } catch (e) {}
        }
"@
$inject1 = $inject1 -replace "`r`n","`n" -replace "`n","`r`n"
$cnt = ([regex]::Matches($txt, [regex]::Escape($anchor1))).Count
if ($cnt -ne 1) { Write-Error "anchor1 not unique: $cnt"; exit 1 }
$txt = $txt.Replace($anchor1, $inject1)

# 2) RoutesPanel.init: add listener to refresh table tags when MyRoutePage updates.
# Inject right before "document.getElementById(\"routesReloadBtn\").addEventListener(\"click\", load);"
$anchor2 = "          _applyTabUI();`r`n          document.getElementById(`"routesReloadBtn`").addEventListener(`"click`", load);"
$inject2 = @"
          _applyTabUI();
          // Re-render leve quando o índice de roteiros abertos mudar (após Sugerir+,
          // ou após o load inicial do MyRoutePage). Re-render apenas se já temos dados.
          try {
            window.addEventListener('castor:myroute-updated', () => {
              if (state.rows && state.rows.length) {
                try { render(); } catch (e) {}
              }
            });
          } catch (e) {}
          document.getElementById("routesReloadBtn").addEventListener("click", load);
"@
$inject2 = $inject2 -replace "`r`n","`n" -replace "`n","`r`n"
$cnt2 = ([regex]::Matches($txt, [regex]::Escape($anchor2))).Count
if ($cnt2 -ne 1) { Write-Error "anchor2 not unique: $cnt2"; exit 1 }
$txt = $txt.Replace($anchor2, $inject2)

[System.IO.File]::WriteAllText($path, $txt, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK final length:" $txt.Length

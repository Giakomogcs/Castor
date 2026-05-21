$ErrorActionPreference = 'Stop'
function Apply-Replace {
    param([string]$Text, [string]$Old, [string]$New, [string]$Label)
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "[$Label] matches=$count" }
    return $Text.Replace($Old, $New)
}

$p = 'castor-agent\front-castor.html'
$t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)

# 1) Replace kanban CSS block (use unique anchor lines and short delimiters).
$startMarker = '      /* Kanban responsivo'
$endMarker   = "        ) !important;`r`n      }"
$sIdx = $t.IndexOf($startMarker)
if ($sIdx -lt 0) { throw 'start marker not found' }
$eIdx = $t.IndexOf($endMarker, $sIdx)
if ($eIdx -lt 0) { throw 'end marker not found' }
$eIdxFull = $eIdx + $endMarker.Length
$oldBlock = $t.Substring($sIdx, $eIdxFull - $sIdx)

$newBlock = @'
      /* ===================================================== */
      /* Kanban responsivo — ocupa toda altura disponível      */
      /* ===================================================== */
      #myRoutePanel {
        flex: 1 1 auto;
        min-height: 0;
        display: flex;
        flex-direction: column;
        padding: 12px 24px 16px;
        overflow: hidden;
      }
      #myRouteSummary { flex: 0 0 auto; }
      #myRouteLoading, #myRouteEmpty { flex: 0 0 auto; }

      #myRouteKanban {
        flex: 1 1 auto;
        min-height: 0;
        overflow: hidden;
      }
      #myRouteKanban,
      #savedRouteKanban {
        grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)) !important;
      }
      /* Colunas: flex-column para que a lista interna role independentemente */
      .myr-col,
      .kan-col {
        display: flex !important;
        flex-direction: column;
        min-height: 0;
        max-height: 100%;
      }
      .myr-col > div:last-child,
      .kan-col > div:last-child {
        overflow-y: auto;
        flex: 1 1 auto;
        min-height: 0;
        padding-right: 2px;
      }
      .myr-col > div:last-child::-webkit-scrollbar,
      .kan-col > div:last-child::-webkit-scrollbar { width: 6px; }
      .myr-col > div:last-child::-webkit-scrollbar-thumb,
      .kan-col > div:last-child::-webkit-scrollbar-thumb {
        background: rgba(0,0,0,.15); border-radius: 3px;
      }

      @media (max-width: 1280px) {
        #myRouteKanban,
        #savedRouteKanban {
          grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)) !important;
        }
      }
      @media (max-width: 900px) {
        #myRouteKanban,
        #savedRouteKanban {
          grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
          gap: 8px !important;
        }
        /* Em telas médias, as colunas crescem com o conteúdo (sem altura fixa) */
        .myr-col, .kan-col { max-height: none; }
        .myr-col > div:last-child,
        .kan-col > div:last-child { overflow-y: visible; }
      }
      @media (max-width: 520px) {
        #myRoutePanel { padding: 8px 12px 12px; }
        #myRouteKanban,
        #savedRouteKanban {
          grid-template-columns: 1fr !important;
        }
        .routes-toolbar { padding: 8px 12px; gap: 6px; }
        .routes-tabs { padding: 0 12px; }
        .routes-tab { padding: 10px 10px; font-size: 0.82rem; }
        .routes-tab .tab-count { font-size: 0.65rem; padding: 0 5px; }
      }

      .kan-card,
      .myr-card {
        transition: transform 0.12s ease, box-shadow 0.12s ease;
      }
      .kan-card:hover,
      .myr-card:hover {
        transform: translateY(-1px);
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
      }
      /* Coluna "Encerrados" — visual sutil para diferenciar de "Fechados" */
      .kan-col[data-col="closed"],
      .myr-col[data-col="closed"] {
        background: repeating-linear-gradient(
          45deg,
          var(--bg-tertiary, #f5f5f5),
          var(--bg-tertiary, #f5f5f5) 8px,
          rgba(71, 85, 105, 0.05) 8px,
          rgba(71, 85, 105, 0.05) 16px
        ) !important;
      }
'@
# Normalize newlines
$newBlock = ($newBlock -replace "`r`n","`n") -replace "`n","`r`n"
$t = $t.Substring(0, $sIdx) + $newBlock + $t.Substring($eIdxFull)

# 2) Update inline style of #myRouteKanban (remove fixed cols + min-height)
$oldDiv = '<div id="myRouteKanban" style="display:grid;grid-template-columns:repeat(4, 1fr);gap:10px;min-height:300px"></div>'
$newDiv = '<div id="myRouteKanban" style="display:grid;gap:10px"></div>'
$t = Apply-Replace -Text $t -Old $oldDiv -New $newDiv -Label 'kanban inline style'

[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK length:" $t.Length

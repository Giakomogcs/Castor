$ErrorActionPreference='Stop'
$today = Get-Date '2026-05-19'

function Parse-Generic([string]$path,[int]$cliIdx,[int]$lojaIdx,[int]$dataIdx,[string]$label){
  $sw = [System.IO.StreamReader]::new($path)
  $rowsByYear = @{}
  $win = @{ '90'=@{}; '180'=@{}; '365'=@{}; '730'=@{}; 'all'=@{} }
  $total=0; $semData=0
  while(($l = $sw.ReadLine()) -ne $null){
    $total++
    $f = $l.Split(';')
    $maxIdx = [Math]::Max([Math]::Max($cliIdx,$lojaIdx),$dataIdx)
    if($f.Count -le $maxIdx){ continue }
    $cli  = ($f[$cliIdx]  -replace '"','').Trim()
    $loja = ($f[$lojaIdx] -replace '"','').Trim()
    $emis = ($f[$dataIdx] -replace '"','').Trim()
    if($emis -notmatch '^\d{8}$'){ $semData++; continue }
    $y = $emis.Substring(0,4)
    if(-not $rowsByYear.ContainsKey($y)){ $rowsByYear[$y]=0 }
    $rowsByYear[$y]++
    $code = $cli+$loja
    try{ $dt = [datetime]::ParseExact($emis,'yyyyMMdd',$null) }catch{ continue }
    $days = ($today - $dt).TotalDays
    $win['all'][$code]=1
    if($days -le 730){ $win['730'][$code]=1 }
    if($days -le 365){ $win['365'][$code]=1 }
    if($days -le 180){ $win['180'][$code]=1 }
    if($days -le 90){  $win['90'][$code]=1 }
  }
  $sw.Close()
  [pscustomobject]@{
    arquivo=$label
    total_linhas=$total
    sem_data=$semData
    por_ano=(($rowsByYear.GetEnumerator()|Sort-Object Name|ForEach-Object{"$($_.Key)=$($_.Value)"}) -join ' ')
    clientes_90d=$win['90'].Count
    clientes_180d=$win['180'].Count
    clientes_365d=$win['365'].Count
    clientes_730d=$win['730'].Count
    clientes_alltime=$win['all'].Count
  }
}

# SC5010 columns (0-based): cliente=3, loja=4, emissao=41
Parse-Generic 'C:\Users\Administrador\Downloads\Castor\SC5010.csv' 3 4 41 'SC5010 (pedidos)' | Format-List
# SF2010 columns (0-based): cliente=3, loja=4, emissao=7
Parse-Generic 'C:\Users\Administrador\Downloads\Castor\SF2010.csv' 3 4 7 'SF2010 (NF)' | Format-List

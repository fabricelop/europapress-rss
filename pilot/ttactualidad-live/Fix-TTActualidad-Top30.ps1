#requires -Version 5.1
# TTActualidad Top 30: update ONLY HTML assets of the existing direct Worker.
# No changes to its JavaScript Worker, KV binding, secrets or other apps.
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$dir=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $dir 'wrangler.jsonc'
$site=Join-Path $dir 'site\index.html'
$worker=Join-Path $dir 'ttactualidad-worker.js'
$wrangler=Join-Path $dir 'node_modules\.bin\wrangler.cmd'
$url='https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
# Pin the tested index.html, not the mutable main branch.
$revision='fe13ec18886976e3f89377986582dd807e98a350'
$source='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$revision+'/pilot/ttactualidad-live/index.html'
$needed=@('let loadRevision=0','function currentTop30(recent){',
  "if(revision!==loadRevision||app!==state.app)return",
  "const radarPath=app==='tr'?",'Top 30','TTImages','/api/manual-news')
$back=$null
$deployed=$false
$temp=Join-Path $env:TEMP ('TTActualidad-Top30-'+[Guid]::NewGuid().ToString('N'))
New-Item -Path $temp -ItemType Directory -Force|Out-Null
try {
  foreach($file in @($config,$site,$worker,$wrangler)){
    if(-not (Test-Path -LiteralPath $file)){throw ('Falta fichero local: '+$file)}
  }
  $cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
  $kv=@($cfg.kv_namespaces|Where-Object{$_.binding -ceq 'PILOT_DECISIONS'})
  if($cfg.name -cne 'ttactualidad-decisions-pilot' -or
     $cfg.main -cne './ttactualidad-worker.js' -or
     @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
     [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
    throw 'Worker/KV desconocidos: despliegue cancelado'
  }
  $health=Invoke-RestMethod -Uri ($url+'health?top30check='+[Guid]::NewGuid()) -TimeoutSec 20
  if($health.ok -ne $true -or
     $health.kind -cne 'ttactualidad-direct-live' -or
     $health.production_connected -ne $true -or
     $health.session_auth -cne 'signed_cookie_v1'){
    throw 'Worker original no está saludable/auténtico. Nada se cambia.'
  }
  $oldPage=(Invoke-WebRequest -UseBasicParsing -Uri ($url+'?top30check='+[Guid]::NewGuid()) -TimeoutSec 20).Content
  foreach($mark in @('Top 30','TTImages','/api/manual-news')){
    if(-not $oldPage.Contains($mark)){throw ('HTML actual no reconocido: '+$mark)}
  }
  $newFile=Join-Path $temp 'index.html'
  Invoke-WebRequest -UseBasicParsing -Uri $source -OutFile $newFile -TimeoutSec 45
  $newHtml=[IO.File]::ReadAllText($newFile,[Text.Encoding]::UTF8)
  foreach($mark in $needed){
    if(-not $newHtml.Contains($mark)){throw ('HTML descargado incompleto: '+$mark)}
  }
  $beg=$newHtml.IndexOf('<script>')
  $end=$newHtml.IndexOf('</script>',$beg)
  if($beg -lt 0 -or $end -le $beg){throw 'Falta JavaScript de interfaz'}
  $testJs=Join-Path $temp 'ttactualidad-top30-check.js'
  [IO.File]::WriteAllText($testJs,$newHtml.Substring($beg+8,$end-$beg-8),[Text.UTF8Encoding]::new($false))
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction Stop}
  & $node.Source --check $testJs
  if($LASTEXITCODE -ne 0){throw 'JS nuevo inválido; no se despliega'}
  $existing=Get-FileHash -LiteralPath $site -Algorithm SHA256
  $next=Get-FileHash -LiteralPath $newFile -Algorithm SHA256
  if($existing.Hash -eq $next.Hash){
    Write-Host 'TT Actualidad Top 30: HTML v8.6 ya instalado localmente.'
    if($oldPage.Contains('let loadRevision=0') -and $oldPage.Contains('function currentTop30(recent){')){
      Write-Host 'TOP 30 YA PUBLICADO Y VERIFICADO';return
    }
  }
  if($PreflightOnly){Write-Host 'PREFLIGHT OK: código listo; nada modificado.';return}
  $workerHash=(Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash
  $back=Join-Path $dir ('index.before-top30-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak')
  Copy-Item -LiteralPath $site -Destination $back -ErrorAction Stop
  Copy-Item -LiteralPath $newFile -Destination $site -Force
  Push-Location $dir
  try{
    $saveErr=$ErrorActionPreference
    try{$ErrorActionPreference='Continue'; & $wrangler deploy --config $config; $exitCode=$LASTEXITCODE}
    finally{$ErrorActionPreference=$saveErr}
  }finally{Pop-Location}
  if($exitCode -ne 0){throw ('Wrangler no pudo publicar HTML ('+$exitCode+')')}
  $deployed=$true
  if((Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash -cne $workerHash){
    throw 'El código del Worker cambió de forma inesperada.'
  }
  $verified=$false
  for($i=0;$i -lt 6;$i++){
    try{
      $live=(Invoke-WebRequest -UseBasicParsing -Uri ($url+'?top30v86='+[Guid]::NewGuid()) -TimeoutSec 18).Content
      $updatedHealth=Invoke-RestMethod -Uri ($url+'health?top30v86='+[Guid]::NewGuid()) -TimeoutSec 18
      if($live.Contains('let loadRevision=0') -and $live.Contains('function currentTop30(recent){') -and
         $updatedHealth.kind -ceq $health.kind -and $updatedHealth.version -ceq $health.version -and
         $updatedHealth.production_connected -eq $true -and $updatedHealth.session_auth -ceq $health.session_auth){
        $verified=$true;break
      }
    }catch{}
    Start-Sleep -Seconds 2
  }
  if(-not $verified){throw 'La nueva interfaz no quedó verificada en el Worker.'}
  Write-Host 'TOP 30 CORREGIDO Y PUBLICADO en TT Actualidad (Worker original).' -ForegroundColor Green
  Write-Host ('Copia del HTML anterior: '+$back)
}catch{
  if($back -and (Test-Path -LiteralPath $back)){
    Copy-Item -LiteralPath $back -Destination $site -Force
    if($deployed){
      Write-Warning 'Intentando recuperar también HTML anterior en Worker'
      try{
        Push-Location $dir
        try{
          $saveErr=$ErrorActionPreference
          try{$ErrorActionPreference='Continue'; & $wrangler deploy --config $config; $restoreCode=$LASTEXITCODE}
          finally{$ErrorActionPreference=$saveErr}
        }finally{Pop-Location}
        if($restoreCode -ne 0){Write-Warning 'Restauración remota no confirmada'}
      }catch{Write-Warning ('Restauración remota fallida: '+$_)}
    }
  }
  throw
}finally{
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

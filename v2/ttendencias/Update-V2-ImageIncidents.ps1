# Update reporting only. No process/task/browser is started, stopped or reconfigured.
[CmdletBinding()]
param([string]$BaseDir=(Join-Path $env:LOCALAPPDATA 'TTActualidadV2'))
$ErrorActionPreference='Stop'
$py=(Get-Command py.exe -ErrorAction Stop).Source
if(-not (Test-Path -LiteralPath $BaseDir -PathType Container)){throw 'No existe la instalación de tendencias V2'}
$worker=Join-Path $BaseDir 'image_worker_v2.py'
function Assert-NoActiveImageWorker {
  $matching=@(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(py|python|pythonw)\.exe$' -and $_.CommandLine -and
    ([string]$_.CommandLine).IndexOf($worker,[StringComparison]::OrdinalIgnoreCase) -ge 0
  })
  if($matching.Count){throw 'Hay una imagen V2 en curso. No se toca: repetir cuando haya terminado.'}
}
Assert-NoActiveImageWorker
$headers=@{'User-Agent'='TTActualidadV2-image-incident-update';'Accept'='application/vnd.github+json'}
$api='https://api.github.com/repos/fabricelop/europapress-rss'
$head=Invoke-RestMethod -Uri ($api+'/commits/'+[Uri]::EscapeDataString('feature/ttactualidad-v2-clean')) -Headers $headers
$sha=[string]$head.sha
if($sha -notmatch '^[a-f0-9]{40}$'){throw 'No se pudo fijar la versión V2'}
$known=@{'image_worker_v2.py'='bb3478c3dfd661fc6085331fc7c787260da9b411';'web_top30_v2.py'='8d112090f89b1a86105ee831fca880bd8cf6c042'}
function GitBlobHash([byte[]]$Bytes){
  $prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$Bytes.Length+[char]0)
  $hash=[Security.Cryptography.SHA1]::Create()
  try{return ([BitConverter]::ToString($hash.ComputeHash([byte[]]($prefix+$Bytes)))).Replace('-','').ToLowerInvariant()}
  finally{$hash.Dispose()}
}
$utf8=New-Object Text.UTF8Encoding($false)
$staged=@()
foreach($name in @('web_top30_v2.py','image_worker_v2.py')){
  $target=Join-Path $BaseDir $name
  if(-not (Test-Path -LiteralPath $target)){throw ('Falta '+$name)}
  $meta=Invoke-RestMethod -Uri ($api+'/contents/v2/ttendencias/'+$name+'?ref='+$sha) -Headers $headers
  $temp=Join-Path $BaseDir ($name+'.incident-update.new.py')
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$sha+'/v2/ttendencias/'+$name) -OutFile $temp -Headers $headers
  if((GitBlobHash ([IO.File]::ReadAllBytes($temp))) -ne [string]$meta.sha){throw 'Descarga no verificada'}
  $original=[IO.File]::ReadAllBytes($target)
  $normalized=[IO.File]::ReadAllText($target).Replace("`r`n","`n")
  $oldHash=GitBlobHash ($utf8.GetBytes($normalized))
  if($oldHash -eq [string]$meta.sha){Remove-Item -LiteralPath $temp;continue}
  if($oldHash -ne $known[$name]){throw ('Versión local distinta de la base validada; se conserva sin sobrescribir: '+$name+' SHA='+$oldHash)}
  $check=Start-Process -FilePath $py -ArgumentList @('-3','-m','py_compile',('"'+$temp+'"')) -Wait -PassThru -WindowStyle Hidden
  if($check.ExitCode -ne 0){throw 'La sintaxis Python descargada no es válida'}
  $staged+=@{name=$name;target=$target;temp=$temp;original_sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash}
}
if(-not $staged.Count){Write-Host 'TT_V2_IMAGE_INCIDENT_REPORTING=ALREADY_INSTALLED';return}
Assert-NoActiveImageWorker
$backup=Join-Path $BaseDir ('Backup-Image-Incidents-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup | Out-Null
foreach($file in $staged){
  if((Get-FileHash -LiteralPath $file.target -Algorithm SHA256).Hash -ne $file.original_sha256){throw 'El archivo local cambió; no sobrescribir'}
  Copy-Item -LiteralPath $file.target -Destination (Join-Path $backup $file.name)
  Move-Item -LiteralPath $file.temp -Destination $file.target -Force
}
Write-Host ('COPIA_SEGURIDAD='+$backup)
Write-Host ('TT_V2_IMAGE_INCIDENT_REPORTING_COMMIT='+$sha)
Write-Host 'TT_V2_IMAGE_INCIDENT_REPORTING=INSTALLED_FOR_NEW_JOBS'
Write-Host 'CHROME_TASKS_AND_RUNNING_JOBS=UNCHANGED'

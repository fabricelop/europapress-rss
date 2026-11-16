# Stops only the two retired V1 ChatGPT pipelines. Run elevated on the Windows PC.
[CmdletBinding()]
param([string]$BaseDir='C:\TTiTTulares', [switch]$StatusOnly)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not $StatusOnly -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  throw 'Abra PowerShell como administrador y vuelva a ejecutar este archivo.'
}
# Exact basenames, never a broad match on TT / Chrome / PowerShell / Node.
$retired=@('TTiTTularesDedicatedListener.ps1','TTendenciasDedicatedListener.ps1',
  'MobileChatTriggerListener.ps1','TTiTTularesMobileChatTriggerListener.ps1',
  'TTendenciasMobileChatTriggerListener.ps1','TTiTTularesImageBridge.js',
  'TTendenciasImageBridge.js','TT-AutoUpdater.ps1')
$taskNames=@('TTiTTulares Local','TTiTTulares Local Ready','TTendencias Local',
  'TTendencias Local Ready','TTendencias-XContext','TTiTTulares-XContext')
$basePattern=[regex]::Escape(([IO.Path]::GetFullPath($BaseDir)).TrimEnd('\')+'\')
$namePattern='(?:'+(($retired | ForEach-Object {[regex]::Escape($_)}) -join '|')+')(?=["\s]|$)'
function Is-RetiredCommand([string]$command){
  if($command -notmatch $basePattern){return $false}
  if($command -match '(?i)selorecordamos|[\\/]v2[\\/]|TTActualidadV2'){return $false}
  if($command -match ('(?i)[\\/]'+$namePattern)){return $true}
  return $command -match '(?i)[\\/](?:Ejecutar\.js|LanzarOculto\.vbs)["\s]+(?:"?(?:titulares|tendencias)"?)(?=\s|$)'
}
function Active-V1 {
  @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and $_.Name -in @('node.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe') -and
    (Is-RetiredCommand ([string]$_.CommandLine))
  })
}
if($StatusOnly){
  $remaining=@(Active-V1)
  $remaining | Select-Object ProcessId,Name,CommandLine | Format-List
  Write-Host ('TT_V1_MATCHING_PROCESSES='+$remaining.Count)
  exit 0
}
if(-not (Test-Path -LiteralPath $BaseDir -PathType Container)){throw "No existe $BaseDir"}
$backup=Join-Path $BaseDir ('Backup-Parada-V1-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$manifest=New-Object Collections.Generic.List[object]
function Save-Original([string]$path){
  $destination=Join-Path $backup ([Guid]::NewGuid().ToString('N')+'-'+[IO.Path]::GetFileName($path))
  Copy-Item -LiteralPath $path -Destination $destination
  $manifest.Add([pscustomobject]@{path=$path;backup=$destination;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash})
  $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'files.json') -Encoding UTF8
}
# Listeners, old task actions and manual launches now reach a no-op entrypoint.
# Keeping the originals separately preserves unseen local hotfixes.
foreach($name in $retired){
  $file=Join-Path $BaseDir $name
  if(-not (Test-Path -LiteralPath $file)){continue}
  if(([IO.File]::ReadAllText($file)) -match 'TT_V1_STOP_WRAPPER_20261116'){continue}
  Save-Original $file
  if($name -like '*.ps1'){$body="# TT_V1_STOP_WRAPPER_20261116`r`nWrite-Output 'TT_V1_CHATGPT_DISABLED'`r`nexit 0`r`n"}
  else {$body="// TT_V1_STOP_WRAPPER_20261116`nprocess.exit(0);`n"}
  [IO.File]::WriteAllText($file,$body,$utf8)
}
# Ejecutar.js can also serve SeLoRecordamos: block only its V1 arguments.
$runner=Join-Path $BaseDir 'Ejecutar.js'
if(Test-Path -LiteralPath $runner){
  $original=[IO.File]::ReadAllText($runner)
  if($original -notmatch 'TT_V1_EXECUTOR_GUARD_20261116'){
    Save-Original $runner
    $guard="// TT_V1_EXECUTOR_GUARD_20261116`nif (process.argv.slice(2).some(x => /^(titulares|tendencias)$/i.test(x))) { console.log('TT_V1_CHATGPT_DISABLED'); process.exit(0); }`n"
    if($original.StartsWith('#!')){
      $newline=$original.IndexOf("`n")
      if($newline -lt 0){throw 'Ejecutar.js: shebang sin salto de linea'}
      $original=$original.Insert($newline+1,$guard)
    }else{$original=$guard+$original}
    [IO.File]::WriteAllText($runner,$original,$utf8)
  }
}
foreach($flag in @('TTendencias-V1-Disabled.flag','TTiTTulares-V1-Disabled.flag','V1-ImageGen-Paused.flag')){
  $file=Join-Path $BaseDir $flag
  if(-not (Test-Path -LiteralPath $file)){[IO.File]::WriteAllText($file,'Retirada V1 autorizada por el usuario: 2026-11-16',$utf8)}
}
# Disable only known V1 task names or exact V1 action paths/arguments.
foreach($task in @(Get-ScheduledTask)){
  $matched=$task.TaskName -in $taskNames
  foreach($action in @($task.Actions)){
    if(Is-RetiredCommand ([string]$action.Execute+' '+[string]$action.Arguments)){$matched=$true}
  }
  if(-not $matched){continue}
  Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath |
    Set-Content -LiteralPath (Join-Path $backup ('task-'+[Guid]::NewGuid().ToString('N')+'.xml')) -Encoding UTF8
  Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
  Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
  Write-Host ('TAREA_V1_DESACTIVADA: '+$task.TaskPath+$task.TaskName)
}
# The shared watchdog may launch the wrappers; they exit and cannot open ChatGPT.
# Do not stop that supervisor, SeLoRecordamos, Chrome or V2 processes.
for($pass=0;$pass -lt 3;$pass++){
  foreach($process in @(Active-V1)){
    $fresh=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.ProcessId)
    if($fresh -and (Is-RetiredCommand ([string]$fresh.CommandLine))){
      Stop-Process -Id $fresh.ProcessId -Force
      Write-Host ('PROCESO_V1_DETENIDO: '+$fresh.ProcessId+' '+$fresh.Name)
    }
  }
  Start-Sleep -Seconds 2
}
$remaining=@(Active-V1)
$report=[ordered]@{at=(Get-Date).ToString('o');remaining_v1=$remaining.Count;backup=$backup;
  browser_terminated=$false;v2_targeted=$false;selorecordamos_targeted=$false;
  note='Las conversaciones ya enviadas no se cancelan en el servidor de ChatGPT.'}
$report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'result.json') -Encoding UTF8
$remaining | Select-Object ProcessId,Name,CommandLine | Format-List
Write-Host ('COPIA_SEGURIDAD='+$backup)
if($remaining.Count){throw 'PARADA_V1_INCOMPLETA: consulte los procesos anteriores y result.json'}
Write-Host 'TT_V1_CHATGPT=DETENIDO_Y_BLOQUEADO_EN_ESTA_MUESTRA'

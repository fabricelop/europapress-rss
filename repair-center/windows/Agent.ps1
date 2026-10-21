#requires -Version 5.1
# Agente en modo consulta; NO diagnostica ni repara nada hasta recibir orden explícita.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$base=Join-Path $env:LOCALAPPDATA 'CentroReparaciones'
$cfgPath=Join-Path $base 'agent-config.json'
$tokenPath=Join-Path $base 'agent-key.bin'
if(-not (Test-Path $cfgPath) -or -not (Test-Path $tokenPath)){exit 0}
$cfg=Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if(([string]$cfg.url) -notmatch '^https://[A-Za-z0-9.-]+/?$'){throw 'URL HTTPS inválida'}
$url=([string]$cfg.url).TrimEnd('/')
$protected=[Convert]::FromBase64String([IO.File]::ReadAllText($tokenPath).Trim())
$raw=[Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
$agentKey=[Text.Encoding]::UTF8.GetString($raw)
[Array]::Clear($raw,0,$raw.Length)
$headers=@{'X-Agent-Key'=$agentKey}
$job=$null
try{
  $reply=Invoke-RestMethod -Uri "$url/api/agent/claim" -Headers $headers -Method POST -ContentType 'application/json' -Body '{}' -TimeoutSec 20
  $job=$reply.job
}catch{throw "No se pudo consultar la cola del agente: $($_.Exception.Message)"}
if($null -eq $job){exit 0}
$result='failed';$detail='No ejecutado'
try{
  $allowed=@('ttittulares.windows','ttendencias.windows','selorecordamos.windows','aquiestuve.windows')
  if($allowed -notcontains [string]$job.target){throw 'Operación no permitida'}
  $item=$null
  if($cfg.tasks -and $cfg.tasks.PSObject.Properties.Name -contains [string]$job.target){
    $item=$cfg.tasks.PSObject.Properties[[string]$job.target].Value
  }
  $taskName=if($null -eq $item){''}else{[string]$item.task_name}
  if(-not $item -or [string]::IsNullOrWhiteSpace($taskName)){
    $result='needs_configuration';$detail='Falta la tarea Windows autorizada para este proceso'
  }else{
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if($task.TaskName -cne $taskName){throw 'La tarea Windows no coincide exactamente'}
    $before=Get-ScheduledTaskInfo -TaskName $taskName
    $isDisabled=($task.State -eq 'Disabled')
    if($isDisabled){$result='needs_configuration';$detail='La tarea está deshabilitada; requiere autorización manual'}
    elseif($item.allow_start -eq $true){
      Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
      $after=Get-ScheduledTaskInfo -TaskName $taskName
      $result='triggered_unverified'
      $detail="Tarea $taskName solicitada. Estado posterior: $($after.LastTaskResult); inicio del proceso final NO verificado."
    }else{
      $result='diagnosed'
      $detail="Tarea ${taskName}: estado=$($task.State); ultimo resultado=$($before.LastTaskResult); ultima ejecución=$($before.LastRunTime). Sin cambios."
    }
  }
}catch{
  $result='failed';$detail=$_.Exception.Message
}
try{
  $payload=@{id=[string]$job.id;lease=[string]$job.lease;state=$result;detail=$detail}|ConvertTo-Json -Compress
  Invoke-RestMethod -Uri "$url/api/agent/report" -Headers $headers -Method POST -ContentType 'application/json' -Body $payload -TimeoutSec 20 | Out-Null
}catch{throw "El resultado local no se pudo registrar; revisar conexión antes de repetir: $($_.Exception.Message)"}

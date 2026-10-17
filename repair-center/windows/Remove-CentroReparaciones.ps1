#requires -Version 5.1
# Desinstalación de CentroReparaciones: no toca TTActualidad, FabCalendar ni otras tareas.
[CmdletBinding()]
param([switch]$SkipCloudflare)
$ErrorActionPreference='Continue'
$errorsFound=@()
Write-Host '=== RETIRAR CENTROREPARACIONES ==='
try {
  $tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {
    $_.TaskName -like '*CentroReparaciones*' -or
    (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match '(?i)CentroReparaciones[\\/]Agent\.ps1'
  })
  foreach($t in $tasks) {
    try {
      Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
      Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
      Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
      Write-Host "Tarea eliminada: $($t.TaskPath)$($t.TaskName)"
    } catch { $errorsFound += "Tarea $($t.TaskName): $($_.Exception.Message)" }
  }
} catch { $errorsFound += "Consultar tareas: $($_.Exception.Message)" }
try {
  Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -match '(?i)CentroReparaciones[\\/]Agent\.ps1'
  } | ForEach-Object {
    try {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
      Write-Host "Proceso del agente detenido: PID $($_.ProcessId)"
    } catch { $errorsFound += "Proceso $($_.ProcessId): $($_.Exception.Message)" }
  }
} catch { $errorsFound += "Consultar procesos: $($_.Exception.Message)" }
$installed=Join-Path $env:LOCALAPPDATA 'CentroReparaciones'
if(Test-Path -LiteralPath $installed) {
  try {
    Remove-Item -LiteralPath $installed -Recurse -Force -ErrorAction Stop
    Write-Host "Instalación y credenciales locales eliminadas: $installed"
  } catch { $errorsFound += "Archivos: $($_.Exception.Message)" }
}
$runPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if(Test-Path $runPath) {
  $props=Get-ItemProperty -LiteralPath $runPath
  foreach($prop in $props.PSObject.Properties) {
    if($prop.Name -notmatch '^PS' -and [string]$prop.Value -match '(?i)CentroReparaciones') {
      try {
        Remove-ItemProperty -LiteralPath $runPath -Name $prop.Name -ErrorAction Stop
        Write-Host "Inicio automático eliminado: $($prop.Name)"
      } catch { $errorsFound += "Inicio automático: $($_.Exception.Message)" }
    }
  }
}
if(-not $SkipCloudflare) {
  $npx=Get-Command 'npx.cmd' -ErrorAction SilentlyContinue
  if(-not $npx) { $npx=Get-Command 'npx' -ErrorAction SilentlyContinue }
  if($npx) {
    Write-Host 'Eliminando únicamente Cloudflare Worker centro-reparaciones; puede solicitar confirmación.'
    & $npx.Source --yes wrangler delete --name centro-reparaciones
    if($LASTEXITCODE -ne 0) { $errorsFound += "Cloudflare: wrangler código $LASTEXITCODE" }
    else { Write-Host 'Cloudflare ha confirmado la orden de eliminación del Worker.' }
  } else {
    $errorsFound += 'Cloudflare: falta npx; Worker no eliminado.'
  }
}
if(Get-ScheduledTask -TaskName 'CentroReparaciones-OnDemand' -ErrorAction SilentlyContinue) {
  $errorsFound += 'La tarea programada sigue presente'
}
if($errorsFound.Count) {
  Write-Warning ('Retirada parcial: '+($errorsFound -join ' | '))
  exit 1
}
Write-Host 'Retirada de Windows finalizada. Ningún otro proyecto modificado.' -ForegroundColor Green

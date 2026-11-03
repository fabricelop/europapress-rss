#requires -Version 5.1
# Read-only diagnostics. No process restart, credentials or full command lines.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
Write-Host 'TTActualidad - auditoria de recuperacion tras inicio de sesion'
Get-ScheduledTask | Where-Object { $_.TaskName -match '^(TT|SeLoRecordamos)' } | ForEach-Object {
 $info=Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath
 [pscustomobject]@{Tarea=$_.TaskName;Estado=$_.State;UltimoResultado=$info.LastTaskResult;Proximo=$info.NextRunTime;ArranquePendiente=$_.Settings.StartWhenAvailable;Ejecutable=([IO.Path]::GetFileName($_.Actions.Execute));Disparadores=(@($_.Triggers | ForEach-Object {$_.CimClass.CimClassName}) -join ',')}
} | Format-Table -AutoSize
Write-Host 'Accesos de inicio de sesion:'
Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Startup')) | Where-Object {$_.Name -match 'TT|SeLoRecordamos'} | Select-Object Name,Extension | Format-Table
Write-Host 'Procesos TT existentes (sin mostrar argumentos):'
Get-CimInstance Win32_Process | Where-Object {[string]$_.CommandLine -match 'TTiTTulares|TTendencias|TTImageApproval|TT-LocalWatchdog|TT-AutoUpdater'} | Select-Object Name,ProcessId | Format-Table
foreach($port in @(9223,9234)){try{$response=Invoke-RestMethod -Uri ('http://127.0.0.1:'+ $port +'/json/version') -TimeoutSec 3;Write-Host ('Chrome '+$port+': '+[bool]$response.webSocketDebuggerUrl)}catch{Write-Host ('Chrome '+$port+': no disponible')}}
$cycle=Join-Path $base 'image-approval-receipts\receiver-cycle.json'
if(Test-Path -LiteralPath $cycle){Get-Content -LiteralPath $cycle}
$status=Join-Path $base 'image-approval-receipts\receiver-status.json'
if(Test-Path -LiteralPath $status){$doc=Get-Content -LiteralPath $status -Raw|ConvertFrom-Json;$doc.PSObject.Properties.Value|Group-Object reason|Select-Object Count,Name|Sort-Object Count -Descending|Format-Table}
Write-Host 'Auditoria terminada. No se ha modificado ningun proceso ni tarea.'

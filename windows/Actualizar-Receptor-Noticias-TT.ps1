#requires -Version 5.1
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='488e1ed580b9c744bdf5a43a42e01493b39bac34'
$expected='1788962e76fce00891f74027afba349f82d195e94ac8c2e06929cfdf2fa1bd37'
$node=(Get-Command node.exe -ErrorAction Stop).Source
$taskName='TT Actualidad - Imagenes pendientes APP'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if([IO.Path]::GetFileName($task.Actions.Execute) -ne 'wscript.exe'){throw 'Se requiere el lanzador WScript oculto ya instalado. Sin cambios.'}
foreach($name in @('TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs')) {
 $source=[IO.File]::ReadAllText((Join-Path $base $name))
 if(-not $source.Contains("return {status:'waiting',reason:'manual_approval_required'}")){throw 'Falta la pausa de asociacion. No se cambia nada.'}
 if(-not $source.Contains('data-user-message-bubble')){throw 'Falta el lector de burbujas actualizado. No se cambia nada.'}
}
$destination=Join-Path $base 'TTImageApprovalReceiver.cjs'
$temporary=Join-Path $env:TEMP ('TT-NewsReceiver-'+[guid]::NewGuid().ToString('N')+'.cjs')
$backup=$destination+'.'+(Get-Date -Format yyyyMMdd-HHmmss)+'.bak'
try {
 Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/TTImageApprovalReceiver.cjs') -OutFile $temporary -TimeoutSec 40
 if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'SHA del receptor incorrecto. Sin instalar.'}
 & $node --check $temporary
 if($LASTEXITCODE -ne 0){throw 'El receptor no supera sintaxis. Sin instalar.'}
 Copy-Item -LiteralPath $destination -Destination $backup
 Copy-Item -LiteralPath $temporary -Destination ($destination+'.new') -Force
 Move-Item -LiteralPath ($destination+'.new') -Destination $destination -Force
 # Preserve existing repetition, principal and hidden action; add login recovery.
 $triggers=@($task.Triggers)
 if(-not @($triggers | Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'}).Count){$triggers+=New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)}
 $task.Settings.StartWhenAvailable=$true
 Set-ScheduledTask -TaskName $taskName -Trigger $triggers -Settings $task.Settings | Out-Null
 Write-Host 'Receptor actualizado: Noticias y Tendencias recuperan conversaciones exactas en el relay privado.'
 Write-Host 'Arranque al iniciar sesion y accion oculta conservados. El siguiente ciclo recogera pendientes.'
 Write-Host ('Backup: '+$backup)
 Write-Host 'No se han reiniciado Chrome, listeners ni generadores. No se ha aprobado ni publicado ninguna imagen.'
} finally {Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue}

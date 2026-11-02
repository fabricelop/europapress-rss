#requires -Version 5.1
$ErrorActionPreference='Stop'
$name='TT Actualidad - Imagenes pendientes APP'
$base='C:\TTiTTulares'
$task=Get-ScheduledTask -TaskName $name -ErrorAction Stop
$dest=Join-Path $base 'TTImageApprovalReceiver.cjs'
if(-not(Test-Path -LiteralPath $dest)){throw 'No existe el receptor. Sin cambios.'}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$launcher=Join-Path $base 'TTImageApprovalReceiver-Hidden.vbs'
$backup=Join-Path $base ('image-inbox-task-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.xml')
Export-ScheduledTask -TaskName $name | Set-Content -LiteralPath $backup -Encoding Unicode
# WScript starts Node hidden and waits, preserving IgnoreNew and the task result.
$command='"'+$node+'" "'+$dest+'"'
$vbs='Set shell = CreateObject("WScript.Shell")'+"`r`n"+'shell.CurrentDirectory = "'+$base.Replace('"','""')+'"'+"`r`n"+'result = shell.Run("'+$command.Replace('"','""')+'", 0, True)'+"`r`n"+'WScript.Quit result'+"`r`n"
[IO.File]::WriteAllText($launcher,$vbs,[Text.Encoding]::Unicode)
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
$action=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //NoLogo "'+$launcher+'"') -WorkingDirectory $base
Set-ScheduledTask -TaskName $name -Action $action | Out-Null
$updated=Get-ScheduledTask -TaskName $name
if($updated.Actions.Execute -ne $wscript){throw 'No se pudo verificar el lanzador oculto.'}
Write-Host 'Tarea actualizada: proximas ejecuciones sin consola visible.' -ForegroundColor Green
Write-Host 'Se conservan receptor, frecuencia, aprobacion manual y procesos en curso.'
Write-Host ('Backup: '+$backup)

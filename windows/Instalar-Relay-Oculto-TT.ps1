#requires -Version 5.1
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='0152c4101ca13ca8c6293306b7927cd598e03e19'
$hash='1c67c0073bf7d32f1715152c2aed3e1ceee8eaa91f8f113a8dd601b2ade3d1c2'
$guard=Join-Path $base 'TT-Relay9234-Guard.ps1'
$launcher=Join-Path $base 'TT-Relay9234-Hidden.vbs'
if(-not(Test-Path -LiteralPath $base)){throw 'Falta la instalacion TT actual.'}
$task=Get-ScheduledTask -TaskName 'TT Actualidad - Imagenes pendientes APP' -ErrorAction Stop
if([IO.Path]::GetFileName($task.Actions.Execute) -ne 'wscript.exe'){throw 'La bandeja debe conservar su accion oculta.'}
$backup=Join-Path $base ('startup-hidden-backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $backup | Out-Null
$temp=Join-Path $env:TEMP ('TT-RelayGuard-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
 Invoke-WebRequest -UseBasicParsing ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/TT-Relay9234-Guard.ps1') -OutFile $temp -TimeoutSec 40
 if((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash){throw 'SHA del guard incorrecto. Sin instalar.'}
 $tokens=$null;$errors=$null
 [Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)|Out-Null
 if($errors.Count){throw 'Guard con errores de sintaxis. Sin instalar.'}
 if(Test-Path -LiteralPath $guard){Copy-Item -LiteralPath $guard -Destination $backup}
 Copy-Item -LiteralPath $temp -Destination $guard -Force
 $command='powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$guard+'"'
 [IO.File]::WriteAllText($launcher,('CreateObject("WScript.Shell").Run "'+$command.Replace('"','""')+'",0,True'),[Text.Encoding]::Unicode)
 $action=New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') -Argument ('//B //NoLogo "'+$launcher+'"') -WorkingDirectory $base
 $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
 $triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $user),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)))
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -StartWhenAvailable
 $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
 Register-ScheduledTask -TaskName 'TT Actualidad - Relay 9234 oculto' -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
 # Convert only the four exact, single-command legacy launchers shown in the audit.
 $startup=[Environment]::GetFolderPath('Startup')
 $entries=@{'TT Auto Updater.cmd'='TT-AutoUpdater.ps1';'TT Automation Watchdog.cmd'='TT-LocalWatchdog.ps1';'TTendencias Mobile Trigger Listener.cmd'='TTendenciasDedicatedListener.ps1';'TTiTTulares Mobile Trigger Listener.cmd'='TTiTTularesDedicatedListener.ps1'}
 foreach($entry in $entries.GetEnumerator()) {
  $old=Join-Path $startup $entry.Key
  if(-not(Test-Path -LiteralPath $old)){continue}
  $lines=@([IO.File]::ReadAllLines($old)|Where-Object {$_.Trim() -and $_ -notmatch '^\s*@?echo\s+off\s*$'})
  if($lines.Count -ne 1){Write-Host ('CONSERVADO por formato no reconocido: '+$entry.Key);continue}
  $m=[regex]::Match($lines[0],'^\s*start\s+""\s+powershell(?:\.exe)?\s+(.+?)\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if(-not $m.Success){Write-Host ('CONSERVADO por comando no reconocido: '+$entry.Key);continue}
  $argsLine=$m.Groups[1].Value
  if($argsLine -notmatch '(?i)-WindowStyle\s+Hidden' -or $argsLine -notmatch ('(?i)-File\s+"?'+[regex]::Escape((Join-Path $base $entry.Value))+'"?\s*$')){Write-Host ('CONSERVADO por destino no reconocido: '+$entry.Key);continue}
  $out=[IO.Path]::ChangeExtension($old,'.vbs')
  if((Test-Path -LiteralPath $out) -and -not([IO.File]::ReadAllText($out).Contains('TTActualidad hidden startup v1'))){Write-Host ('CONSERVADO: existe VBS ajeno para '+$entry.Key);continue}
  Copy-Item -LiteralPath $old -Destination $backup
  $text="' TTActualidad hidden startup v1"+[Environment]::NewLine+'CreateObject("WScript.Shell").Run "'+('powershell.exe '+$argsLine).Replace('"','""')+'",0,False'
  [IO.File]::WriteAllText($out,$text,[Text.Encoding]::Unicode)
  Move-Item -LiteralPath $old -Destination ($old+'.disabled-'+(Get-Date -Format yyyyMMddHHmmss))
  Write-Host ('Inicio oculto convertido: '+$entry.Key)
 }
 # Manual execution is visible only in this user-invoked PowerShell; Chrome is headless.
 & $guard
 Write-Host ('Backup: '+$backup)
 Write-Host 'No se han detenido procesos. Chrome 9223 y las tareas existentes se conservan.'
 $log=Join-Path $base 'relay9234-guard.log'
 if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log -Tail 2}
} finally {Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}

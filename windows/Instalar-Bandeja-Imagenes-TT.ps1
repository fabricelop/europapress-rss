#requires -Version 5.1
# Separate private receiver; never restarts generators, Chrome or listeners.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='0ea0a1d53ad2f77fe5c6ba5a0ccc03db9d58dfcb'
$expected='92f1fbfe3d35afd14263f76df3e802fd8ec8f4913213da3667bb41da00b8ed5d'
$node=(Get-Command node.exe -ErrorAction Stop).Source
foreach($name in @('TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs')) {
 $p=Join-Path $base $name
 if(-not(Test-Path -LiteralPath $p)){throw ('Falta '+$name+'. Aplica primero Pausar-Asociacion-Automatica-TT.ps1.')}
 if(-not([IO.File]::ReadAllText($p).Contains("return {status:'waiting',reason:'manual_approval_required'}"))){throw ('La pausa no esta instalada en '+$name+'. No se activa el receptor.')}
}
$dest=Join-Path $base 'TTImageApprovalReceiver.cjs'
$temp=Join-Path $env:TEMP ('TT-PrivateReceiver-'+[guid]::NewGuid().ToString('N')+'.cjs')
try {
 Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/TTImageApprovalReceiver.cjs') -OutFile $temp -TimeoutSec 40
 if((Get-FileHash -Algorithm SHA256 -LiteralPath $temp).Hash.ToLowerInvariant() -ne $expected){throw 'No coincide el SHA del receptor. Sin instalar.'}
 & $node --check $temp
 if($LASTEXITCODE -ne 0){throw 'El receptor no supera la validacion de sintaxis.'}
 if(Test-Path -LiteralPath $dest){Copy-Item -LiteralPath $dest -Destination ($dest+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak')}
 Copy-Item -LiteralPath $temp -Destination $dest -Force
 $action=New-ScheduledTaskAction -Execute $node -Argument ('"'+$dest+'"') -WorkingDirectory $base
 $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
 $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 8) -StartWhenAvailable
 Register-ScheduledTask -TaskName 'TT Actualidad - Imagenes pendientes APP' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
 Start-ScheduledTask -TaskName 'TT Actualidad - Imagenes pendientes APP'
 Write-Host 'Receptor privado instalado. La aprobacion se hace solo en APP; no se publica automaticamente.' -ForegroundColor Green
 Write-Host 'Solo recupera PNGs de conversaciones existentes y reconocidas. No genera ni abre pestanas.'
} finally {Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}

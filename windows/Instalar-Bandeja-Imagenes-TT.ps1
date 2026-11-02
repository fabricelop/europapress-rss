#requires -Version 5.1
# Separate private receiver; never restarts generators, Chrome or listeners.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='11421928b5c9bda3f35e0090edd2b9a9abd6651a'
$expected='1299dbaabdd856cdd773cea71ed280c7dea5c34b67fc6d02601d1c32ed7eae58'
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
 Write-Host 'Solo recupera PNGs de conversaciones reconocidas. Si hace falta, usa una pestana temporal del relay 9234; nunca escribe ni genera.'
} finally {Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}

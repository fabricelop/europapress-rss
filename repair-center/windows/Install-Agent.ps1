#requires -Version 5.1
# Instala el agente como tarea no intrusiva. No inicia ningún otro proyecto.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Windows PowerShell 5.1: DPAPI lives in System.Security.dll.
Add-Type -AssemblyName System.Security
$base=Join-Path $env:LOCALAPPDATA 'CentroReparaciones'
New-Item -ItemType Directory -Force -Path $base | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Agent.ps1') -Destination (Join-Path $base 'Agent.ps1') -Force
$cfgPath=Join-Path $base 'agent-config.json'
if(-not (Test-Path $cfgPath)){
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'agent-config.example.json') -Destination $cfgPath
  Write-Host "EDITAR antes de usar: $cfgPath" -ForegroundColor Yellow
}
$secured=Read-Host 'Introducir AGENT_KEY de Cloudflare (no se mostrará)' -AsSecureString
$bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secured)
try{ $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
if($plain.Length -lt 32){throw 'La clave requiere al menos 32 caracteres'}
$raw=[Text.Encoding]::UTF8.GetBytes($plain)
$encrypted=[System.Security.Cryptography.ProtectedData]::Protect($raw,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
[Array]::Clear($raw,0,$raw.Length)
[IO.File]::WriteAllText((Join-Path $base 'agent-key.bin'),[Convert]::ToBase64String($encrypted))
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $base 'Agent.ps1')+'"')
$trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName 'CentroReparaciones-OnDemand' -Action $action -Trigger $trigger -Settings $settings -Description 'Solo consulta órdenes explícitas; no diagnostica ni repara continuamente' -Force | Out-Null
Write-Host 'Agente instalado. NO reinicia nada hasta recibir orden y estar configurada la tarea exacta.' -ForegroundColor Green
Write-Host 'Configurar las tareas en: ' $cfgPath

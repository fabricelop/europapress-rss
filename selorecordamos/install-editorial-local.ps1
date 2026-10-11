$ErrorActionPreference='Stop'
$runner=Join-Path $PSScriptRoot 'run-editorial-local.ps1'
$task='SeLoRecordamos-Editorial-Local'
if (-not (Test-Path $runner)) { throw 'Falta run-editorial-local.ps1' }
try {
    $response=Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 5
} catch { throw 'Ollama no responde en localhost:11434. Instala Ollama e inicia el servicio antes de activar la tarea.' }
$model=if ($env:SR_OLLAMA_MODEL) {$env:SR_OLLAMA_MODEL} else {'qwen2.5:7b'}
if (-not @($response.models | ForEach-Object name).Contains($model)) { throw "El modelo $model no está instalado. Ejecuta: ollama pull $model" }
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$runner+'"')
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
$user=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
Write-Host "Instalada tarea $task; primera ejecución solicitada. Comprobar runtime/editorial-local.log."

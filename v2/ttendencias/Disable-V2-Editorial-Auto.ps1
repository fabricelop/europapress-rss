# Detener el consumidor V2 con seguridad: no interrumpir un chat en marcha.
# Dejar que complete su tendencia y luego terminar la sesión automática.
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$flag=Join-Path $root 'auto-editorial-v2.enabled'
if (Test-Path -LiteralPath $flag) {
    [IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=NO" + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false)))
}
$taskName='TTActualidadV2-Editorial-Auto'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) { Disable-ScheduledTask -TaskName $taskName | Out-Null }
Write-Host 'TT_V2_AUTO_ENABLED=NO'
Write-Host 'TT_V2_AUTO_TASK_DISABLED=YES'
Write-Host 'TT_V2_RUNNING_CHAT_ALLOWED_TO_FINISH=YES'
Write-Host 'TT_V2_PUBLISHED=NO'

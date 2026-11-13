# TTActualidad V2: cambiar de forma segura a consola y Chrome OCULTOS.
# Espera únicamente a que la elaboración ya iniciada termine; no cierra
# Chrome, no mata tareas, no reenvía chats y no modifica V1.
$ErrorActionPreference='Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
New-Item -ItemType Directory -Path $root -Force | Out-Null

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Write-Host 'TT_V2_OLD_AUTO_DISABLED=YES'
}
[IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=NO" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'TT_V2_DRAIN_ACTIVE_CHAT=YES'
$deadline = (Get-Date).AddMinutes(30)
do {
    $proc = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
            ($_.Name -match '^(python|pythonw|py)(\.exe)?$') -and
            $_.CommandLine -like '*TTActualidadV2*editorial_daemon_v2.py*'
        })
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($proc.Count -eq 0 -and (!$task -or $task.State -ne 'Running')) { break }
    if ((Get-Date) -ge $deadline) {
        throw 'V2 aún ocupado. Se conserva el estado y la tarea desactivada; no se interrumpe ningún chat.'
    }
    Start-Sleep -Seconds 5
} while ($true)
Write-Host 'TT_V2_DRAIN_COMPLETED=YES'

# Descargar el instalador desde el commit completo actual de la rama V2.
$repo='fabricelop/europapress-rss'
$branch='feature/ttactualidad-v2-clean'
$headers=@{'User-Agent'='TTActualidadV2-hidden-upgrade';'Accept'='application/vnd.github+json'}
$head=Invoke-RestMethod -Uri ('https://api.github.com/repos/'+$repo+'/commits/'+[Uri]::EscapeDataString($branch)) -Headers $headers -UseBasicParsing
$sha=[string]$head.sha
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'Commit no verificable' }
$installer=Join-Path $root 'Install-V2-Editorial-Auto.ps1'
$url='https://raw.githubusercontent.com/'+$repo+'/'+$sha+'/v2/ttendencias/Install-V2-Editorial-Auto.ps1'
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -Headers $headers
Write-Host ('TT_V2_UPGRADE_SOURCE_COMMIT='+$sha)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
if ($LASTEXITCODE -ne 0) {
    throw ('Instalador V2 oculto terminó con error '+$LASTEXITCODE)
}
Write-Host 'TT_V2_HIDDEN_UPGRADE_INSTALLED=YES'

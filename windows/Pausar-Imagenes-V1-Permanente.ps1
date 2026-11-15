# Pausa SOLO ImageGen V1 en TTendencias y TTiTTulares, incluidos reinicios.
# No para la redacción, Telegram, X, V2 ni los receptores de imágenes ya hechas.
$ErrorActionPreference = 'Stop'
$root = 'C:\TTiTTulares'
$flag = Join-Path $root 'V1-ImageGen-Paused.flag'
$repoUrl = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/'
$names = @('TTendenciasDedicatedListener.ps1','TTiTTularesDedicatedListener.ps1')
if (!(Test-Path -LiteralPath $root -PathType Container)) { throw 'No existe C:\TTiTTulares; ninguna tarea modificada.' }

# Primero asegurar que ambos listeners nuevos respetan la pausa; descargar a
# temporales, nunca actualizar uno si el otro no pasa las comprobaciones.
$downloads = @{}
try {
  foreach ($name in $names) {
    $local = Join-Path $root $name
    if (!(Test-Path -LiteralPath $local -PathType Leaf)) { throw ('Falta listener local: ' + $local) }
    $download = Join-Path $env:TEMP ('TT-V1-Pause-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $downloads[$name] = $download
    Invoke-WebRequest -Uri ($repoUrl + $name) -OutFile $download -UseBasicParsing -TimeoutSec 30
    if ((Get-Item -LiteralPath $download).Length -lt 20000 -or
        !(Select-String -LiteralPath $download -Pattern 'V1-ImageGen-Paused.flag' -SimpleMatch -Quiet) -or
        !(Select-String -LiteralPath $download -Pattern 'IMAGE V1 PAUSED' -SimpleMatch -Quiet)) {
      throw ('No se ha recibido la versión protegida de ' + $name)
    }
  }

  # Este archivo queda en disco después de reiniciar y es respetado por ambos
  # listeners, incluso cuando su actualizador los vuelva a instalar.
  [IO.File]::WriteAllText($flag, "V1_IMAGEGEN_PAUSED=YES`r`n", (New-Object System.Text.UTF8Encoding($false)))
  Write-Host 'V1_IMAGEGEN_PAUSA_PERSISTENTE=SI'

  $backup = Join-Path $env:LOCALAPPDATA 'TTActualidadV1-ImageGen-Backup'
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach ($name in $names) {
    $local = Join-Path $root $name
    Copy-Item -LiteralPath $local -Destination (Join-Path $backup ($stamp + '-' + $name)) -ErrorAction Stop
    Copy-Item -LiteralPath $downloads[$name] -Destination $local -Force -ErrorAction Stop
    Write-Host ('V1_LISTENER_PROTEGIDO=' + $name)
  }

  # Desactivar únicamente tareas que lancen los bridges de ImageGen V1,
  # más la tarea antigua de imágenes pendientes que el usuario pidió parar.
  foreach ($task in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    $actions = @($task.Actions)
    $isBridgeTask = @($actions | Where-Object {
      ([string]$_.Execute + ' ' + [string]$_.Arguments) -match '(?i)TT(?:iTTulares|endencias)ImageBridge\.js'
    }).Count -gt 0
    $isLegacyPending = $task.TaskName -eq 'TT Actualidad - Imagenes pendientes APP'
    if ($isBridgeTask -or $isLegacyPending) {
      if ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop
        Write-Host ('V1_TAREA_GENERACION_DETENIDA=' + $task.TaskName)
      }
      if ($task.State -ne 'Disabled') {
        Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop | Out-Null
        Write-Host ('V1_TAREA_GENERACION_DESACTIVADA=' + $task.TaskName)
      }
    }
  }

  function Find-V1Process([string]$name,[string[]]$exes) {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -in $exes -and [string]$_.CommandLine -match [regex]::Escape($name)
    })
  }

  # Apagar solo el proceso generador; jamás cerrar Chrome ni Ejecutar.js.
  foreach ($name in @('TTendenciasImageBridge.js','TTiTTularesImageBridge.js')) {
    foreach ($proc in (Find-V1Process $name @('node.exe'))) {
      Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
      Write-Host ('V1_BRIDGE_DETENIDO=' + $name)
    }
  }

  # Los listeners que estaban vivos deben recargar el nuevo código;
  # reiniciar SOLO esos dos. La automatización editorial sigue igual.
  foreach ($name in $names) {
    $running = @(Find-V1Process $name @('powershell.exe','pwsh.exe'))
    if (!$running.Count) {
      Write-Host ('V1_LISTENER_NO_ESTABA_ACTIVO=' + $name)
      continue
    }
    foreach ($proc in $running) {
      Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
    }
    Start-Sleep -Milliseconds 500
    if (@(Find-V1Process $name @('powershell.exe','pwsh.exe')).Count -eq 0) {
      $script = Join-Path $root $name
      $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'
      $started = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru -ErrorAction Stop
      Write-Host ('V1_LISTENER_EDITORIAL_REINICIADO=' + $name + ';PID=' + $started.Id)
    } else {
      Write-Host ('V1_LISTENER_REINICIADO_POR_WATCHDOG=' + $name)
    }
  }

  # Verificación: flag y versión del código; no reactivar tareas de imágenes.
  if (!(Test-Path -LiteralPath $flag)) { throw 'Falta el bloqueo persistente' }
  foreach ($name in $names) {
    if (!(Select-String -LiteralPath (Join-Path $root $name) -Pattern 'V1-ImageGen-Paused.flag' -SimpleMatch -Quiet)) {
      throw ('El listener sigue sin protección: ' + $name)
    }
  }
  foreach ($name in @('TTendenciasImageBridge.js','TTiTTularesImageBridge.js')) {
    if (@(Find-V1Process $name @('node.exe')).Count -ne 0) {
      throw ('Queda un generador V1 activo: ' + $name)
    }
  }
  Write-Host 'V1_IMAGEGEN_DETENIDO_Y_BLOQUEADO_TRAS_REINICIO=SI'
  Write-Host 'V2_EDITORIAL_Y_PUBLICACIONES=NO_MODIFICADAS'
  Write-Host ('V1_COPIAS_DE_SEGURIDAD=' + $backup)
} finally {
  foreach ($path in $downloads.Values) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  }
}

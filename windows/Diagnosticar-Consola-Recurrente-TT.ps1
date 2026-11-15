#requires -Version 5.1
<#
  Diagnostico SIN CAMBIOS: identifica el proceso/tarea responsable de
  una consola que aparece periodicamente en Windows.
  No lee secretos ni imprime argumentos completos de los procesos.
#>
[CmdletBinding()]
param([ValidateRange(0,600)][int]$ObservarSegundos = 210)
$ErrorActionPreference = 'Stop'
$started = Get-Date
$recent = $started.AddMinutes(-35)
$observed = New-Object 'System.Collections.Generic.List[object]'

function Script-Visible([string]$linea) {
  if (-not $linea) { return '-' }
  $match = [regex]::Match($linea, '(?i)([\w .()_-]+\.(?:ps1|vbs|cmd|bat|js|cjs))(?=["\s]|$)')
  if ($match.Success) { return $match.Groups[1].Value.Trim() }
  return '-'
}
function Proceso([int]$id) {
  try { return Get-CimInstance Win32_Process -Filter ("ProcessId=$id") -ErrorAction Stop }
  catch { return $null }
}
function Mostrar-Tareas-Recientes([datetime]$desde) {
  Write-Host ''
  Write-Host '=== INICIOS RECIENTES DEL PROGRAMADOR DE TAREAS ==='
  $rows = @()
  try {
    $events = @(Get-WinEvent -FilterHashtable @{
      LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=200; StartTime=$desde
    } -MaxEvents 1000 -ErrorAction Stop)
    foreach ($evt in $events) {
      try {
        $xml = [xml]$evt.ToXml()
        $taskName = ''
        $actionName = ''
        foreach ($item in @($xml.Event.EventData.Data)) {
          if ($item.Name -eq 'TaskName') { $taskName = [string]$item.'#text' }
          if ($item.Name -eq 'ActionName') { $actionName = [string]$item.'#text' }
        }
        if ($taskName) {
          $rows += [pscustomobject]@{ Fecha=$evt.TimeCreated; Tarea=$taskName; Ejecutable=([IO.Path]::GetFileName($actionName)) }
        }
      } catch {}
    }
  } catch {
    Write-Host 'HISTORIAL_NO_DISPONIBLE (es habitual si no esta activado).'
  }
  if ($rows.Count -eq 0) { Write-Host 'SIN_EVENTOS_DE_INICIO'; return }
  $out = @(
    foreach ($group in ($rows | Group-Object Tarea)) {
      $ordered = @($group.Group | Sort-Object Fecha)
      $gaps = @()
      for ($i=1; $i -lt $ordered.Count; $i++) {
        $seconds = ($ordered[$i].Fecha - $ordered[$i-1].Fecha).TotalSeconds
        if ($seconds -gt 15 -and $seconds -lt 1200) { $gaps += $seconds }
      }
      $median = 0
      if ($gaps.Count -gt 0) {
        $sorted = @($gaps | Sort-Object)
        $median = [math]::Round([double]$sorted[[int][math]::Floor($sorted.Count / 2)] / 60,1)
      }
      [pscustomobject]@{ Tarea=$group.Name; Veces=$ordered.Count; IntervaloMin=$median;
        Ultima=$ordered[-1].Fecha.ToString('HH:mm:ss'); Ejecutable=$ordered[-1].Ejecutable }
    }
  )
  $likely = @($out | Where-Object { $_.Veces -ge 2 -and $_.IntervaloMin -ge 1 -and $_.IntervaloMin -le 6 } |
    Sort-Object @{Expression='Veces';Descending=$true} | Select-Object -First 25)
  if ($likely.Count -gt 0) {
    Write-Host 'CANDIDATAS_CON_INTERVALO_1_A_6_MINUTOS:'
    $likely | Format-Table -AutoSize | Out-String -Width 190 | Write-Host
  } else { Write-Host 'SIN_TAREAS_REPETIDAS_EN_INTERVALO_1_A_6_MINUTOS' }
  Write-Host 'ULTIMAS_15_TAREAS_INICIADAS:'
  $rows | Sort-Object Fecha -Descending | Select-Object -First 15 |
    Format-Table -AutoSize | Out-String -Width 190 | Write-Host
}

Write-Host 'TT_CONSOLA_AUDITORIA=SOLO_LECTURA'
Write-Host ('INICIO=' + $started.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host '=== TAREAS PROGRAMADAS TT Y DE INTERVALO CORTO ==='
try {
  $taskRows = @(
    foreach ($task in (Get-ScheduledTask -ErrorAction Stop)) {
      $intervals = @($task.Triggers | ForEach-Object { [string]$_.Repetition.Interval } | Where-Object { $_ })
      $frequent = @($intervals | Where-Object {
        $_ -match '^PT[1-6]M$|^00:0[1-6]:00$|^0[1-6]:00$'
      }).Count -gt 0
      if (-not $frequent -and $task.TaskName -notmatch '(?i)TT|SeLoRecordamos|Actualidad|ImageRelay') { continue }
      $last = '-'
      try { $last = (Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath).LastRunTime.ToString('HH:mm:ss') } catch {}
      $actionNames = @($task.Actions | ForEach-Object { [IO.Path]::GetFileName([string]$_.Execute) })
      $scripts = @($task.Actions | ForEach-Object { Script-Visible ([string]$_.Arguments) } | Where-Object { $_ -ne '-' })
      [pscustomobject]@{ Tarea=$task.TaskName; Estado=[string]$task.State;
        Cada=($intervals -join ','); Ultima=$last; Ejecutable=($actionNames -join ','); Script=($scripts -join ',') }
    }
  )
  $taskRows | Sort-Object Tarea | Format-Table -AutoSize |
    Out-String -Width 230 | Write-Host
} catch { Write-Host 'ERROR_ENUMERANDO_TAREAS' }

if ($ObservarSegundos -gt 0) {
  Write-Host ('=== OBSERVANDO PROCESOS DURANTE ' + $ObservarSegundos + ' SEGUNDOS ===')
  Write-Host 'Deja esta ventana abierta hasta que aparezca otra vez la consola.'
  $source = 'TTConsolaDiagnostico' + [guid]::NewGuid().ToString('N')
  $registered = $false
  try {
    Register-WmiEvent -Class Win32_ProcessStartTrace -SourceIdentifier $source -ErrorAction Stop | Out-Null
    $registered = $true
    $until = (Get-Date).AddSeconds($ObservarSegundos)
    while ((Get-Date) -lt $until) {
      $event = Wait-Event -SourceIdentifier $source -Timeout 2
      if ($null -eq $event) { continue }
      try {
        $e = $event.SourceEventArgs.NewEvent
        $exe = [string]$e.ProcessName
        if ($exe -notmatch '^(?i:cmd|powershell|pwsh|conhost|wscript|cscript|node)\.exe$') { continue }
        $pidFound = [int]$e.ProcessID
        $parentPid = [int]$e.ParentProcessID
        $process = Proceso $pidFound
        $parent = Proceso $parentPid
        $observed.Add([pscustomobject]@{ Hora=(Get-Date).ToString('HH:mm:ss');
          Proceso=$exe; PID=$pidFound; Padre=if($parent){[string]$parent.Name}else{'PID '+$parentPid};
          Script=if($process){Script-Visible ([string]$process.CommandLine)}else{'-' } })
      } finally { Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue }
    }
  } catch { Write-Host ('MONITOR_NO_DISPONIBLE: ' + $_.Exception.Message) }
  finally {
    if ($registered) { Unregister-Event -SourceIdentifier $source -ErrorAction SilentlyContinue }
  }
  Write-Host '=== PROCESOS DE CONSOLA OBSERVADOS ==='
  if ($observed.Count) {
    $observed | Format-Table -AutoSize | Out-String -Width 190 | Write-Host
  } else { Write-Host 'SIN_PROCESOS_DE_CONSOLA_OBSERVADOS' }
}

Mostrar-Tareas-Recientes $recent
Write-Host 'TT_CONSOLA_AUDITORIA_FIN=SI; NO_SE_HA_MODIFICADO_NADA'

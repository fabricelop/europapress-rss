# Repara las ventanas de consola de TTActualidad V2 sin alterar desencadenadores.
# No inicia, detiene, habilita ni deshabilita ninguna tarea. No toca V1.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$backupRoot = Join-Path $root 'TaskBackups-Consola'
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$wrapper = Join-Path $root 'Launch-V2-Hidden.vbs'
$vbs = @'
Option Explicit
Dim shell, script, binary, cmd, result
If WScript.Arguments.Count <> 1 Then WScript.Quit 2
script = WScript.Arguments(0)
Set shell = CreateObject("WScript.Shell")
binary = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & binary & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(script, """", "") & """"
result = shell.Run(cmd, 0, True)
WScript.Quit result
'@
[IO.File]::WriteAllText($wrapper, $vbs, (New-Object System.Text.UTF8Encoding($false)))
$windowsWscript = Join-Path $env:WINDIR 'System32\wscript.exe'
if (!(Test-Path -LiteralPath $windowsWscript)) { throw 'Windows Script Host no disponible' }

$targets = @(
    @{ Task='TTActualidadV2-Editorial-Auto'; Runner='Run-V2-Editorial-Auto.ps1' },
    @{ Task='TTActualidadV2-Images-Auto'; Runner='Run-V2-Images-Auto.ps1' },
    @{ Task='TTActualidadV2-Top30-15m'; Runner='Run-V2-Top30-Tick.ps1' }
)
foreach ($target in $targets) {
    $task = Get-ScheduledTask -TaskName $target.Task -ErrorAction SilentlyContinue
    if (!$task) { Write-Host ('TT_V2_NO_EXISTE=' + $target.Task); continue }
    if (@($task.Actions).Count -ne 1) {
        Write-Host ('TT_V2_NO_MODIFICADA_ACCIONES_INESPERADAS=' + $target.Task)
        continue
    }
    $oldAction = $task.Actions[0]
    $runner = Join-Path $root $target.Runner
    if (!(Test-Path -LiteralPath $runner)) {
        Write-Host ('TT_V2_NO_MODIFICADA_FALTA_RUNNER=' + $target.Task)
        continue
    }
    $isOwnAction = ($oldAction.Execute -match '(?i)(^|[\\/])powershell\.exe$' -and
                    $oldAction.Arguments -like ('*' + $target.Runner + '*'))
    $alreadyHidden = ($oldAction.Execute -match '(?i)(^|[\\/])wscript\.exe$' -and
                      $oldAction.Arguments -like ('*' + $target.Runner + '*'))
    if (!$isOwnAction -and !$alreadyHidden) {
        Write-Host ('TT_V2_NO_MODIFICADA_ACCION_DISTINTA=' + $target.Task)
        continue
    }
    $oldState = [string]$task.State
    if ($alreadyHidden) {
        Write-Host ('TT_V2_YA_OCULTA=' + $target.Task + ';ESTADO=' + $oldState)
        continue
    }
    # Guardar XML recuperable antes de sustituir la accion. No se modifican
    # trigger, principal, credenciales, estado, ni periodicidad de la tarea.
    $backup = Join-Path $backupRoot ($target.Task + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.xml')
    $xml = Export-ScheduledTask -TaskName $target.Task -TaskPath $task.TaskPath -ErrorAction Stop
    [IO.File]::WriteAllText($backup, $xml, (New-Object System.Text.UTF8Encoding($false)))
    $args = '//B //Nologo "' + $wrapper + '" "' + $runner + '"'
    if ($oldAction.WorkingDirectory) {
        $newAction = New-ScheduledTaskAction -Execute $windowsWscript -Argument $args -WorkingDirectory $oldAction.WorkingDirectory
    } else {
        $newAction = New-ScheduledTaskAction -Execute $windowsWscript -Argument $args
    }
    Set-ScheduledTask -TaskPath $task.TaskPath -TaskName $target.Task -Action $newAction | Out-Null
    $updated = Get-ScheduledTask -TaskPath $task.TaskPath -TaskName $target.Task
    if ($updated.Actions[0].Execute -notmatch '(?i)wscript\.exe$') { throw ('No se reparó: ' + $target.Task) }
    if ($oldState -eq 'Disabled' -and $updated.State -ne 'Disabled') { throw ('Se ha cambiado indebidamente el estado de: ' + $target.Task) }
    Write-Host ('TT_V2_CONSOLA_OCULTA=' + $target.Task + ';ANTES=' + $oldState + ';DESPUES=' + $updated.State)
    Write-Host ('TT_V2_TAREA_BACKUP=' + $backup)
}

# Diagnóstico de otras tareas del propio Windows: solo lectura y sin argumentos.
# Si siguiera apareciendo la ventana, los últimos inicios ayudan a identificarla.
$cutoff = (Get-Date).AddHours(-3)
foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    $actions = @($task.Actions | Where-Object {
        $_.Execute -match '(?i)(powershell|pwsh|cmd|conhost|python|py|cscript)\.exe$'
    })
    if (!$actions.Count) { continue }
    $info = Get-ScheduledTaskInfo -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction SilentlyContinue
    if (!$info -or $info.LastRunTime -lt $cutoff) { continue }
    Write-Host ('TT_POSIBLE_CONSOLA=' + $task.TaskPath + $task.TaskName + ';ULTIMA=' + $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') + ';ESTADO=' + $task.State)
}
Write-Host 'TT_V2_REPARACION_CONSOLAS_FINALIZADA=SI'

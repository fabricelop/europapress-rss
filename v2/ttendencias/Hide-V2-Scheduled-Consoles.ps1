# TTActualidad V2: eliminar parpadeos de consolas sin detener el consumidor.
# Preparado para ejecucion MANUAL; no publica ni modifica V1.
# Sustituye solo la accion de las tareas V2 conocidas por WScript oculto.
# Set-ScheduledTask no modifica una instancia ya en ejecucion.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$report = Join-Path $root 'v2-console-hidden-fix-report.txt'
New-Item -ItemType Directory -Path $root -Force | Out-Null
Set-Content -LiteralPath $report -Value ('TT_V2_HIDE_FIX_STARTED=' + [DateTimeOffset]::UtcNow.ToString('o')) -Encoding UTF8
function Note([string]$key, [string]$value) {
    $line = $key + '=' + $value
    Write-Host $line
    Add-Content -LiteralPath $report -Value $line -Encoding UTF8
}
function AsLaunchText([string]$runner) {
    # ASCII only. Expand paths at launch, not while writing the .vbs file.
    $template = @'
Option Explicit
Dim shell, ps, runner, command, result
Set shell = CreateObject("WScript.Shell")
ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
runner = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\TTActualidadV2\RUNNER_FILE")
command = Chr(34) & ps & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & runner & Chr(34)
result = shell.Run(command, 0, True)
WScript.Quit result
'@
    return $template.Replace('RUNNER_FILE', $runner)
}
function PatchTask([string]$name, [string]$scriptName, [string]$vbsName, [bool]$required) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (!$task) {
        if ($required) { throw ('No existe la tarea V2 requerida: ' + $name) }
        Note 'TT_V2_OPTIONAL_TASK' ($name + ':NOT_INSTALLED')
        return
    }
    $runner = Join-Path $root $scriptName
    if (!(Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw ('La tarea existe, pero falta su runner: ' + $runner)
    }
    $actions = @($task.Actions)
    if ($actions.Count -ne 1) { throw ('Acciones inesperadas en ' + $name) }
    $previous = $actions[0]
    $exe = [string]$previous.Execute
    $args = [string]$previous.Arguments
    # No modificar una tarea que no ejecute ya su runner V2 especifico.
    $alreadySilent = (($exe -match '(?i)(?:^|[\\/])wscript\.exe$') -and
        ($args -match [regex]::Escape($vbsName)))
    $allowedOld = (($exe -match '(?i)(?:^|[\\/])(?:powershell|pwsh)\.exe$') -and
        ($args -match [regex]::Escape($scriptName)))
    if (!$allowedOld -and !$alreadySilent) {
        throw ('La tarea no usa el runner V2 esperado: ' + $name)
    }
    $backup = Join-Path $root ('backup-' + $name + '-before-silent.xml')
    $vbsPath = Join-Path $root $vbsName
    [IO.File]::WriteAllText($vbsPath, (AsLaunchText $scriptName), [System.Text.Encoding]::ASCII)
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (!(Test-Path -LiteralPath $wscript -PathType Leaf)) { throw 'Windows Script Host no disponible' }
    $newArgs = '//B //Nologo "' + $vbsPath + '"'
    # Validar que Windows Script Host no esta deshabilitado por la politica
    # local antes de cambiar una tarea que hoy funciona.
    $probe = Join-Path $root 'v2-wscript-silent-probe.vbs'
    [IO.File]::WriteAllText($probe, 'WScript.Quit 0', [System.Text.Encoding]::ASCII)
    try {
        $check = Start-Process -FilePath $wscript -ArgumentList ('//B //Nologo "' + $probe + '"') -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if ($check.ExitCode -ne 0) { throw ('Windows Script Host no operativo: ' + $check.ExitCode) }
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
    if ($alreadySilent -and $args -eq $newArgs) {
        Note 'TT_V2_TASK_ALREADY_SILENT' $name
        return
    }
    # Backup only once: rerunning the fix must not replace the original XML
    # with a backup of the already-modified task.
    if (!(Test-Path -LiteralPath $backup -PathType Leaf)) {
        $xml = Export-ScheduledTask -TaskName $name -ErrorAction Stop
        [IO.File]::WriteAllText($backup, $xml, (New-Object System.Text.UTF8Encoding($false)))
    }
    $newAction = New-ScheduledTaskAction -Execute $wscript -Argument $newArgs
    try {
        # Mantener disparadores, principal, duracion e IgnoreNew intactos.
        # La instancia Running no se detiene ni se reinicia.
        Set-ScheduledTask -TaskName $name -Action $newAction -ErrorAction Stop | Out-Null
        $verified = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        $actual = @($verified.Actions)
        if ($actual.Count -ne 1 -or
            [string]$actual[0].Execute -ine $wscript -or
            [string]$actual[0].Arguments -ne $newArgs) {
            throw 'La accion silenciosa no se verifico'
        }
    } catch {
        try { Set-ScheduledTask -TaskName $name -Action $previous -ErrorAction Stop | Out-Null } catch { }
        throw ('No se pudo cambiar la tarea ' + $name + ': ' + $_.Exception.Message)
    }
    Note 'TT_V2_TASK_SILENT_CONFIGURED' $name
    Note 'TT_V2_TASK_STATE_UNCHANGED' ([string]$task.State)
}
try {
    PatchTask 'TTActualidadV2-Editorial-Auto' 'Run-V2-Editorial-Auto.ps1' 'TTActualidadV2-Editorial-Silent.vbs' $true
    PatchTask 'TTActualidadV2-Top30-15m' 'Run-V2-Top30-Tick.ps1' 'TTActualidadV2-Top30-Silent.vbs' $false
    Note 'TT_V2_HIDE_FIX_RESULT' 'INSTALLED_NEXT_INVOCATIONS_SILENT'
    Note 'TT_V2_CURRENT_WORKER' 'UNTOUCHED'
    Note 'TT_V2_CHROME' 'UNTOUCHED'
    Note 'TT_V1_MODIFIED' 'NO'
} catch {
    Note 'TT_V2_HIDE_FIX_RESULT' 'ERROR_NOT_APPLIED_FULLY'
    Note 'TT_V2_HIDE_FIX_ERROR' ($_.Exception.Message -replace '[\r\n]+', ' ')
    Note 'TT_V1_MODIFIED' 'NO'
    exit 1
}

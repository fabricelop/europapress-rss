#requires -Version 5.1
# Read-only inventory for decommissioning TT Telegram ONLY.
# DOES NOT change services, tasks, Chrome, files or GitHub. Avoid printing secrets.
$ErrorActionPreference='Continue'
Write-Host '=== AUDITORIA SEGURA: TT TELEGRAM / CHROME / PROCESOS ===' -ForegroundColor Cyan
Write-Host ('Fecha: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$important='TTiTTulares|TTendencias|TT[-_ ]|telegram|SeLoRecordamos|TTImages|imagebridge|chrome'
$tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object{
 $label=[string]$_.TaskName+' '+[string]$_.TaskPath+' '+(@($_.Actions)|ForEach-Object{[string]$_.Execute+' '+[string]$_.Arguments} -join ' ')
 $label -match $important
})
function Classify([string]$s){
 if($s -match '(?i)selorecordamos|slr'){return 'CONSERVAR - SeLoRecordamos'}
 if($s -match '(?i)TTImages|ImageBridge|ttimages'){return 'CONSERVAR - imagenes'}
 if($s -match '(?i)TTiTTularesDedicatedListener|TTendenciasDedicatedListener|TT[-_]LocalWatchdog|TT[-_]AutoUpdater|TT Chrome|TTiTTulares Local|TTendencias Local'){return 'CONSERVAR - editorial/Chrome'}
 if($s -match '(?i)telegram'){return 'REVISAR - Telegram (NO detenido)'}
 return 'REVISAR - no identificado'
}
Write-Host ''
Write-Host '=== TAREAS PROGRAMADAS (sin mostrar argumentos ni credenciales) ===' -ForegroundColor Cyan
$taskRows=@(foreach($t in $tasks){
 $actions=(@($t.Actions)|ForEach-Object{[string]$_.Execute+' '+[string]$_.Arguments}) -join ' '
 try{$info=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop}
 catch{$info=$null}
 [pscustomobject]@{Tarea=($t.TaskPath+$t.TaskName);Estado=[string]$t.State;Tipo=(Classify ($t.TaskName+' '+$actions));Ultima=$(if($info){$info.LastRunTime.ToString('dd/MM HH:mm')}else{'--'})}
})
if($taskRows.Count){$taskRows|Sort-Object Tarea|Format-Table -AutoSize|Out-String -Width 220|Write-Host}else{Write-Host 'No se encontraron tareas TT/Telegram.'}
Write-Host '=== PROCESOS POWERSHELL/NODE/WSCRIPT (sin argumentos) ===' -ForegroundColor Cyan
$raw=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|
 Where-Object {$_.Name -match '^(powershell|pwsh|node|wscript|cscript|python)(\.exe)?$'})
$items=@(foreach($p in $raw){
 $line=[string]$p.CommandLine
 if($line -notmatch '(?i)TTiTTulares|TTendencias|TTImages|SeLoRecordamos|telegram|imagebridge|tt[-_ ]'){continue}
 $files=[regex]::Matches($line,'(?i)[^" \t\r\n=]+?\.(ps1|js|mjs|vbs|py|cmd|bat)')|
  ForEach-Object{[IO.Path]::GetFileName($_.Value.Trim('"',"'"))}
 $scripts=($files | Sort-Object -Unique) -join ', '
 if(!$scripts){$scripts='(argumentos ocultos)'}
 [pscustomobject]@{
  PID=$p.ProcessId;Parent=$p.ParentProcessId;Exe=[string]$p.Name
  Scripts=$scripts;Tipo=(Classify ($line))
 }
})
if($items.Count){$items|Sort-Object PID|Format-Table -AutoSize|Out-String -Width 220|Write-Host}else{Write-Host 'No hay procesos TT identificables mediante esos nombres.'}
Write-Host '=== CHROME (SOLO ESTADISTICAS, SIN CERRAR NADA) ===' -ForegroundColor Cyan
$chrome=@(Get-Process chrome -ErrorAction SilentlyContinue)
$mib=0;if($chrome.Count){$mib=[math]::Round((($chrome|Measure-Object WorkingSet64 -Sum).Sum/1MB),0)}
Write-Host ('Chrome: '+$chrome.Count+' procesos; RAM aprox sumada '+$mib+' MiB')
Write-Host ''
Write-Host 'RESULTADO: AUDITORIA SOLO LECTURA. No se ha detenido, deshabilitado, cerrado ni cambiado NADA.' -ForegroundColor Green
Write-Host 'Copia esta salida al chat, sin pegar tokens ni claves.'

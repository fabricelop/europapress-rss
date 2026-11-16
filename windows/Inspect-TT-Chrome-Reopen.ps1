# Read-only diagnosis: never starts/stops a task, process or browser.
[CmdletBinding()]
param([string]$BaseDir='C:\TTiTTulares')
$ErrorActionPreference='Stop'

function Get-ChromeCommandIdentity([string]$CommandLine){
  $port=$null;$profile=$null
  if($CommandLine -match '--remote-debugging-port(?:=|\s+)"?(\d{1,5})"?(?=\s|$)'){
    $parsed=[int]$Matches[1]
    if($parsed -ge 1 -and $parsed -le 65535){$port=$parsed}
  }
  if($CommandLine -match '(?:"--user-data-dir=([^"]+)"|--user-data-dir(?:=|\s+)(?:"([^"]+)"|([^\s]+)))'){
    $profile=if($Matches[1]){$Matches[1]}elseif($Matches[2]){$Matches[2]}else{$Matches[3]}
  }
  [pscustomobject]@{port=$port;profile=$profile;headless=($CommandLine -match '--headless(?:=|\s|$)')}
}
function Hide-SensitiveArgument([string]$Text){
  [regex]::Replace($Text,'(?i)((?:token|password|secret|api[_-]?key)\s*(?:=|:)\s*)(?:"[^"]*"|[^\s,;]+)','$1<oculto>')
}
function Process-Summary($Process){
  if(-not $Process){return $null}
  [pscustomobject]@{pid=$Process.ProcessId;parent_pid=$Process.ParentProcessId;name=$Process.Name;
    created_at=$Process.CreationDate;command=(Hide-SensitiveArgument ([string]$Process.CommandLine))}
}

$all=@(Get-CimInstance Win32_Process)
$byId=@{};foreach($process in $all){$byId[[int]$process.ProcessId]=$process}
$roots=@($all | Where-Object {$_.Name -eq 'chrome.exe' -and [string]$_.CommandLine -notmatch '(?:^|\s)--type='})
$browsers=@(foreach($root in $roots){
  $identity=Get-ChromeCommandIdentity ([string]$root.CommandLine)
  $parents=@();$parentId=[int]$root.ParentProcessId;$seen=@{}
  for($depth=0;$depth -lt 5;$depth++){
    if(-not $parentId -or $seen.ContainsKey($parentId)){break}
    $seen[$parentId]=$true
    $parent=$byId[$parentId]
    # Avoid attributing a reused PID to a browser created before that process.
    if(-not $parent -or $parent.CreationDate -gt $root.CreationDate){break}
    $parents+=Process-Summary $parent;$parentId=[int]$parent.ParentProcessId
  }
  [pscustomobject]@{process=(Process-Summary $root);port=$identity.port;profile=$identity.profile;
    headless=$identity.headless;parent_chain=$parents}
})
$supervisors=@($all | Where-Object {
  $_.Name -in @('powershell.exe','pwsh.exe','node.exe','wscript.exe','cscript.exe','python.exe','py.exe') -and
  [string]$_.CommandLine -match 'TT-LocalWatchdog|TT-Guard9223|TT-Relay9234-Guard|TTImages-AutoRecovery|TTActualidadV2|SeLoRecordamos|TTendenciasDedicatedListener|TTiTTularesDedicatedListener'
} | ForEach-Object {Process-Summary $_})

$taskError=$null;$tasks=@()
try{
  $tasks=@(Get-ScheduledTask | Where-Object {
    $_.TaskName -match '^TT Chrome|^(TTiTTulares Local|TTendencias Local)$|Guard.*9223|Relay.*9234|TTActualidad.*V2|SeLoRecordamos' -or
    (@($_.Actions | Where-Object {[string]$_.Arguments -match 'TT-LocalWatchdog|TT-Guard9223|TT-Relay9234-Guard'}).Count -gt 0)
  } | ForEach-Object {
    $task=$_;$info=$null
    try{$info=Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath}catch{}
    [pscustomobject]@{name=($task.TaskPath+$task.TaskName);state=[string]$task.State;
      last_run=$info.LastRunTime;last_result=$info.LastTaskResult;next_run=$info.NextRunTime;
      actions=@($task.Actions | ForEach-Object {[pscustomobject]@{execute=$_.Execute;arguments=(Hide-SensitiveArgument ([string]$_.Arguments))}})}
  })
}catch{$taskError=$_.Exception.Message}

$ports=@(9223,9234)+@($browsers | Where-Object {$_.port} | ForEach-Object {[int]$_.port})
$cdp=@(foreach($port in @($ports | Select-Object -Unique | Select-Object -First 8)){
  try{
    $version=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$port+'/json/version') -TimeoutSec 2
    $rawPages=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$port+'/json/list') -TimeoutSec 2
    # Normalize Windows PowerShell's possible nested JSON array output.
    $pages=@(foreach($item in $rawPages){if($item -is [array]){foreach($child in $item){$child}}else{$item}})
    [pscustomobject]@{port=$port;reachable=$true;browser=$version.Browser;
      pages=@($pages | Where-Object {$_.type -eq 'page'} | ForEach-Object {
        $safeUrl=[string]$_.url
        try{$uri=[uri]$safeUrl;$safeUrl=$uri.GetLeftPart([UriPartial]::Path)}catch{}
        [pscustomobject]@{id=$_.id;url=$safeUrl}
      })}
  }catch{[pscustomobject]@{port=$port;reachable=$false}}
})
$flags=@(foreach($name in @('TTendencias-V1-Disabled.flag','TTiTTulares-V1-Disabled.flag','V1-ImageGen-Paused.flag')){
  [pscustomobject]@{name=$name;present=(Test-Path -LiteralPath (Join-Path $BaseDir $name))}
})
$localWatchdog=Join-Path $BaseDir 'TT-LocalWatchdog.ps1'
$watchdog=$null
if(Test-Path -LiteralPath $localWatchdog){
  $source=[IO.File]::ReadAllText($localWatchdog)
  $watchdog=[pscustomobject]@{path=$localWatchdog;sha256=(Get-FileHash -LiteralPath $localWatchdog -Algorithm SHA256).Hash;
    has_chrome_auto_launch=($source -match 'schtasks[.]exe\s+/Run\s+/TN\s+"TT Chrome Auto"');
    has_chrome_auto_task_enable=($source -match 'function EnsureScheduledTasks' -and $source -match 'TT Chrome Auto')}
}
$log=Join-Path $BaseDir 'tt-local-watchdog.log'
$recentLog=@()
if(Test-Path -LiteralPath $log){
  $recentLog=@(Get-Content -LiteralPath $log -Tail 180 | Where-Object {$_ -match 'CHROME AUTO|TASK ENABLED|WATCHDOG START'} |
    Select-Object -Last 15 | ForEach-Object {Hide-SensitiveArgument $_})
}
$report=[ordered]@{at=(Get-Date).ToString('o');browsers=$browsers;supervisors=$supervisors;
  tasks=$tasks;task_read_error=$taskError;cdp=$cdp;flags=$flags;local_watchdog=$watchdog;recent_watchdog_log=$recentLog;
  note='Solo lectura. La existencia de EnsureChrome en el archivo no prueba que causara esta ventana; correlacionar puerto/perfil, padres, tareas y log.'}
$folder=Join-Path $env:TEMP ('TT-Chrome-Diagnostico-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $folder | Out-Null
$output=Join-Path $folder 'chrome-reopen.json'
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $output -Encoding UTF8
Write-Host '=== CHROME RAIZ: PUERTO / PERFIL / PADRES ==='
$browsers | ConvertTo-Json -Depth 8 | Write-Output
Write-Host '=== SUPERVISORES Y TAREAS ==='
@{supervisors=$supervisors;tasks=$tasks;flags=$flags;recent_log=$recentLog} | ConvertTo-Json -Depth 8 | Write-Output
Write-Host '=== CDP: PUERTOS Y PAGINAS (SIN CONSULTAS URL) ==='
$cdp | ConvertTo-Json -Depth 7 | Write-Output
Write-Host ('INFORME='+$output)
Write-Host 'DIAGNOSTICO_SOLO_LECTURA=COMPLETADO'

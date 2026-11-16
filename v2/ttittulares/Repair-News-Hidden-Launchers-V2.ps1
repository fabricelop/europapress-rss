# Repair only future launches. Existing jobs, task flags and triggers are preserved.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
if(-not (Test-Path -LiteralPath $root)){throw 'NEWS_INSTALLATION_MISSING'}
$repo='fabricelop/europapress-rss'
$headers=@{'User-Agent'='TTNoticiasV2-HiddenRepair';'Accept'='application/vnd.github+json'}
$head=Invoke-RestMethod -Uri ('https://api.github.com/repos/'+$repo+'/commits/'+[Uri]::EscapeDataString('feature/ttactualidad-v2-clean')) -Headers $headers
$sha=[string]$head.sha
if($sha -notmatch '^[a-f0-9]{40}$'){throw 'NEWS_COMMIT_NOT_VERIFIED'}
$tree=Invoke-RestMethod -Uri ('https://api.github.com/repos/'+$repo+'/git/trees/'+$sha+'?recursive=1') -Headers $headers
if($tree.truncated){throw 'NEWS_TREE_TRUNCATED'}
$stage=Join-Path $root ('hidden-launcher-releases\'+$sha)
New-Item -ItemType Directory -Path $stage -Force|Out-Null
foreach($name in @('Launch-News-Hidden.vbs','News-HiddenTask-Xml.ps1')){
 $path='v2/ttittulares/'+$name
 $entry=@($tree.tree|Where-Object {$_.path -eq $path -and $_.type -eq 'blob'})
 if($entry.Count -ne 1){throw 'NEWS_HIDDEN_FILE_MISSING'}
 $target=Join-Path $stage $name
 Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/'+$repo+'/'+$sha+'/'+$path) -Headers $headers -OutFile $target
 $bytes=[IO.File]::ReadAllBytes($target);$prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
 $hash=[Security.Cryptography.SHA1]::Create()
 try{$actual=([BitConverter]::ToString($hash.ComputeHash([byte[]]($prefix+$bytes)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
 if($actual -ne $entry[0].sha){throw 'NEWS_HIDDEN_FILE_HASH_MISMATCH'}
}
. (Join-Path $stage 'News-HiddenTask-Xml.ps1')
$launcher=Join-Path $root 'Launch-News-Hidden.vbs'
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
$backup=Join-Path $root ('Backup-Hidden-Launchers-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup -Force|Out-Null
$plan=@()
foreach($name in @('TTActualidadNoticiasV2-Editorial','TTActualidadNoticiasV2-Images')){
 $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if(-not $task){continue}
 $runner=Join-Path $root $(if($name -eq 'TTActualidadNoticiasV2-Editorial'){'Run-News-Editorial-Auto.ps1'}else{'Run-News-Images-Auto.ps1'})
 $original=Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
 [IO.File]::WriteAllText((Join-Path $backup ($name+'.xml')),$original,(New-Object Text.UTF8Encoding($false)))
 $changed=ConvertTo-NewsHiddenTaskXml -Xml $original -Runner $runner -Launcher $launcher -Wscript $wscript
 $plan+=@{Name=$task.TaskName;Path=$task.TaskPath;Xml=$changed}
}
if(-not $plan.Count){throw 'NEWS_TASKS_NOT_INSTALLED_WAIT_FOR_UPGRADE'}
if(Test-Path -LiteralPath $launcher){Copy-Item -LiteralPath $launcher -Destination (Join-Path $backup 'Launch-News-Hidden.vbs') -Force}
Copy-Item -LiteralPath (Join-Path $stage 'Launch-News-Hidden.vbs') -Destination $launcher -Force
foreach($task in $plan){
 Register-ScheduledTask -TaskName $task.Name -TaskPath $task.Path -Xml $task.Xml -Force|Out-Null
 $verify=Get-ScheduledTask -TaskName $task.Name -TaskPath $task.Path
 if([IO.Path]::GetFileName($verify.Actions.Execute) -ine 'wscript.exe' -or -not $verify.Settings.Hidden){throw 'NEWS_HIDDEN_TASK_READBACK_FAILED'}
 Write-Host ('TTN2_HIDDEN_TASK='+$task.Name)
}
Write-Host ('COPIA_SEGURIDAD='+$backup)
Write-Host 'TTN2_FUTURE_LAUNCHES=WSCRIPT_HIDDEN'
Write-Host 'TTN2_RUNNING_JOBS_CHROME_FLAGS_TRIGGERS=UNCHANGED'

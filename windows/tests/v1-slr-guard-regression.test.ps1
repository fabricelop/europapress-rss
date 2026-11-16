$ErrorActionPreference='Stop'
$scripts=@('Stop-TT-V1-ChatGPT.ps1','Repair-TT-V1-Stop-SeLoRecordamos.ps1')
$guardTexts=@()
foreach($script in $scripts){
  $path=Join-Path $PSScriptRoot ('..\'+$script)
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw ($errors | Out-String)}
  $function=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-V1ExecutorGuard'},$true)[0]
  if(-not $function){throw ('Guard function missing: '+$script)}
  Invoke-Expression $function.Extent.Text
  $guardTexts+=Get-V1ExecutorGuard
  if($script -like 'Repair-*'){
    foreach($command in $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)){
      if($command.GetCommandName() -match '^(Start-Process|Stop-Process|Start-ScheduledTask|Stop-ScheduledTask|Enable-ScheduledTask|Disable-ScheduledTask|Register-ScheduledTask|schtasks[.]exe|taskkill[.]exe)$'){
        throw ('Repair must not control any job or browser: '+$command.GetCommandName())
      }
    }
  }
}
if($guardTexts[0] -cne $guardTexts[1]){throw 'Stop/repair guards differ'}
$node=Get-Command node.exe -ErrorAction Stop
$temp=Join-Path $env:TEMP ('tt-v1-slr-regression-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$fixture=Join-Path $temp 'fixture.cjs'
$utf8=New-Object Text.UTF8Encoding($false)
$tail="console.log('TRANSPORT_CONTINUES');`n"
[IO.File]::WriteAllText($fixture,$guardTexts[0]+$tail,$utf8)
$previous=$env:TT_CHAT_MESSAGE_B64
function Encode-Message([string]$Message){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message))}
function Assert-GuardCase([string]$Label,[string[]]$LauncherArgs,[string]$Encoded,[bool]$Allowed){
  $env:TT_CHAT_MESSAGE_B64=$Encoded
  $output=(& $node.Source $fixture @LauncherArgs 2>&1 | Out-String)
  if($LASTEXITCODE -ne 0){throw ('Node guard failed: '+$Label)}
  if($Allowed){
    if($output -notmatch 'TRANSPORT_CONTINUES' -or $output -match 'TT_V1_CHATGPT_DISABLED'){throw ('Legitimate transport blocked: '+$Label)}
  }else{
    if($output -match 'TRANSPORT_CONTINUES' -or $output -notmatch 'TT_V1_CHATGPT_DISABLED'){throw ('V1 guard bypass: '+$Label)}
  }
}
try{
  $message='SELORECORDAMOS_EDITORIAL_JOB_V1 sr-1794850211145 | Ejecuta AHORA la pasada editorial de SeLoRecordamos. Lee el contrato actual.'
  $valid=Encode-Message $message
  Assert-GuardCase 'headlines no message' @('titulares','--enviar') '' $false
  Assert-GuardCase 'trends no message' @('tendencias','--enviar') '' $false
  Assert-GuardCase 'legitimate current SLR transport' @('titulares','--enviar') $valid $true
  Assert-GuardCase 'SLR does not exempt trends' @('tendencias','--enviar') $valid $false
  Assert-GuardCase 'mixed project arguments' @('titulares','TENDENCIAS','--enviar') $valid $false
  Assert-GuardCase 'ordinary V1 message' @('titulares','--enviar') (Encode-Message 'Ejecuta TTiTTulares') $false
  Assert-GuardCase 'wrong SLR command id' @('titulares','--enviar') (Encode-Message ($message.Replace('sr-1794850211145','sr-falso'))) $false
  Assert-GuardCase 'wrong SLR prefix' @('titulares','--enviar') (Encode-Message ('noise '+$message)) $false
  Assert-GuardCase 'malformed base64 with valid decoded prefix' @('titulares','--enviar') ('%%%'+$valid) $false
  $invalidUtf8=[Text.Encoding]::UTF8.GetBytes($message)+[byte[]]@(255)
  Assert-GuardCase 'malformed utf8' @('titulares','--enviar') ([Convert]::ToBase64String($invalidUtf8)) $false
  Assert-GuardCase 'other project untouched' @('selorecordamos','--enviar') '' $true

  # Invoke the actual repair in an isolated directory; it may edit only this
  # fixture's exact guard, never restore retired listeners or launch a job.
  $runner=Join-Path $temp 'Ejecutar.js'
  $oldGuard="// TT_V1_EXECUTOR_GUARD_20261116`nif (process.argv.slice(2).some(x => /^(titulares|tendencias)$/i.test(x))) { console.log('TT_V1_CHATGPT_DISABLED'); process.exit(0); }`n"
  [IO.File]::WriteAllText($runner,$oldGuard+$tail,$utf8)
  $listener=Join-Path $temp 'TTiTTularesDedicatedListener.ps1'
  [IO.File]::WriteAllText($listener,'# RETIRED WRAPPER MUST REMAIN',$utf8)
  $repair=Join-Path $PSScriptRoot '..\Repair-TT-V1-Stop-SeLoRecordamos.ps1'
  $first=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repair -BaseDir $temp 2>&1 | Out-String)
  if($LASTEXITCODE -ne 0 -or $first -notmatch 'GUARDIA_CORREGIDA_V1_SIGUE_BLOQUEADO'){throw 'Actual repair did not succeed'}
  $after=[IO.File]::ReadAllText($runner)
  if($after -cne ($guardTexts[0]+$tail)){throw 'Repair changed more than the exact guard'}
  if([IO.File]::ReadAllText($listener) -cne '# RETIRED WRAPPER MUST REMAIN'){throw 'Retired listener changed'}
  $backups=@(Get-ChildItem -LiteralPath $temp -Directory -Filter 'Backup-Guardia-SLR-*')
  if($backups.Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $backups[0].FullName 'Ejecutar.js')) -cne ($oldGuard+$tail)){throw 'Original backup missing or changed'}
  $second=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repair -BaseDir $temp 2>&1 | Out-String)
  if($LASTEXITCODE -ne 0 -or $second -notmatch 'YA_COMPATIBLE' -or [IO.File]::ReadAllText($runner) -cne $after){throw 'Repair not idempotent'}
  [IO.File]::WriteAllText($runner,$oldGuard.Replace('process.exit(0)','process.exit(7)')+$tail,$utf8)
  $unknown=[IO.File]::ReadAllText($runner)
  $savedPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
  $rejected=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repair -BaseDir $temp 2>&1 | Out-String)
  $rejectedExit=$LASTEXITCODE;$ErrorActionPreference=$savedPreference
  if($rejectedExit -eq 0 -or [IO.File]::ReadAllText($runner) -cne $unknown){throw 'Unknown guard was overwritten'}
  # The rejected child is expected to exit 1; do not leak that status to the
  # GitHub PowerShell wrapper after all assertions have succeeded.
  $global:LASTEXITCODE=0
  Write-Output 'TT_V1_SLR_GUARD_REAL_NODE_CASES_AND_EXACT_REPAIR=PASS'
}finally{
  if($null -eq $previous){Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue}else{$env:TT_CHAT_MESSAGE_B64=$previous}
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

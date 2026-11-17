# Evaluate ONLY the installer pilot guards extracted through the PowerShell AST.
# No install, task registration, browser launch, flags or network mutation occurs.
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'Install-News-Editorial-V2.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$guards=@($ast.FindAll({
 param($node)
 if($node -isnot [Management.Automation.Language.IfStatementAst]){return $false}
 $text=$node.Extent.Text
 return ($text.StartsWith('if($pilot.status -notin') -or
         $text.StartsWith('if($pilot.status -in') -or
         $text.StartsWith('if($pilot.status -eq ''quarantined'')'))
},$true))
if($guards.Count -ne 3){throw 'PILOT_GUARDS_NOT_FOUND'}
$code=[ScriptBlock]::Create(($guards|ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine)
$pilot=@{status='quarantined';error_type='ContractError';submission_confirmed=$true;
 capture_complete=$true;capture_persisted=$true;failure_persisted=$true;cleanup_verified=$true}
& $code
foreach($field in @('submission_confirmed','capture_complete','capture_persisted','failure_persisted','cleanup_verified')){
 $pilot=@{status='quarantined';error_type='ContractError';submission_confirmed=$true;
  capture_complete=$true;capture_persisted=$true;failure_persisted=$true;cleanup_verified=$true}
 $pilot[$field]=$false
 $rejected=$false
 try{& $code}catch{$rejected=$true}
 if(-not $rejected){throw ('PILOT_ACCEPTED_UNVERIFIED_'+$field)}
}
foreach($status in @('incident','unexpected')){
 $pilot=@{status=$status;cleanup_verified=$true}
 $rejected=$false;try{& $code}catch{$rejected=$true}
 if(-not $rejected){throw ('PILOT_ACCEPTED_BAD_STATUS_'+$status)}
}
$pilot=@{status='ready';cleanup_verified=$true}
& $code
$pilot=@{status='idle'}
& $code
$pilot=@{status='quarantined';error_type='RuntimeError';submission_confirmed=$true;
 capture_complete=$true;capture_persisted=$true;failure_persisted=$true;cleanup_verified=$true}
$rejected=$false;try{& $code}catch{$rejected=$true}
if(-not $rejected){throw 'PILOT_ACCEPTED_UNEXPECTED_FAILURE'}
Write-Host 'TTN2_PILOT_VERIFIED_QUARANTINE_GUARDS=PASS'

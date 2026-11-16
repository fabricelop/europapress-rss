$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot '..\Stop-TT-V1-ChatGPT.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
# Load only the pure matching function. Never execute the stop procedure in CI.
$function=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Is-RetiredCommand'},$true)[0]
Invoke-Expression $function.Extent.Text
$basePattern=[regex]::Escape('C:\TTiTTulares\')
$namePattern='(?:TTiTTularesDedicatedListener\.ps1|TTendenciasDedicatedListener\.ps1|MobileChatTriggerListener\.ps1|TTiTTularesMobileChatTriggerListener\.ps1|TTendenciasMobileChatTriggerListener\.ps1|TTiTTularesImageBridge\.js|TTendenciasImageBridge\.js|TT-AutoUpdater\.ps1)(?=["\s]|$)'
foreach($command in @(
  'powershell.exe -File "C:\TTiTTulares\TTiTTularesDedicatedListener.ps1"',
  'powershell.exe -File C:\TTiTTulares\TTendenciasDedicatedListener.ps1',
  'node.exe C:\TTiTTulares\TTiTTularesImageBridge.js command event'
)){if(-not (Is-RetiredCommand $command)){throw "Missed V1: $command"}}
foreach($command in @(
  'node.exe C:\TTiTTulares\Ejecutar.js selorecordamos --enviar',
  'node.exe "C:\TTiTTulares\Ejecutar.js" titulares --enviar',
  'wscript.exe "C:\TTiTTulares\LanzarOculto.vbs" tendencias',
  'node.exe C:\TTiTTulares\v2\TTiTTularesImageBridge.js',
  'node.exe C:\TTActualidadV2\TTiTTularesImageBridge.js',
  'powershell.exe -File C:\TTiTTulares\TT-LocalWatchdog.ps1',
  'chrome.exe --remote-debugging-port=9223',
  'node.exe C:\Otro\TTiTTularesImageBridge.js',
  'powershell.exe -File C:\TTiTTulares\TTiTTularesDedicatedListener.ps1.backup',
  'powershell.exe -File C:\TTiTTulares\SeLoRecordamos\MobileChatTriggerListener.ps1'
)){if(Is-RetiredCommand $command){throw "Protected process matched: $command"}}
$source=[IO.File]::ReadAllText($scriptPath)
if($source -notmatch 'Save-Original \$runner' -or $source -match 'taskkill|Stop-Process\s+-Name'){
  throw 'Backup or narrow stopping guarantee failed'
}
Write-Output 'TT_V1_STOP_PARSE_AND_PROCESS_SCOPE=PASS'

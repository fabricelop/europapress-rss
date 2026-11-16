$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot '..\Inspect-TT-Chrome-Reopen.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($name in @('Get-ChromeCommandIdentity','Hide-SensitiveArgument')){
  $function=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)[0]
  if(-not $function){throw "Missing function: $name"}
  Invoke-Expression $function.Extent.Text
}
$a=Get-ChromeCommandIdentity 'chrome.exe --remote-debugging-port=9223 --user-data-dir="C:\TTiTTulares\Chrome Auto"'
if($a.port -ne 9223 -or $a.profile -ne 'C:\TTiTTulares\Chrome Auto' -or $a.headless){throw 'Legacy visible Chrome parse failed'}
$b=Get-ChromeCommandIdentity 'chrome.exe --headless=new --remote-debugging-port 9234 --user-data-dir=C:\TTImages\ChromeProfile'
if($b.port -ne 9234 -or $b.profile -ne 'C:\TTImages\ChromeProfile' -or -not $b.headless){throw 'Relay parse failed'}
$c=Get-ChromeCommandIdentity 'chrome.exe --profile-directory=Default'
if($c.port -or $c.profile){throw 'Personal Chrome invented CDP identity'}
$d=Get-ChromeCommandIdentity 'chrome.exe --remote-debugging-port=99999'
if($d.port){throw 'Invalid port accepted'}
$e=Get-ChromeCommandIdentity 'chrome.exe "--remote-debugging-port=9235" "--user-data-dir=C:\TTActualidad V2\slot 1"'
if($e.port -ne 9235 -or $e.profile -ne 'C:\TTActualidad V2\slot 1'){throw 'Whole-argument quoting failed'}
$f=Get-ChromeCommandIdentity 'chrome.exe --remote-debugging-port=123456'
if($f.port){throw 'Partial port match accepted'}
if((Hide-SensitiveArgument 'node.exe token=secretvalue password="two words"') -match 'secretvalue|two words'){throw 'Sensitive argument not hidden'}
$commands=$ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)
foreach($command in $commands){
  if($command.GetCommandName() -match '^(Stop-Process|Start-Process|Stop-ScheduledTask|Start-ScheduledTask|Disable-ScheduledTask|Enable-ScheduledTask|Set-ScheduledTask|Register-ScheduledTask|Remove-Item|Set-ItemProperty|Invoke-Expression|schtasks[.]exe|taskkill[.]exe)$'){
    throw ('Diagnostic contains mutation command: '+$command.GetCommandName())
  }
}
Write-Output 'TT_CHROME_REOPEN_DIAGNOSTIC_SCOPE=PASS'

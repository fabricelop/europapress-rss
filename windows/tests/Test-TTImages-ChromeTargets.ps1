#requires -Version 7.0
# Isolated parser regression; no real Chrome access, no file modifications.
$ErrorActionPreference='Stop'
$source=Get-Content -LiteralPath 'windows/Recuperar-TTImages-Visor-Bloqueado.ps1' -Raw
$tokens=$null;$errorsFound=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errorsFound)
if($errorsFound.Count){throw 'Recovery script syntax invalid'}
foreach($name in @('GetChromeTargets','GetGalleryTargets')){
  $node=$ast.FindAll({
    param($a)
    $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name
  },$true)|Select-Object -First 1
  if(-not $node){throw ('Missing function '+$name)}
  Invoke-Expression $node.Extent.Text
}
$base='http://127.0.0.1:9234'
$galleryPattern='^https://chatgpt\.com/images(?:[/?#]|$)'
$global:mockJson=''
function Invoke-WebRequest {
  param([switch]$UseBasicParsing,[string]$Uri,[int]$TimeoutSec)
  if($Uri -ne 'http://127.0.0.1:9234/json/list'){throw 'Unexpected URL '+$Uri}
  return [pscustomobject]@{Content=$global:mockJson}
}
$ids=1..8 |ForEach-Object{('{0:X32}' -f $_)}
$urls=@('https://chatgpt.com/images','https://chatgpt.com/c/aaa','about:blank','https://chatgpt.com/','chrome://newtab/','about:blank','chrome://settings/','chrome://version/')
$types=@('page','page','iframe','page','browser_ui','worker','browser_ui','worker')
$urls[5]='' # Chrome workers can report an empty URL
$rows=@(for($i=0;$i -lt $ids.Count;$i++){[ordered]@{id=$ids[$i];type=$types[$i];url=$urls[$i];webSocketDebuggerUrl=('ws://127.0.0.1:9234/devtools/page/'+$ids[$i])}})
$global:mockJson=ConvertTo-Json -InputObject $rows -Depth 4 -Compress
$targets=@(GetChromeTargets)
if($targets.Count -ne 8){throw ('Chrome response must be 8 separate targets, got '+$targets.Count)}
if($targets[0].id -is [array]){throw 'A target ID must be scalar, not Object[]'}
if([string]$targets[0].id -cne $ids[0]){throw 'Chrome target identity corrupted'}
$galleries=@(GetGalleryTargets $targets)
if($galleries.Count -ne 1){throw ('Must identify exactly one gallery, got '+$galleries.Count)}
$rows[1].url='https://chatgpt.com/images'
$global:mockJson=ConvertTo-Json -InputObject $rows -Depth 4 -Compress
$targets=@(GetChromeTargets)
$galleries=@(GetGalleryTargets $targets)
if($galleries.Count -ne 2){throw 'Duplicate galleries must be counted independently'}
$rows[0].url='https://chatgpt.com/c/other'
$rows[1].url='https://chatgpt.com/'
$global:mockJson=ConvertTo-Json -InputObject $rows -Depth 4 -Compress
if(@(GetGalleryTargets @(GetChromeTargets)).Count -ne 0){throw 'Zero-gallery case incorrect'}
Write-Host 'PASS_CHROME_9234_JSON_LIST_REAL_TARGETS_AND_DUPLICATES'

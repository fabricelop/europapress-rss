#requires -Version 5.1
<#
 Recover the ORIGINAL ChatGPT generated image from an existing conversation.
 No ImageGen requests, no image rewriting, no Telegram, no Chrome restarts.
 Without -Apply this is only a read-only preflight.
 With -Apply it opens a NEW tab in the ALREADY RUNNING Chrome CDP 9223
 (never reuses/navigates the pinned generator tab), then invokes a single
 ID-scoped existing-receipt retry. It never guesses a conversation URL.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[A-Za-z0-9_-]{6,80}$')]
  [string]$NewsId,
  [Parameter(Mandatory=$true)]
  [string]$ConversationUrl,
  [switch]$Apply
)
$ErrorActionPreference='Stop'
$root='C:\TTiTTulares'
$receiver=Join-Path $root 'TTiTTularesWebImages.cjs'
$receipts=Join-Path $root 'ttittulares-web-images'
function Emit([string]$label,[string]$value=''){
  Write-Host ('TTIMAGE_NEWS_RESCUE '+$label+' '+$value)
}
[Uri]$url=$null
if(-not [Uri]::TryCreate($ConversationUrl,[UriKind]::Absolute,[ref]$url)){
  throw 'La URL debe ser el enlace real de la conversación original ChatGPT.'
}
if($url.Scheme -ne 'https' -or $url.Host -ne 'chatgpt.com' -or
   $url.Port -ne 443 -or $url.UserInfo -or $url.Query -or $url.Fragment -or
   $url.AbsolutePath -notmatch '^/(?:c/[a-fA-F0-9-]{32,}|g/[A-Za-z0-9_-]+/c/[a-fA-F0-9-]{32,})/?$'){
  throw 'URL rechazada: usa solo el enlace de conversación https://chatgpt.com/c/... (sin parámetros).'
}
if(-not(Test-Path -LiteralPath $receiver)){throw 'Receptor de Noticias no instalado'}
$node=Get-Command node.exe -ErrorAction Stop
$matches=@()
if(Test-Path -LiteralPath $receipts){
  foreach($file in @(Get-ChildItem -LiteralPath $receipts -Filter '*.json' -File -ErrorAction SilentlyContinue)){
    try{
      $r=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
      if([string]$r.target_id -eq $NewsId -and [string]$r.status -eq 'waiting' -and
         [string]$r.command_id -match '^[A-Za-z0-9._-]{3,160}$'){
        $matches+=@($r)
      }
    }catch{}
  }
}
if($matches.Count -lt 1){Emit 'NO_PENDING_RECEIPT' $NewsId;return}
Emit 'RECEIPT_FOUND' ('id='+$NewsId+' count='+$matches.Count)
$base='http://127.0.0.1:9223'
try{
  $pages=@(Invoke-RestMethod -Method Get -Uri ($base+'/json/list') -TimeoutSec 5)
}catch{Emit 'CDP9223_UNAVAILABLE';return}
Emit 'CDP9223_AVAILABLE' ('tabs='+$pages.Count)
$canonical=$url.GetLeftPart([UriPartial]::Path).TrimEnd('/')
$existing=@($pages|Where-Object {
  [string]$_.type -eq 'page' -and [string]$_.url -eq $canonical
})
if(-not $Apply){
  Emit 'READ_ONLY' $(if($existing.Count){'ORIGINAL_TAB_PRESENT'}else{'WOULD_OPEN_NEW_TAB'})
  Emit 'END' 'NO_CHANGES'
  return
}
if($existing.Count -eq 0){
  # PUT /json/new only CREATES a new target; it does not navigate a pinned tab.
  $encoded=[Uri]::EscapeDataString($canonical)
  try{
    $new=Invoke-RestMethod -Method Put -Uri ($base+'/json/new?'+$encoded) -TimeoutSec 12
    if(-not $new.id){throw 'Chrome did not return a CDP target'}
    Emit 'ORIGINAL_TAB_OPENED' 'new_target_created'
  }catch{
    Emit 'ORIGINAL_TAB_NOT_OPENED' 'Chrome CDP refused to open the existing conversation URL'
    return
  }
}else{
  Emit 'ORIGINAL_TAB_REUSED' 'matched_url'
}
# Page hydration is asynchronous; if the existing conversation is not yet
# loaded the caller may safely repeat the same command. The receiver validates
# the command marker, revision and editorial hash before persisting bytes.
Start-Sleep -Seconds 4
Emit 'TRY_EXISTING_ORIGINAL' $NewsId
& $node.Source $receiver --once-id $NewsId
if($LASTEXITCODE -ne 0){Emit 'RETRY_DEFERRED' ('exit='+$LASTEXITCODE)}
Emit 'END' 'NO_NEW_IMAGE_GENERATED'

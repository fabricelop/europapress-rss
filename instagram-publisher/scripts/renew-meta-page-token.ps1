# One-time repair for expired Meta Page token (OAuth 190 / subcode 463).
# Meta credentials are prompted locally; do not provide them in chat or GitHub.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$publisher = (Resolve-Path (Join-Path $folder '..')).Path
$pageId = '1424696600717440'
$igId = '17841414511690117'
$worker = 'tt-actualidad-instagram-pilot'
$api = 'https://graph.facebook.com/v26.0'
$userToken = $null
$pageToken = $null

Write-Host ''
Write-Host 'TT Actualidad: renovar token Meta (sin guardarlo en archivos).'
Write-Host 'Abre https://developers.facebook.com/tools/explorer/'
Write-Host 'Selecciona tu app, genera un token de USUARIO con permisos:'
Write-Host 'pages_show_list, pages_read_engagement, instagram_basic, instagram_content_publish.'
Write-Host 'No pegues la credencial en ChatGPT ni en el repositorio.'
Write-Host ''

try {
    $secure = Read-Host 'Pega el USER access token (entrada oculta)' -AsSecureString
    $handle = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $userToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($handle)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($handle)
    }
    if ([string]::IsNullOrWhiteSpace($userToken) -or $userToken.Length -lt 30) {
        throw 'Token de usuario ausente o demasiado corto.'
    }

    $headers = @{Authorization = 'Bearer ' + $userToken; 'User-Agent' = 'TTActualidad-MetaTokenRepair/1.0'}
    $fields = [Uri]::EscapeDataString('id,name,access_token,instagram_business_account{id,username}')
    $page = Invoke-RestMethod -Method Get -Uri ($api + '/' + $pageId + '?fields=' + $fields) -Headers $headers -TimeoutSec 30

    if ([string]$page.id -ne $pageId) { throw 'La credencial no pertenece a la pagina prevista.' }
    if ([string]$page.instagram_business_account.id -ne $igId) {
        throw 'La pagina no tiene vinculada la cuenta Instagram prevista.'
    }
    if ([string]$page.instagram_business_account.username -ne 'ttactualidad') {
        throw 'El usuario Instagram vinculado no es ttactualidad.'
    }

    $pageToken = [string]$page.access_token
    if ([string]::IsNullOrWhiteSpace($pageToken) -or $pageToken.Length -lt 30) {
        throw 'No se ha obtenido el Page Access Token. Comprueba pages_show_list y tu acceso a la pagina.'
    }

    $pageHeaders = @{Authorization = 'Bearer ' + $pageToken; 'User-Agent' = 'TTActualidad-MetaTokenRepair/1.0'}
    $pageMe = Invoke-RestMethod -Method Get -Uri ($api + '/me?fields=id,name') -Headers $pageHeaders -TimeoutSec 30
    if ([string]$pageMe.id -ne $pageId) {
        throw 'El Page Access Token no identifica la pagina prevista. No se cambiara Cloudflare.'
    }

    Write-Host 'Validacion correcta: pagina y cuenta @ttactualidad.'
    Write-Host 'Guardando el nuevo secreto directamente en Cloudflare...'
    Push-Location $publisher
    try {
        $pageToken | & npx.cmd wrangler secret put INSTAGRAM_PAGE_ACCESS_TOKEN --name $worker
        if ($LASTEXITCODE -ne 0) { throw 'Wrangler no ha confirmado la actualizacion del secreto.' }
    } finally {
        Pop-Location
    }

    Write-Host 'TOKEN_META_ACTUALIZADO: OK. No se ha publicado ninguna imagen.'
    Write-Host 'Avisa en ChatGPT solamente de este estado (nunca copies el token).'
} finally {
    $secure = $null
    $userToken = $null
    $pageToken = $null
    $headers = $null
    $pageHeaders = $null
}

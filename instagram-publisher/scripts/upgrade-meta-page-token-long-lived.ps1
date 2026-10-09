# Upgrade a valid Meta USER token to a long-lived (~60 day) USER token,
# then derive a potentially non-expiring PAGE token for @ttactualidad.
# No credentials are saved in files, command lines, GitHub, or this chat.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$publisher = (Resolve-Path (Join-Path $folder '..')).Path
$worker = 'tt-actualidad-instagram-pilot'
$pageId = '1424696600717440'
$igId = '17841414511690117'
$api = 'https://graph.facebook.com/v26.0'
$appId = ''
$appSecret = $null
$userToken = $null
$longToken = $null
$pageToken = $null

function Read-Hidden([string]$prompt) {
    $secure = Read-Host $prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        $secure = $null
    }
}
function UrlEscape([string]$value) {
    return [Uri]::EscapeDataString($value)
}
function MetaGet([string]$uri, [string]$token = '') {
    $headers = @{ 'User-Agent' = 'TTActualidad-LongLivedTokenSetup/1.0' }
    if ($token) { $headers['Authorization'] = 'Bearer ' + $token }
    # Do not leak sensitive URL/query data in PowerShell's exception message.
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    } catch {
        throw 'Meta no ha aceptado la consulta de autorización. No se ha actualizado Cloudflare. Comprueba App ID, App Secret y token de usuario.'
    }
}

Write-Host ''
Write-Host 'TT Actualidad: configurar token de pagina de larga duracion.'
Write-Host 'Necesitas App ID + App Secret en Meta for Developers > App settings > Basic.'
Write-Host 'Tambien un token de USUARIO valido generado con tu aplicacion (Graph API Explorer).'
Write-Host 'Permisos: pages_show_list, pages_read_engagement, instagram_basic, instagram_content_publish.'
Write-Host 'Ninguno de estos valores debe pegarse en ChatGPT ni en un repositorio.'
Write-Host ''

try {
    $appId = (Read-Host 'Meta App ID (identificador numerico)').Trim()
    if ($appId -notmatch '^\d{5,30}$') {
        throw 'App ID incorrecto. Se esperaba un identificador numerico.'
    }
    $appSecret = Read-Hidden 'Meta App Secret (entrada oculta)'
    $userToken = Read-Hidden 'USER Access Token valido (entrada oculta)'
    if ($appSecret.Length -lt 16 -or $userToken.Length -lt 30) {
        throw 'App Secret o token de usuario no valido.'
    }
    Write-Host 'Solicitando intercambio de token de usuario de larga duracion...'

    $url = $api + '/oauth/access_token?grant_type=fb_exchange_token' +
           '&client_id=' + (UrlEscape $appId) +
           '&client_secret=' + (UrlEscape $appSecret) +
           '&fb_exchange_token=' + (UrlEscape $userToken)
    $exchange = MetaGet $url
    $url = $null
    $longToken = [string]$exchange.access_token
    $expiresIn = [long]$exchange.expires_in
    if ($longToken.Length -lt 30 -or $expiresIn -lt 30 * 24 * 3600) {
        throw 'Meta no ha emitido un token de usuario suficientemente duradero. No se tocara Cloudflare.'
    }
    Write-Host ('Token de usuario extendido: duracion aproximada de ' +
                [Math]::Floor($expiresIn / 86400) + ' dias.')
    $userToken = $null

    # With a long-lived user token, derive a Page token rather than storing
    # the expiring USER token as INSTAGRAM_PAGE_ACCESS_TOKEN.
    $fields = UrlEscape 'id,name,access_token,instagram_business_account{id,username}'
    $page = MetaGet ($api + '/' + $pageId + '?fields=' + $fields) $longToken
    if ([string]$page.id -ne $pageId -or
        [string]$page.instagram_business_account.id -ne $igId -or
        [string]$page.instagram_business_account.username -ne 'ttactualidad') {
        throw 'La pagina no coincide con la cuenta @ttactualidad. No se tocara Cloudflare.'
    }
    $pageToken = [string]$page.access_token
    if ($pageToken.Length -lt 30) {
        throw 'Meta no ha devuelto un Page Access Token. No se tocara Cloudflare.'
    }
    $me = MetaGet ($api + '/me?fields=id,name') $pageToken
    if ([string]$me.id -ne $pageId) {
        throw 'El Page Access Token no identifica la pagina TT Actualidad. No se tocara Cloudflare.'
    }

    # Read-only expiry diagnostic using the app token. If Meta blocks
    # inspection, do not pretend this Page token is non-expiring.
    $debug = $null
    $inspected = $false
    try {
        $debugUri = $api + '/debug_token?input_token=' + (UrlEscape $pageToken) +
                    '&access_token=' + (UrlEscape ($appId + '|' + $appSecret))
        $debug = MetaGet $debugUri
        $debugUri = $null
        $inspected = $true
    } catch {
        Write-Warning 'Meta no ha permitido inspeccionar la fecha de caducidad; el token ha sido validado contra la pagina.'
    }
    if ($inspected) {
        if ($debug.data.is_valid -ne $true) {
            throw 'Meta considera invalido el token de pagina. No se tocara Cloudflare.'
        }
        $expiry = [long]$debug.data.expires_at
        if ($expiry -eq 0) {
            Write-Host 'Meta confirma: Page Access Token sin fecha de caducidad programada.'
        } else {
            $expiration = [DateTimeOffset]::FromUnixTimeSeconds($expiry)
            $remaining = ($expiration - [DateTimeOffset]::UtcNow).TotalDays
            if ($remaining -lt 30) {
                throw 'El token de pagina caducara pronto. No se sustituira el token activo de Cloudflare.'
            }
            Write-Host ('Meta indica caducidad de Page token: ' + $expiration.ToString('yyyy-MM-dd') + ' UTC.')
        }
    }
    Write-Host 'Pagina TT Actualidad y @ttactualidad comprobadas.'
    Write-Host 'Guardando SOLO el nuevo Page Access Token en el Worker de Instagram...'
    Push-Location $publisher
    try {
        $pageToken | & npx.cmd wrangler secret put INSTAGRAM_PAGE_ACCESS_TOKEN --name $worker
        if ($LASTEXITCODE -ne 0) { throw 'Wrangler no ha confirmado la actualizacion.' }
    } finally {
        Pop-Location
    }
    Write-Host 'TOKEN_META_LARGA_DURACION_OK. No se ha publicado ninguna imagen.'
    Write-Host 'Aunque no tenga caducidad fija, Meta puede revocarlo si cambian permisos o la cuenta.'
} finally {
    $appSecret = $null
    $userToken = $null
    $longToken = $null
    $pageToken = $null
    $url = $null
    $debugUri = $null
}

# TT Actualidad — publicación controlada en Instagram

## Estado validado, 9 de octubre de 2026

- Cuenta: **@ttactualidad**, vinculada a la página TT Actualidad (ID `1424696600717440`), Instagram User ID `17841414511690117`.
- Publicador independiente: `tt-actualidad-instagram-pilot`, con base Cloudflare D1 `tt-actualidad-instagram`.
- Control editorial manual por botones Telegram en TTendencias y TTiTTulares; **no se publica automáticamente** cuando un contenido pasa a READY.
- Las acciones de Instagram son independientes de «Publicado»/«Desestimar» de X y no borran mensajes.
- Validación real: Shakira `https://www.instagram.com/p/DeQ-5r7DNct/`, Real Madrid `https://www.instagram.com/p/DeQ-7ApjLnD/`; ambos confirmados por Meta sin duplicados.
- La imagen es el JPEG preparado junto al paquete; no se regenera al publicar.
- D1 deduplica por `source:event_id`. Las publicaciones en estado `uncertain` NO deben repetirse automáticamente.

## Texto y etiquetas de Instagram

`shared/instagram_pilot.py` prepara el snapshot de Instagram al enviar cada nuevo paquete Telegram.
Conserva el texto factual y el remate exactamente como se aprobaron, omite la repetición de
`@ttactualidad` y la coletilla fija «Ilustración satírica generada con IA», y añade etiquetas
temáticas que aparecen efectivamente en el contenido, hasta cuatro en total (incluidas las
etiquetas ya existentes). Ejemplos: `#Shakira`, `#LaRevuelta`, `#RealMadrid`, `#Euroliga`.
No inventa personas o noticias para ganar visibilidad. Los paquetes anteriores y publicaciones
ya hechas no se modifican. Instagram enseña por su cuenta el nombre de usuario como autor.

**Transparencia:** quitar la frase fija del pie no elimina las políticas de Meta sobre
contenidos sintéticos. Usar sus etiquetas de «Información de IA» cuando correspondan
y evitar presentar ilustraciones fotorealistas como fotografías documentales reales.

## Token de Meta de larga duración

El token de página derivado directamente de un token de usuario de Graph API Explorer
puede caducar pronto. Para mayor estabilidad: `USER token breve` →
intercambio `fb_exchange_token` usando **App ID y App Secret** →
`USER token ~60 días` → nuevo **Page Access Token** de larga duración
(puede figurar sin caducidad programada; sigue siendo revocable).

En el PC Windows autenticado con Wrangler:

1. Abrir `https://developers.facebook.com/apps/`, entrar en la app
   **TT Actualidad Publicador** → *Configuración de la aplicación* → *Básica*.
   Copiar **App ID** y preparar el **App Secret**, sin pegarlos en ChatGPT.
2. Obtener un **USER Access Token** vigente desde `https://developers.facebook.com/tools/explorer/`
   con `pages_show_list`, `pages_read_engagement`, `instagram_basic`
   e `instagram_content_publish`, usando esa misma app.
3. En PowerShell:

   ```powershell
   Set-Location "$env:USERPROFILE\europapress-rss"
   git pull --ff-only origin main
   if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar el repositorio." }
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   & ".\instagram-publisher\scripts\upgrade-meta-page-token-long-lived.ps1"
   ```

4. Introducir App ID, App Secret (oculto) y token de usuario (oculto).
   El script comprueba el token extendido, la página y cuenta correctas,
   consulta opcionalmente la fecha de caducidad con `debug_token`,
   y guarda **únicamente** el Page Access Token en
   `INSTAGRAM_PAGE_ACCESS_TOKEN` de Cloudflare.
5. Esperar `TOKEN_META_LARGA_DURACION_OK` y verificar `GET /meta-preflight`
   a través del workflow autenticado (sin volver a publicar ni tocar X).
   No hace falta redeploy del código del Worker después de cambiar este secreto.

Nunca publicar App Secret, USER token o Page token en chats, logs, GitHub ni archivos.
El script de emergencia `renew-meta-page-token.ps1` sigue disponible, pero
**no convierte** el token de usuario en uno de larga duración.

## Contrato y seguridad

- `GET /health` no requiere autenticación y muestra `active` (sin secretos).
- `GET /meta-preflight` requiere `INSTAGRAM_INTERNAL_SECRET` y valida de forma read-only
  la página, el Instagram asociado, el token y el esquema D1.
- `POST /publish` requiere el mismo secreto, comprueba origen `ttendencias` o
  `ttittulares`, identidad del envío, JPEG alojado en el repositorio y caption de ≤2200 caracteres.
- El servicio reserva en D1, crea el contenedor, espera su finalización y lo publica.
  Si la fase de publicación es ambigua, permanece bloqueada para evitar dobles publicaciones.
- No almacenar credenciales Meta en GitHub ni modificar MoneyWiz/X.

Las pruebas de integración de texto, botones, URL JPEG y publicación idempotente están
en `instagram-publisher/test/`.

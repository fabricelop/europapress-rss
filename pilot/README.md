# TTActualidad — piloto aislado de decisiones directas
Fecha: 2026-10-15

## Alcance
- Cambia exclusivamente `docs/index.html` en esta rama de prueba.
- Mantiene el origen de datos de TTActualidad y sus pestañas habituales.
- Sustituye en esta prueba las acciones `prepare` y `deleted` por peticiones HTTP al Worker piloto (sin Telegram).
- Permite deslizar tarjetas de TTiTTulares en estado En elaboración, Creciendo o Problemática: derecha → preparar, izquierda → desestimar.
- El botón «Configurar Worker de prueba» solicita la URL HTTPS y el token para cada sesión, sin guardar el token en el repositorio.
- No cambia ni conecta `TTiTTularesDedicatedListener.ps1`, `TTendenciasDedicatedListener.ps1`, colas de producción, ni generación de imágenes.

## Estado importante
**Piloto de interfaz y buzón, NO sistema de decisiones operativo en producción.**
El Worker no está desplegado y el PC no consume su buzón. Ninguna decisión pulsada desde esta rama llega a producción, y así debe seguir siendo hasta validar las reglas, autenticación y deduplicación.

## Backend de pruebas
`pilot/ttactualidad-worker.js`: Worker aislado. Requiere:
- Namespace KV dedicado `PILOT_DECISIONS` (nunca el de producción)
- Secreto `PILOT_TOKEN`
- CORS únicamente desde `https://fabricelop.github.io`
- Endpoints `GET /health`, `POST /api/decision` y `GET /api/decisions`.
- No llama a Telegram, GitHub ni PC. No invoca procesamiento editorial.

**Despliegue no realizado.** No habilitar ni cambiar rutas en los Workers de producción.

## Cómo probar la interfaz sin publicar
Desde `europapress-rss`, crear una copia aislada con:
```powershell
git fetch origin pilot/ttactualidad-direct-decisions-20261015
git show origin/pilot/ttactualidad-direct-decisions-20261015:docs/index.html > "$env:TEMP\\TTActualidad-piloto.html"
```
Para conservar codificación UTF-8 en Windows PowerShell 5.1 es preferible:
```powershell
$src = cmd.exe /d /c "git show origin/pilot/ttactualidad-direct-decisions-20261015:docs/index.html"
[IO.File]::WriteAllText("$env:TEMP\\TTActualidad-piloto.html",($src -join "`n"),[Text.UTF8Encoding]::new($false))
```
Abrir el HTML en el navegador del PC. Las imágenes y datos de GitHub pueden depender de CORS/permiso file://; para prueba integral alojar la rama por un origen HTTPS piloto distinto o un servidor local.

## Siguientes comprobaciones
1. Desplegar Worker de PRUEBA (no de producción) y comprobar autenticación y cuota de Cloudflare.
2. Validar los gestos en iPhone y recepción de órdenes de prueba en `PILOT_DECISIONS`.
3. Diseñar un puente autorizado que entregue decisiones al PC y su comportamiento con temporizador de 10 minutos, con exclusión de órdenes atrasadas.
4. Solo tras verificarlo y obtener autorización explícita, considerar integración de decisiones reales. No modificar producción por defecto.

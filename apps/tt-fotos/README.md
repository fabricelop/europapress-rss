# TT Fotos independiente · Cloudflare Worker + R2 + D1

**Estado:** implementación de código y pruebas; **no desplegado**, sin conexión real aún a la biblioteca privada de ChatGPT Imágenes. Esta aplicación está completamente separada de `ttactualidad.rainyraven22.chatgpt.site` y de la bandeja del iPhone.

## Arquitectura

- `src/worker.mjs`: sirve galería e interfaz y enruta su API privada. **Cloudflare Access obligatorio y verificado criptográficamente** (JWT RS256: firma, `kid`, issuer, audience, caducidad, correo permitido).
- `src/access.mjs`: no acepta solo la cabecera de email, ni cabeceras falsas o una sesión sin firma.
- `public/index.html`: monitor remoto con fichas asociadas, «Sin asociar» y confirmación de coincidencias dudosas.
- `FOTOS_DB` (D1): trabajos, assets, asociaciones, historial; esquema en `migrations/0001_init.sql`.
- `FOTOS_R2` (R2 privado): PNG duraderos bajo hash SHA256. **No habilitar dominio público R2.**
- API propia `/api/tt-fotos/v1/*` en `src/lib/api.mjs`, independiente del Site anterior.
- `scripts/build-companion.mjs`: genera extensión Chrome limitada al dominio HTTPS real del nuevo TT Fotos, más ChatGPT. El origen conserva el PNG en memoria y el destino lo escribe directamente en R2 privado. El equipo no se utiliza como almacén de fotografías.

## Preparación de infraestructura

No ejecutar todavía sin revisar que las credenciales y los bindings corresponden a la cuenta correcta de Cloudflare. Crear un **Worker nuevo** llamado, por ejemplo, `tt-fotos-independent`; nunca sustituir los Workers existentes.

1. Crear bucket R2 **privado** `tt-fotos-originals-private`, sin dominio `r2.dev` público ni dominio personalizado público.
2. Crear D1 `tt-fotos-private`. Aplicar `schema.sql` de cloud-v1 **solo a la nueva D1**.
3. Copiar `wrangler.jsonc.example` a `wrangler.jsonc`, rellenar `database_id`, `CF_ACCESS_ISSUER` y `CF_ACCESS_AUD`. El fichero de configuración real NO se sube al repositorio.
4. En Cloudflare Zero Trust → Access → Applications crear una aplicación independiente para el URL del Worker. Autorizar exclusivamente a los editores pertinentes. Su AUD se copia en `CF_ACCESS_AUD`. Configurar la variable **secreta** `TT_FOTOS_ALLOWED_EMAIL` como lista separada por comas de direcciones autorizadas. Esa variable se comprueba además de la política Access.
5. Con la sesión de la cuenta Cloudflare adecuada en `wrangler`: `npx wrangler d1 execute tt-fotos-private --remote --file=migrations/0001_init.sql` desde `apps/tt-fotos`, revisar el resultado, y luego `npx wrangler deploy`.
6. Verificar que **sin iniciar sesión** el Worker devuelve 403 tanto en `/fotos` como en `/api/tt-fotos/v1/status`, y que el origen está efectivamente protegido por Access.
7. Una vez desplegado, desde la raíz `apps/tt-fotos`: `node scripts/build-companion.mjs https://TU-URL-REAL-DE-TT-FOTOS`; instalar la carpeta `dist/chrome-companion` como extensión sin empaquetar en Chrome, revisando permisos. No instalar el conector antiguo cuyo destino era el Site.
8. Iniciar sesión en la página **independiente** TT Fotos y en `https://chatgpt.com/images`. Pulsar el icono de la extensión solo cuando se vean imágenes de calidad suficiente (o en sus conversaciones originales). El conector aún no garantiza enumeración exhaustiva del catálogo; lee recursos visibles y no usa APIs privadas de ChatGPT.

## Reglas funcionales

- Si imagen y prompt originales acreditan en **el mismo turno** `TTITTULARES_IMAGE_JOB_V4` o `TTENDENCIAS_IMAGE_JOB_V4`, `commandId`, proyecto, revisión, y trabajo exacto de GitHub, la API asocia automáticamente.
- Si no hay prueba completa, guarda en R2 con estado «Sin asociar»; en la web el editor puede asociar manualmente proporcionando un comando exacto de la ficha. La API valida el job antes de confirmar; jamás decide por nombre o apariencia.
- La última asociación reemplaza la foto mostrada de ese **mismo encargo**; no borra PNG anteriores ni historial. Un duplicado idéntico solo se confirma una vez.
- El catálogo ChatGPT Imágenes completo puede **no ser accesible** al conector de navegador: no se promete recuperar imágenes fuera de la sesión/recursos visibles. Ante CORS, falta de original o DOM diferente, se registra fallo y no se inventa éxito.
- **Ninguna acción ni modificación** sobre `/api/image-inbox/v1/*`, Telegram, X, Instagram o el Site TTActualidad anterior.

## Comprobaciones antes de declarar éxito

`node --test tests/*.test.mjs` desde `apps/tt-fotos`. En CI, ejecutar también `node --test tests/api.test.mjs` para verificar su API propia.

**Piloto:** abrir el propio Worker protegido, autenticar editor, recuperar 1 PNG de noticia y 1 PNG de tendencia; comparar SHA de R2 y pantalla; asociar una imagen sin prueba exacta manualmente; repetir sin duplicar; confirmar que el Site/app iPhone no han sido tocados. Después ampliar a nuevas imágenes desde el 10 de noviembre de 2026 y evaluar cobertura real del catálogo.

## Restricciones de despliegue

No hay acceso de este chat a Cloudflare R2, D1, Zero Trust ni a la sesión privada del usuario en ChatGPT Imágenes. **Un commit/PR o pruebas unitarias no equivale a despliegue ni a fotos importadas**. Para ejecutar la conexión real hay que usar un navegador autenticado en ChatGPT Work o una sesión Cloudflare autorizada, con estas instrucciones. No sustituir estas pruebas por una promesa de importación automática.
## Búsqueda manual por nombre

La galería «Sin asociar» ofrece búsqueda por **titular o nombre de tendencia**, además de la opción de escribir un `commandId` completo. La búsqueda toma únicamente noticias actualmente listas (`main/ttittulares/prepared.json`) y las tendencias del Top 30 actual (`main/trends/site-top30-current.json`). Al elegir la ficha se consulta su job exacto de GitHub y se recupera el `commandId) verificable. Si esa revisión no está conservada, la imagen permanece sin asociar; no se inventa ninguna identidad. El histórico fuera de esas fuentes necesita un índice de jobs adicional.

## Despliegue manual autorizado desde GitHub Actions

El workflow `.github/workflows/tt-fotos-standalone-deploy.yml` se ejecuta **únicamente mediante `workflow_dispatch`**, nunca por un push. Deben estar configurados en el repositorio los secrets `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `TT_FOTOS_ALLOWED_EMAIL` y las variables `TT_FOTOS_D1_DATABASE_ID`, `TT_FOTOS_ACCESS_ISSUER`, `TT_FOTOS_ACCESS_AUD`.

Se espera que D1, R2 y la política Access del Worker estén **creadas previamente**. El workflow aplica migraciones solamente a la D1 de TT Fotos y despliega solamente `tt-fotos-independent`. Si faltan variables o secretos, falla sin desplegar. No configura automáticamente una sesión de ChatGPT Imágenes, no importa imágenes sin una acción autenticada del editor y no toca la app iPhone.

## Verificación de entrega

Hasta verificar una instalación real en la cuenta Cloudflare autorizada y una imagen recuperada de una conversación real, todo queda **preparado en código, no operativo en producción**. Los tests unitarios locales del aislamiento y validación de Access (8 pasando) no sustituyen el piloto real del navegador o la verificación de R2/D1. El CI completo definido en GitHub Actions incluye pruebas de la API y la extensión, pero no se ha confirmado aquí su resultado.

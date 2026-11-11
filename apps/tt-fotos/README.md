# TT Fotos independiente · Cloudflare Worker + R2 + D1

**Estado:** implementación de código y pruebas; **no desplegado**, sin conexión real aún a la biblioteca privada de ChatGPT Imágenes. Esta aplicación está completamente separada de `ttactualidad.rainyraven22.chatgpt.site` y de la bandeja del iPhone.

## Arquitectura

- `src/worker.mjs`: sirve galería e interfaz y enruta su API privada. **Cloudflare Access obligatorio y verificado criptográficamente** (JWT RS256: firma, `kid`, issuer, audience, caducidad, correo permitido).
- `src/access.mjs`: no acepta solo la cabecera de email, ni cabeceras falsas o una sesión sin firma.
- `public/index.html`: monitor remoto con fichas asociadas, «Sin asociar» y confirmación de coincidencias dudosas.
- `FOTOS_DB` (D1): trabajos, assets, asociaciones, historial; esquema en `migrations/0001_init.sql`.
- `FOTOS_R2` (R2 privado): PNG duraderos bajo hash SHA256. **No habilitar dominio público R2.**
- API propia y aislada `/api/tt-fotos/v1/*` en `src/lib/api.mjs`. No realiza llamadas al Site antiguo.
- `scripts/build-companion.mjs`: genera extensión Chrome limitada al dominio HTTPS real del nuevo TT Fotos, más ChatGPT. El origen conserva el PNG en memoria y el destino lo escribe directamente en R2 privado. El equipo no se utiliza como almacén de fotografías.

## Preparación de infraestructura

No ejecutar todavía sin revisar que las credenciales y los bindings corresponden a la cuenta correcta de Cloudflare. Crear un **Worker nuevo** llamado, por ejemplo, `tt-fotos-independent`; nunca sustituir los Workers existentes.

1. Crear bucket R2 **privado** `tt-fotos-originals-private`, sin dominio `r2.dev` público ni dominio personalizado público.
2. Crear D1 `tt-fotos-private`. Aplicar `migrations/0001_init.sql` **solo a la nueva D1**.
3. Copiar `wrangler.jsonc.example` a `wrangler.jsonc`, rellenar `database_id`, `CF_ACCESS_ISSUER` y `CF_ACCESS_AUD`. El fichero de configuración real NO se sube al repositorio.
4. En Cloudflare Zero Trust → Access → Applications crear una aplicación independiente para el URL del Worker. Autorizar exclusivamente a los editores pertinentes. Su AUD se copia en `CF_ACCESS_AUD`. Configurar la variable **secreta** `TT_FOTOS_ALLOWED_EMAIL` como lista separada por comas de direcciones autorizadas. Esa variable se comprueba además de la política Access.
5. Con la sesión de la cuenta Cloudflare adecuada en `wrangler`: `npx wrangler d1 execute tt-fotos-private --remote --file=migrations/0001_init.sql` desde `apps/tt-fotos`, revisar el resultado, y luego `npx wrangler deploy`.
6. Verificar que **sin iniciar sesión** el Worker devuelve 403 tanto en `/fotos` como en `/api/tt-fotos/v1/status`, y que el origen está efectivamente protegido por Access.
7. Una vez desplegado, desde la raíz `apps/tt-fotos`: `node scripts/build-companion.mjs https://TU-URL-REAL-DE-TT-FOTOS`; instalar la carpeta `dist/chrome-companion` como extensión sin empaquetar en Chrome, revisando permisos. No instalar el conector antiguo cuyo destino era el Site.
8. Iniciar sesión en la página **independiente** TT Fotos y en `https://chatgpt.com/images`. Pulsar el icono de la extensión, elegir **«Importar imágenes abiertas»** y ver el resultado: detectadas, guardadas, sin asociar y omitidas, con motivos. Si solo hay miniaturas, abrir una imagen a tamaño completo y repetir. El conector aún no garantiza enumeración exhaustiva del catálogo; lee recursos visibles y no usa APIs privadas de ChatGPT.

## Reglas funcionales

- Si imagen y prompt originales acreditan en **el mismo turno** `TTITTULARES_IMAGE_JOB_V4` o `TTENDENCIAS_IMAGE_JOB_V4`, `commandId`, proyecto, revisión, y trabajo exacto de GitHub, la API asocia automáticamente.
- Si no hay prueba completa, guarda en R2 con estado «Sin asociar»; en la web el editor puede asociar manualmente proporcionando un comando exacto de la ficha. La API valida el job antes de confirmar; jamás decide por nombre o apariencia.
- La última asociación reemplaza la foto mostrada de ese **mismo encargo**; no borra PNG anteriores ni historial. Un duplicado idéntico solo se confirma una vez.
- El catálogo ChatGPT Imágenes completo puede **no ser accesible** al conector de navegador: no se promete recuperar imágenes fuera de la sesión/recursos visibles. Ante CORS, falta de original o DOM diferente, se registra fallo y no se inventa éxito.
- **Ninguna acción ni modificación** sobre `/api/image-inbox/v1/*`, Telegram, X, Instagram o el Site TTActualidad anterior.

## Comprobaciones antes de declarar éxito

`node --test tests/*.test.mjs` desde `apps/tt-fotos`. Incluye las pruebas de la API propia y del conector Chrome. **29/29 pruebas superadas localmente** inicialmente; tras las nuevas comprobaciones de asociación, **36/36 pruebas superadas en CI GitHub Actions el 11/11/2026**.

**Piloto:** abrir el propio Worker protegido, autenticar editor, recuperar 1 PNG de noticia y 1 PNG de tendencia; comparar SHA de R2 y pantalla; asociar una imagen sin prueba exacta manualmente; repetir sin duplicar; confirmar que el Site/app iPhone no han sido tocados. Después ampliar a nuevas imágenes desde el 10 de noviembre de 2026 y evaluar cobertura real del catálogo.

## Restricciones de despliegue

No hay acceso de este chat a Cloudflare R2, D1, Zero Trust ni a la sesión privada del usuario en ChatGPT Imágenes. **Un commit/PR o pruebas unitarias no equivale a despliegue ni a fotos importadas**. Para ejecutar la conexión real hay que usar un navegador autenticado en ChatGPT Work o una sesión Cloudflare autorizada, con estas instrucciones. No sustituir estas pruebas por una promesa de importación automática.

## Actualización de recuperación visible y seguridad (11/11/2026)

El conector incluye ahora un popup con cuatro contadores (detectadas, guardadas, sin asociar y omitidas), detalle de omisiones y botón explícito de importación. No importa imágenes automáticamente al navegar; la acción del editor inicia cada pasada. La lectura está limitada a 12 recursos visibles de resolución suficientemente alta por pasada. **Los mosaicos/miniaturas del catálogo no se convierten falsamente en originales.**

La asociación automática solo puede usar el marcador del **turno de usuario inmediatamente anterior** al turno del asistente que contiene la imagen, además de exigir la identidad editorial y conversación registrada. Si hay mensajes intermedios, la foto queda sin asociar para evitar una atribución errónea. El popup no almacena originales en el disco.

El directorio `extension-templates/` incluye `popup.html`, `popup.js` y los 4 archivos anteriores. `node scripts/build-companion.mjs https://ORIGEN-REAL-DE-TT-FOTOS` genera `dist/chrome-companion` con el hostname correcto y los seis archivos del paquete de Chrome. **No usar la URL de ensayo** utilizada por las pruebas como URL de producción.

El código y pruebas están disponibles, pero **sigue faltando el despliegue real**: este chat no tiene una conexión autenticada a la cuenta Cloudflare ni a ChatGPT Imágenes. No hay un Worker independiente accesible ni PNG de producción importado hasta realizar el piloto en una sesión autorizada. No lanzar un deployment genérico en la cuenta equivocada ni cambiar los Workers existentes.
## Actualización de asociación de fichas (11/11/2026)

Se comprobó que las antiguas rutas `control/.../image-runs/jobs/<id>.json` **devuelven 404** para varios encargos reales. Esto no significa que la noticia o tendencia no exista. Por ejemplo, TTiTTulares `683beffb5aed` sigue en el radar `ttittulares/status.json`; TTendencias `e617da285349` sigue en `trends/site-top30-current.json`.

La búsqueda privada ahora incluye las noticias del radar. El proveedor de encargos distingue dos niveles:

1. **`exact_job`:** archivo de encargo original accesible en GitHub, con comando, proyecto, id y revisión coincidentes. Solo este nivel puede asociar **automáticamente** una fotografía, siempre con la evidencia exacta del turno ChatGPT.
2. **`editorial_identity_only`:** el archivo de encargo original falta (404), pero GitHub corrobora el identificador editorial y revisión en noticias preparadas/radar o Top 30. El comando se obtiene exclusivamente del prompt ChatGPT o de la entrada exacta del editor; **jamás se inventa**. La fotografía queda **sin asociar** hasta una confirmación explícita del editor. El monitor muestra una advertencia sobre el recibo faltante antes de confirmar.

Una respuesta errónea (5xx), un recibo contradictorio o una revisión distinta **no** activan este modo alternativo. Las fotografías y asociaciones se almacenan exclusivamente en D1/R2 privados de TT Fotos. El Site anterior y la bandeja iPhone no se escriben. Esta alternativa permite recuperar fichas sin hacer pasar una coincidencia editorial por una verificación del encargo original.

**CI comprobado:** `36/36` pruebas del Worker/monitor/extensión aprobadas en GitHub Actions el 11/11/2026 (ejecución [43092592207](https://github.com/fabricelop/europapress-rss/actions/runs/43092592207), commit `a862471d064883c22901fc6893c377a7dd96cc8d`). Esto **no** implica despliegue ni recuperación real de fotografías.

## Control de despliegue y duplicados (11/11/2026)

- Cloudflare permite proteger **un único Worker** en Workers & Pages → `tt-fotos-independent` → Access → `Protect this Worker behind Access` → **All traffic**. Es preferible a proteger solo un hostname porque cubre también `workers.dev`, dominios y previews sin modificar los otros Workers. Mantener simultáneamente la validación criptográfica del JWT y la lista de correos del propio Worker. Comprobar que el AUD configurado corresponde **exactamente a esta nueva aplicación Access**.
- **No confundir dos puertas:** Cloudflare Access puede redirigir al login (HTTP 302/303) antes de ejecutar el Worker; una llamada directa al Worker sin JWT válido debe ser rechazada (HTTP 403). Un 403 por sí solo no demuestra que la política Access del borde esté activa.
- La comprobación anónima de solo lectura se ejecuta desde `apps/tt-fotos`: `node scripts/check-live-access.mjs https://ORIGEN-REAL-TT-FOTOS`. Debe fallar si la galería o su API responde 200 sin autenticación, si la ruta no existe, o si redirige fuera del login de Access. No envía credenciales ni fotografías.
- En el GitHub Action de despliegue manual, se puede configurar la **variable opcional de repositorio** `TT_FOTOS_PUBLIC_ORIGIN` con el origen **real** del nuevo Worker. Si está presente, el workflow realiza automáticamente esa comprobación después de desplegar y configurar el secreto del editor. La validación completa con una sesión autorizada de ChatGPT Imágenes **sigue siendo manual**.
- Repetir la importación del mismo PNG para el mismo encargo ahora devuelve `operation: unchanged`: conserva la asociación y la confianza anteriores, sin generar una fila adicional de historial. El SHA y las versiones anteriores permanecen disponibles.
- **No ejecutar** el workflow de despliegue sin haber creado R2 y D1 **nuevos**, confirmado la cuenta correcta y configurado Access para este Worker. Sin las credenciales reales el despliegue no es posible desde esta conversación.

## Barrera adicional: comprobar que R2 no está expuesto

Antes de aplicar cualquier SQL remoto, el workflow `tt-fotos-standalone-deploy.yml` comprueba ahora en modo de **solo lectura**:

- `scripts/verify-remote-resources.mjs`: UUID de la D1 y nombre del bucket R2 en la cuenta seleccionada.
- `scripts/verify-private-r2.mjs`: API de Cloudflare para la dirección pública administrada `r2.dev` y para los dominios personalizados del bucket. Exige `enabled:false` en `r2.dev` y en cada dominio registrado; los errores, permisos insuficientes o respuestas incompletas **bloquean** el despliegue.
- La verificación utiliza las variables ya previstas `CLOUDFLARE_API_TOKEN` y `CLOUDFLARE_ACCOUNT_ID`, sin guardar ni mostrar el token. No cambia reglas de dominio, no cierra buckets existentes y no publica fotografías.

Se verificaron los nombres de las operaciones en la documentación Cloudflare: `GET /accounts/{account_id}/r2/buckets/{bucket_name}/domains/managed` y `GET /accounts/{account_id}/r2/buckets/{bucket_name}/domains/custom`. Al desplegar, es imprescindible que el token de la cuenta correcta tenga permisos de lectura R2.

**Importante:** este control de R2 no crea ni activa la aplicación Cloudflare Access. Esa aplicación, con alcance exclusivo del Worker `tt-fotos-independent` y política de editores, debe quedar configurada antes de aceptar el despliegue como operativo. La galería de `chatgpt.com/images` todavía requiere un piloto autenticado con la extensión de Chrome. CI verde nunca equivale a fotografías importadas.



## Instalación independiente desde GitHub Actions — propuesta PR #388

Esta sección describe **código propuesto, sin desplegar**. Está aislado en una PR en borrador y requiere pruebas verdes antes de fusionar. Los workflows anteriores en cola usan otro commit y no contienen esta preparación.

- **Recursos privados:** `.github/workflows/tt-fotos-prepare-storage.yml` admite inspección de solo lectura (por defecto) o creación de recursos ausentes con `create_missing=true`. `scripts/prepare-private-resources.mjs` consulta nombres exactos, valida UUID si se proporcionó, no elimina ni reconfigura recursos existentes y comprueba que R2 no tenga acceso público. Solo crea `tt-fotos-private` y `tt-fotos-originals-private` con una orden explícita.
- **Acceso de editor:** `scripts/prepare-worker-access.mjs` verifica las aplicaciones de Cloudflare Access del Worker `tt-fotos-independent`. Con una orden explícita puede crear **solo si falta** una nueva app `self_hosted` dirigida a este Worker, con política de correos individuales obtenidos de `TT_FOTOS_ALLOWED_EMAIL`. Nunca actualiza aplicaciones o políticas existentes. Rechaza reglas `everyone`, dominios enteros, `bypass`, excepciones públicas y aplicaciones compartidas con otro Worker. Exige permisos de **Access: Apps and Policies Write** para crearla.
- **Despliegue de una sola aplicación:** `.github/workflows/tt-fotos-standalone-deploy.yml` admite dos indicadores, `create_missing_storage` y `create_missing_access`, ambos **desactivados por defecto**. Solo cuando se autorizan de forma explícita crea recursos ausentes; nunca reutiliza silenciosamente una base con identificador contradictorio ni modifica otros Workers.
- **Primera instalación:** si Access todavía no existe y se autoriza crearlo, el primer despliegue se realiza con un AUD temporal no válido que **rechaza todas las autenticaciones**. Después se obtiene el AUD real de la app recién creada o verificada y se vuelve a desplegar únicamente `tt-fotos-independent`. Se reestablece la lista secreta de editores y se comprueba el rechazo anónimo en el Worker.
- **Conector:** tras las comprobaciones de privacidad, GitHub genera `tt-fotos-chrome-companion-private` como artefacto instalable de Chrome con permisos limitados a `chatgpt.com` y al origen real del Worker. Contiene **código, no fotos**. Debe instalarse en Chrome con la sesión de ChatGPT Imágenes abierta, y realizar una importación piloto visible. No se prometen todas las imágenes históricas del catálogo.

Configuración necesaria en GitHub: secretos `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `TT_FOTOS_ALLOWED_EMAIL`; variable `TT_FOTOS_ACCESS_ISSUER`. Opcionales si ya existen: `TT_FOTOS_D1_DATABASE_ID`, `TT_FOTOS_ACCESS_AUD` y `TT_FOTOS_PUBLIC_ORIGIN`. Nunca enviar los secretos por chat ni escribirlos en el repositorio. El token debe tener permisos suficientes para gestionar **únicamente los recursos autorizados de la cuenta**, incluidos D1, R2, Workers y Access; el script falla si no los tiene.

Tras el primer despliegue, conviene guardar en las variables del repositorio el AUD real de la aplicación y el UUID de la D1 para futuras verificaciones y ejecuciones sin creación. No activar una segunda instalación mientras otra ejecución de despliegue siga en cola. La **aceptación final** exige CI verde, Worker protegido y operativo, artefacto Chrome instalable, un PNG real comprobado en R2 con SHA y una asociación validada en la ficha, sin afectar al Site antiguo ni al iPhone.

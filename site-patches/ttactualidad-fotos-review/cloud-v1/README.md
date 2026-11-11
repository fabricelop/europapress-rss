# TT Fotos — importación privada desde ChatGPT Imágenes, automática cuando existe prueba exacta

**Estado del paquete:** implementación desarrollada y probada con datos simulados en Node 22; **NO desplegada en el TTActualidad Site**, **NO conectada a tu sesión real de ChatGPT Imágenes**. No se ha movido ningún PNG de producción ni se ha tocado el inbox del iPhone.

Este paquete es para incorporar al Site real `https://ttactualidad.rainyraven22.chatgpt.site`, que usa almacenamiento privado R2 y D1. **No es otra versión del monitor Windows.** El destino de las fotos es R2 privado del Site, no ninguna carpeta de `C:\TTiTTulares`.

## Qué está implementado

- `core.mjs`: verificación exacta de `commandId`, noticia/tendencia, revisión, conversación y marcador del encargo en un turno de ChatGPT. Jamás asocia por título, parecido visual ni fecha.
- `job-provider.mjs`: consulta el trabajo individual en la rama GitHub `control/ttittulares-run-trigger-v2` o `control/ttendencias-run-trigger`. No confunde índices incompletos con el histórico íntegro; si no encuentra el trabajo exacto, guarda la imagen sin asociación.
- `api.mjs`: API privada `/api/tt-fotos/v1/...`, distinta de `/api/image-inbox/v1/...`; necesita callback **real de editor GitHub OAuth del Site**, D1 y R2. Autorización obligatoria incluso para ver las imágenes. PNG validado, SHA-256, 8 MiB máximo, recibo de la propia galería, versiones anteriores preservadas e historial por cada asociación.
- `schema.sql`: tablas nuevas con prefijo `tt_fotos_`, aisladas de la bandeja del iPhone.
- `fotos.html`: web de editor para ver fichas, imágenes no asociadas y seleccionar la noticia/tendencia manualmente cuando falte identificación suficiente.
- `chrome-companion/`: conector opcional Chromium. **Solo tras clic explícito del editor** en ChatGPT Imágenes o conversación ChatGPT. Lee imágenes de alta resolución que el navegador ya ha cargado, transfiere bytes por memoria a una pestaña del Site autenticada (sin archivo descargado al disco) y muestra un contador de lo que pudo importar. Nunca usa endpoints privados no documentados de ChatGPT ni cookies extraídas. Si la UI ofrece WebP/JPEG visible, intenta crear una **copia visual PNG en memoria**, señalada `rendered_png_copy`, **no la presenta como PNG original binariamente idéntico**.
- `api.test.mjs`: pruebas automatizadas de autorización, integridad, asociación automática, caso ambiguo, histórico, privacidad y no sobreescritura física.

## Qué falta para que funcione con tus fotos

1. **Acceso de edición al Site**. Su código de sesión GitHub OAuth, bindings y rutas no están accesibles desde esta conversación. Integrar `createTTFotosApi({db,r2,authenticate,jobProvider})` con **el callback de autenticación real del Site** y los bindings R2/D1 reales. NO introducir `authenticate:()=>({isEditor:true})` en producción.
2. Ejecutar el esquema D1 nuevo con migración reversible. Asegurar R2 privado no público, sin modificar las tablas o endpoints de `image-inbox`.
3. Servir `fotos.html` bajo `/fotos` tras comprobar la sesión de editor y conectar el handler a `/api/tt-fotos/v1/*`.
4. Instalar en Chrome el conector sin empaquetar (carpeta `chrome-companion`), con los permisos específicos de `chatgpt.com` y el Site. Iniciar sesión en ambas pestañas. Abrir `https://chatgpt.com/images` y pulsar su icono **solo después de desplegar la API**. Importa imágenes de resolución suficiente actualmente visibles que se puedan leer o convertir; **NO puede enumerar ni exportar necesariamente toda la biblioteca** ni automatizar una paginación desconocida. Algunas imágenes del catálogo pueden quedar sin transferir si los originales están protegidos por CORS, el navegador muestra miniaturas o el DOM cambia.
5. Para asociación automática completa, abrir la **conversación de origen** con la imagen y el mensaje `TTITTULARES_IMAGE_JOB_V4` / `TTENDENCIAS_IMAGE_JOB_V4`. El conector toma imagen y marcador en un turno contiguo visible, el Site valida el trabajo GitHub exacto y entonces vincula. Desde la simple cuadrícula de Imágenes puede faltar la relación exacta: esas fotografías se guardan como «Sin asociar» para revisión manual desde TT Fotos.
6. Verificar un piloto real: noticia y tendencia del 10/11 de noviembre. Confirmar PNG en R2 y su SHA, asociación editorial correcta, lectura de ficha y que la bandeja privada del iPhone no cambió. Luego realizar recuperaciones por lotes pequeños con reintentos.

**No prometer recuperación del 100 %**: una biblioteca no accesible, una imagen visible solo como miniatura o una foto sin trabajo GitHub conservado impide rescate automático. Es preferible mostrar una incidencia real a inventar que la imagen se recuperó.

## API (privada; paths nuevos, no existentes hasta su integración)

| Método | Ruta | Función |
|---|---|---|
| `GET` | `/api/tt-fotos/v1/status` | Contadores R2/D1 de TT Fotos |
| `GET` | `/api/tt-fotos/v1/assets?state=unmatched` | Galería de fotos sin asociar |
| `GET` | `/api/tt-fotos/v1/jobs?since=2026-11-10` | Fichas registradas; **no todo el histórico** |
| `GET` | `/api/tt-fotos/v1/jobs/:commandId` | Consultar trabajo exacto en GitHub |
| `GET` | `/api/tt-fotos/v1/assets/:sha/original` | PNG privado solo para editor |
| `POST` | `/api/tt-fotos/v1/assets` | Transferencia directa en bytes y posible asociación automática |
| `POST` | `/api/tt-fotos/v1/matches` | Asociación o sustitución manual con confirmación explícita |

Todos los `POST` exigen sesión de editor, `Origin` igual al propio Site y encabezado `x-tt-fotos-action: editor-v1`. Jamás se envían fotografías a la bandeja iPhone. Si la fuente solo aporta una imagen de la cuadrícula sin prueba del encargo, queda en `unmatched` hasta confirmación.

### Ejemplo de adaptación a backend Site (pseudocódigo deliberado)

```js
import { createTTFotosApi } from './cloud-v1/api.mjs';
const handleTTFotos = createTTFotosApi({
  db: REAL_SITE_D1_BINDING,
  r2: REAL_SITE_PRIVATE_R2_BINDING,
  authenticate: async request => {
    // Resolver la sesión de editor con el Github OAuth actual del Site.
    // Si no existe o no hay permiso: devolver null; NUNCA permitir por defecto.
    const editor = await REAL_EXISTING_SITE_EDITOR_SESSION_LOOKUP(request);
    return editor?.authorizedForImages ? {isEditor:true} : null;
  }
});
// En el router existente del Site, para /api/tt-fotos/v1/*:
// return await handleTTFotos(request)
// En /fotos: verificar sesión GitHub editor y servir fotos.html
```

No hay plugin ni API verificada para acceder directamente a toda la biblioteca privada ChatGPT Imágenes desde un servicio backend. El conector usa solamente la interfaz ya abierta bajo sesión del usuario. Si la política del navegador o la interfaz bloquea la lectura de una imagen, queda reportada como no importada.

## Comprobar código localmente (sin red ni datos privados)

```bash
node --test api.test.mjs
node --check api.mjs
node --check chrome-companion/images-source.js
```

Las pruebas unitarias **no son una confirmación de despliegue, de funcionamiento de la extensión en la web real ni de recuperación de una foto privada**.
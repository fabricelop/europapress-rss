# TT Fotos — recuperación directa a fichas, sin almacén intermedio

## Decisión editorial actual (12 de noviembre de 2026)

El editor **NO quiere guardar una colección nueva** en Workers KV, un bucket R2 independiente, una base D1 de fotografías ni una galería que duplique imágenes. Tampoco quiere activar Zero Trust con método de pago. El objetivo es recuperar, desde la **interfaz autenticada de ChatGPT Imágenes**, la imagen ya generada y **asociarla directamente a la ficha editorial real** de TTiTTulares o TTendencias, con la misma comprobación de identidad que emplea el circuito de bandeja. Sin descargas a disco en Windows ni cambios en la bandeja iPhone, el Site anterior, X/Instagram o los Workers actualmente productivos.

### Flujo correcto

1. **Fuente:** extensión o proceso autorizado dentro del navegador ya autenticado en `chatgpt.com/images` o en la conversación de origen. Captura solo imágenes que realmente puede leer; no presupone una API pública para enumerar la biblioteca ni extrae cookies.
2. **Identidad exacta:** recuperar `commandId` (`tt-img-auto-...` / `tr-img-auto-...`), `project`, `editorialId`, `revision`, conversación y, si existen, huellas del episodio/texto. Contrastar con registros del encargo y con la ficha editorial actual. **No asociar por fecha, nombre de archivo, título o similitud visual.**
3. **Transferencia única:** enviar los bytes **en memoria** al receptor **autorizado del flujo editorial existente**, que ya sabe publicar la imagen de una ficha. No pasarlos por KV, R2 o D1 de TT Fotos. No poner claves de subida, tokens de GitHub ni secretos de los Workers en extensión, HTML o query string.
4. **Aplicación a ficha:** usar el mecanismo actual de asociación, tras revalidar revisión y SHA-256 en el receptor. Si la imagen debe seguir visible en web/app, **el sistema final existente** tiene que conservar su imagen/URL estable; no puede apuntar únicamente al `blob:` o URL privada/temporal de ChatGPT. Eso **no** equivale a crear un almacén nuevo de TT Fotos.
5. **Ambigüedad:** no tocar la ficha. Mostrar candidato y motivo para selección/confirmación manual en el monitor. Conservar únicamente metadatos de estado de la operación cuando sean necesarios; no crear archivo de fotos separado.
6. **Verificación:** leer otra vez la ficha, comprobar que la imagen correcta aparece, revisar estado de la revisión y confirmar no haber cambiado otras fichas ni el estado de la bandeja.

### Infraestructura existente a reutilizar / estudiar

- Receptor Windows de bandeja: `windows/TTImageApprovalReceiver.cjs`, `windows/TTImagesImmediateInbox.cjs`. Estos **NO** deben ser el nuevo destino automático: la bandeja iPhone no se modifica.
- Canales editoriales de imágenes: `windows/TTiTTularesWebImages.cjs` y `windows/TTendenciasImageBridge.js`, con recepción autenticada en Cloudflare y publicación/archivo editorial existente. **Verificar sus contratos de API actuales y permisos antes de reutilizarlos**; no asumir que los endpoints privados de subida pueden llamarse desde un navegador sin servidor autenticado.
- Archivos existentes de publicación: `ttittulares/generated-images/`, `trends/generated-images/` y sus correspondientes registros editoriales. No crear duplicados por captura cuando el original ya está enlazado a la ficha.
- `apps/tt-fotos/extension-templates/images-source.js` ya prueba a obtener bytes visibles de ChatGPT, pero actualmente remite a la API de almacén TT Fotos; debe adaptarse a la transferencia directa autorizada.
- La interfaz diagnóstica `docs/fotos/estado.html` puede ayudar a encontrar `LAUNCHED` sin recibo y errores; **no** equivale a imágenes recuperadas ni a confirmación de publicación.
- Nunca regenerar imagen ni alterar `/api/image-inbox/v1/images/ingest` o `/decision` solo para completar esta recuperación directa.

### Por qué NO basta con guardar un enlace de ChatGPT

Los originales de ChatGPT Imágenes pueden requerir sesión y sus URLs visibles pueden ser temporales. No está confirmado un enlace externo, estable y accesible desde las fichas publicadas. No poner `blob:`, `data:` ni direcciones privadas como URL permanente de imagen en una ficha. La imagen recuperada tiene que llegar al **destino editorial persistente que ya usa el sistema**, no a un nuevo almacenamiento inventado.

## Antes de activar el flujo

- Identificar y probar el receptor editorial real por proyecto, incluyendo formato de solicitud y la verificación de identidad/revisión, sin exponer su credencial en el navegador.
- Diseñar canal autenticado de una sola transferencia en memoria desde el navegador al receptor, aprovechando autenticación existente; en caso contrario crear solo un **adaptador de transporte** sin base propia, no un almacén.
- Probar primero una noticia y una tendencia; si falla la captura real o la asociación segura, informar el bloqueo y no declararlo operativo.
- Mantener inhabilitado el despliegue legado de `apps/tt-fotos` con D1/R2/Access. La ejecución antigua de GitHub `43098204122` quedó atascada con respuestas contradictorias a cancelación y no puede considerarse cancelada solo por cambios posteriores en `main`.

**Estado:** arquitectura corregida. No se ha realizado un piloto completo ni se han transferido fotografías nuevas en esta modificación.

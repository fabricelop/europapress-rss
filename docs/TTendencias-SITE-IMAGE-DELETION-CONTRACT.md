# TTendencias Site: eliminación completa de una imagen IA — contrato v1

## Estado y límites (31-10-2026)

- Site EXISTENTE: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/
- Project ID: `appgprj_6ae4dcf7d7488191a574e5b649e67370`.
- Catálogo que consume iOS: `trends/site-ai-images.json` en `main`.
- App iOS 0.4.34: el botón «Eliminar imagen IA» retira **solo el catálogo** y lo comunica como operación parcial. **No es una eliminación completa**.
- El conector actual ofrece `inspect_top30_images`, `attach_trend_image`, `verify_trend_image`, sin acción de borrado.
- Este PR prepara el validador de la segunda fase; **NO cambia ni publica el Site, NO borra PNGs reales y NO implementa una cuarta operación de conector**.

## Contrato de operación nueva: `remove_trend_image`

Al editar el Site original, añadir «Eliminar imagen IA», y si la configuración de su conector lo permite, exponer `remove_trend_image`. No generar imágenes nuevas ni crear otro Site.

1. Mostrar botón solo para una ficha con imagen IA, incluidas agrupaciones; resolver por ID del líder editorial (`coveredByID`), nunca por nombre, hashtag, ranking o semejanza.
2. Pedir **confirmación humana explícita** incluyendo nombre, ID, revisión y SHA256. Cancelar sin efectos.
3. Releer estado editorial justo antes de tocar nada y revalidar `project_id`, `target_id`, `revision`, texto literal de `explanation`, `explained_at`, `image_url`, `sha256`. Si existe conflicto, abortar sin borrar.
4. En el servidor del Site, eliminar **la imagen original** y **su asociación persistente a la ficha**. Verificar por lectura real que el archivo ya no existe y que la ficha ya no tiene ese enlace. Un HTTP 404 aislado del CDN no basta.
5. Emitir recibo de servidor únicamente si ambas comprobaciones son satisfactorias. No aceptar recibos autodeclarados por el navegador. Guardar recibo de servidor para reintentos idempotentes si falla la fase GitHub.
6. Releer `trends/site-ai-images.json` de GitHub **main**, usar `trends/site_image_delete_contract.py` para autorizar quitar exactamente un registro. Hacer `PUT` con SHA de blob condicional, reintentar tras 409/422 con nuevo `GET`, y volver a leer main para verificar.
7. Si GitHub falla, mostrar «Site borrado; sincronización con app pendiente», no «borrado completo». Reintentar fase GitHub sin repetir eliminación. Si Site falla, no quitar del catálogo.
8. Invalidar caché del catálogo en iOS solo cuando GitHub confirme. No tocar otras fichas, publicaciones X, ni contenido de explicación. No revelar secretos a navegador o logs.

## Entrada propuesta

```json
{
  "context": {
    "project_id": "appgprj_6ae4dcf7d7488191a574e5b649e67370",
    "target_id": "<ID_EDITORIAL_EXACTO>",
    "revision": 0,
    "name": "<NOMBRE_INFORMATIVO>",
    "scope": "editorial",
    "explanation": "<EXPLICACION_LITERAL>",
    "explained_at": "<FECHA_LITERAL>"
  },
  "sha256": "<SHA256_64_HEX>",
  "image_url": "<URL_ORIGINAL_SITE>"
}
```

El nombre sirve para la interfaz, **no identifica** la imagen. La identidad fuerte es ID+revisión+texto+fecha+URL+SHA256.

## Recibo que debe emitir el servidor de Sites

```json
{
  "status": "deleted",
  "project_id": "appgprj_6ae4dcf7d7488191a574e5b649e67370",
  "target_id": "<ID_EDITORIAL_EXACTO>",
  "revision": 0,
  "sha256": "<SHA256_64_HEX>",
  "image_url": "<URL_ORIGINAL_SITE>",
  "storage_missing": true,
  "editorial_link_missing": true
}
```

Un recibo parcial, `pending`, `conflict`, `failed`, o sin ambas verificaciones **no autoriza** quitar la referencia de GitHub.

## Componente que sí incorpora este PR

`trends/site_image_delete_contract.py`: función pura `reconcile_after_site_deletion(manifest, request, site_receipt)`. Valida formato de proyecto y esquema, unicidad de ID/revisión, explicación+fecha, SHA/URL exactas, origen HTTPS del Site y recibo de borrado verificado. Devuelve un nuevo documento sin la ficha exacta. **No llama al Site, no guarda en GitHub ni publica.** El integrador del Site debe encargarse de autenticación, almacenamiento, recepción y transacción GitHub con SHA condicional.

Pruebas: `python -m unittest discover -s tests -p 'test_site_image_delete_contract.py' -v`.

## Falta integrar para producción

- Abrir el Site en modo **editable** desde ChatGPT Sites (enlace solo no adjunta automáticamente su proyecto al chat).
- Implementar en el almacenamiento real de Sites el borrado y verificaciones; conectar la operación del Site/conector a este contrato. No inventar endpoints de Sites.
- Sustituir el borrado parcial actual de iOS 0.4.34 por una solicitud Site-first y reconciliación, con estado de error/pendiente.
- Validar una eliminación completa en imagen de prueba **elegida y confirmada**, antes de publicar el flujo definitivo. No destruir imágenes actuales para pruebas sin confirmación.

## Instrucciones ya preparadas para el chat editable del mismo Site

> Modifica exclusivamente este Site original TTendencias (`appgprj_6ae4dcf7d7488191a574e5b649e67370`). Consulta `docs/TTendencias-SITE-IMAGE-DELETION-CONTRACT.md` del repo `fabricelop/europapress-rss`. Añade botón «Eliminar imagen IA» con confirmación explícita y revalidación estricta de identidad editorial, revisión, texto, fecha, SHA y URL. Borra primero el PNG **real** y el vínculo de su ficha, verifica ambos por lectura del almacenamiento y emite el recibo descrito. Solo tras ello retira la entrada exacta de `trends/site-ai-images.json` en GitHub main mediante lectura, SHA condicional y verificación posterior. Si alguna fase falla, presenta «pendiente» o «parcial», nunca «completado». Conserva Site, URL, explicaciones, diseño compacto y botones existentes. No generes nuevas imágenes ni publiques sin revisar la vista previa. Si el editor no puede exponer `remove_trend_image` como herramienta de conector, implementa el botón con la API autenticada propia del Site y declara esa limitación.

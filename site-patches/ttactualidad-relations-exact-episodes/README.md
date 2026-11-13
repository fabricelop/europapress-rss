# Cracovia: reparación de la validación de relaciones por episodio exacto

**Fecha:** 8 de noviembre de 2026. **Estado:** código auxiliar + pruebas de contrato
en GitHub, **NO instalado** en el backend privado del Site ChatGPT. No es un
segundo almacén de relaciones, ni un endpoint nuevo ni un cambio de producción.

## Reproducción real

En la aplicación iOS, pulsar «Relaciones» de **Cracovia**, seleccionar dos de
las cinco noticias encontradas y pulsar Guardar produjo: **1/2 confirmadas**.
La primera fue rechazada con **HTTP 400**, la segunda sí recibió confirmación.

La primera candidata existe en `main` de
`telegram/editorial-processing.json`, con estos campos verificados:

- `event_id=e1f64f5801b7`, `revision=1`, `status=READY`.
- Título comienza por «El perfil Un polaco de 24 años y con ideas de extrema
  derecha: así es el autor del ataque en Cracovia».
- La noticia tiene identidad editorial en GitHub, aunque podría no estar en
  `GET /api/editorial-relations/v1/snapshot` del Site. **No se ha podido leer el
  snapshot privado autenticado ni su log de rechazo**, por lo que la causa
  concreta del HTTP 400 aún requiere comprobación con backend.

## Cambio requerido en el servicio Site existente

En `POST /api/editorial-relations/v1/decisions` (Site auténtico, no este
repositorio), cuando el editor autenticado envía:
```json
{
  "action": "link",
  "expectedNews": {"id": "e1f64f5801b7", "revision": 1},
  "expectedTrend": {
    "id": "<ID EDITORIAL DE CRACOVIA>",
    "revision": 0
  },
  "commandId": "<UUID ESTABLE POR REINTENTO>"
}
```
el servicio debe resolver **ambas identidades** en su catálogo histórico de
episodios reales, ampliándolo mediante datos server-side desde las fuentes
oficiales GitHub (`telegram/editorial-processing.json`,
`ttittulares/prepared.json`, `ttittulares/status.json`, relaciones
persistidas y catálogo de tendencias histórico). Aceptar episodio exacto por
`(project,id,revision)` sin exigir que el iPhone invente una huella.
Si se proporciona `episodeFingerprint` real, verificarlo; la discrepancia,
revisión realmente obsoleta o ID inexistente debe dar **409**, nunca generar
una vinculación por título, nombre o posición. La caducidad en Listas y el
estado editorial no son filtros para la relación manual.

`resolve-exact-episodes.cjs` aporta un **resolver auxiliar puro** y
`resolve-exact-episodes.test.cjs` comprueba específicamente el episodio
`e1f64f5801b7:r1` y otras regresiones. Para integración real:

1. Incorporar la resolución al handler privado del Site y abastecer los
   índices mediante lecturas auténticas del lado servidor. **Nunca** confiar
   en catálogos enviados por cliente.
2. Mantener la autorización GitHub del editor, anti-CSRF/SSRF y commandId
   idempotente. Ejecutar el mismo almacenamiento de relaciones ya instalado
   y su recibo `{state:"linked", relationId:"..."}` (o el de desvinculación).
   NO usar GitHub como segundo ledger ni publicar tweets al asociar.
3. Ampliar `GET /v1/snapshot` para incluir episodios históricos consultables,
   con las asociaciones ya confirmadas, aunque no estén en Listas ni Top30.
4. Confirmar sobre datos privados reales que el primer `link` de Cracovia
   devuelve 200 y recibo, que la segunda relación sigue intacta, que al
   refrescar y reabrir se recuperan **2/2**, y que `unlink` sigue funcionando.
   Probar también 401/403 (auth), 409 (revision/fingerprint), reintento mismo
   commandId, y rechazo de ID desconocido. No recrear ni publicar noticias.
5. Mantener intactos Buffer, X, Site público, imágenes privadas, aprobación,
   Windows, listas, tendencias, deduplicación y Live Activity.

**No confundir la compilación de pruebas en GitHub con la reparación real
del servidor Site:** el backend privado vive fuera del repo y necesita un
despliegue nativo propio antes de declarar que las dos relaciones funcionan.

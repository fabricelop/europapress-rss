# Cracovia: reparación de la validación de relaciones por episodio exacto

**Fecha:** 8 de noviembre de 2026. **Estado:** restauración sobre el `main` autoritativo actual, código auxiliar + pruebas de contrato
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

## Adaptador probado para el snapshot real de Sites

El resolver `buildTrustedRelationIndexes({processing,prepared,status,treated,siteTop30,explained,snapshot})`
acepta los catálogos de servidor, los `news[]` y `trends[]` de la respuesta
privada y los vínculos persistidos `snapshot.items[].news/.trend`.
**Conserva las huellas auténticas ya emitidas** y no infiere ninguna desde
títulos, posiciones o fechas. Las nuevas pruebas cubren específicamente
las dos selecciones de Cracovia, el formato `id/canonical_title`, las
relaciones previamente guardadas y el rechazo de huellas manipuladas.

Este módulo permanece sin efectos laterales: el backend privado existente
debe obtener los catálogos directamente, autenticar al editor, llamar al
resolver y persistir únicamente mediante su ledger y recibos actuales.
No hay mecanismo autorizado de despliegue del proyecto ChatGPT Site desde el
repositorio GitHub. No declarar el error 400 resuelto sin leer recibo 200 y
verificar el par de relaciones reabriendo la APP.

### Estado del código y de la integración
- El código está preparado para quedar disponible en el `main` vigente tras
  superar CI; es una pieza para integrar en el Site, **no** el endpoint Site.
- Si el código desaparece por divergencia de ramas, verificar `main` antes de
  declarar la entrega; una PR marcada «merged» no certifica por sí sola que
  el archivo sigue visible en el árbol actual.

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


## 09/11/2026 — Julián: 2/2 rechazados HTTP 400 (READY y WAITING)

**Evidencia del editor:** en la app, «Relaciones → Julián», las dos noticias
coincidentes se seleccionan correctamente, pero Guardar devuelve 0/2 con
HTTP 400 en ambas. No es un fallo del buscador ni una ausencia de las
noticias. IDs y revisiones comprobados contra GitHub main:

| Noticia | Fuente autoritativa | Identidad | Estado |
|---|---|---|---|
| Enrique Cerezo: «El mejor perdón de Julián Álvarez no es un gol, sino dos» | telegram/editorial-processing.json | 9ed95352b91b:r1 | READY |
| El mensaje cariñoso de Simeone a Julián: «Lo necesitamos» | ttittulares/status.json → events | 9593c2b869f1:r1 | WAITING |
| Tendencia Julián | trends/site-top30-current.json | trend-update-08da896cbbe389cf5192:r0 | EXPLICADA |

**Contrato funcional:** toda noticia visible recuperada de un catálogo
editorial fiable, con ID y revisión reales, debe poder vincularse manualmente,
independientemente de READY, WAITING, publicación, antigüedad, Listas o foto.
La identidad se valida por ID/revisión en el servidor, sin exigir que
existiera previamente en snapshot.news ni que el iPhone conozca una
huella. Si se proporciona fingerprint, el servidor verifica que coincide;
si falta, los identificadores exactos son suficientes. Nunca desactivar
la autenticación, aceptar IDs inventados ni crear asociaciones por nombre.

**Integración requerida en el servicio privado del Site:**

1. En POST /api/editorial-relations/v1/decisions, después de autenticar
   al editor y antes de la escritura existente, obtener los catálogos
   oficiales en el propio servidor y ejecutar
   resolveManualDecision(decision, trustedCatalogs).
   Los catálogos autorizados incluyen processing, prepared, status, treated,
   publicationEvents, siteTop30, explained y el snapshot persistido. No aplicar
   filtros editoriales de READY, WAITING, Listas o fecha. Continuar la
   persistencia que ya funciona con las otras relaciones y la idempotencia
   del commandId, sin instalar otra base.
2. En GET /api/editorial-relations/v1/snapshot, ampliar las listas de episodios
   con exposeLinkableEpisodes(existingSnapshot, buildTrustedRelationIndexes(
   trustedCatalogs)). Esta función añade noticias/tendencias elegibles a
   news[] y trends[] sin inventar enlaces en items[]; una huella opcional
   inexistente se serializa como cadena vacía, y cualquier huella auténtica
   previa se conserva.
3. La web debe presentar los vínculos manuales de snapshot.items en la misma
   vista «Noticias relacionadas» que ya muestra relaciones de Nadal o Mestalla,
   con tarjetas existentes, sin otro sistema de datos ni pantalla adicional.
   Coincidencia textual no equivale a vínculo persistido.
4. Prueba autorizada: enviar link para Cerezo y Simeone → dos recibos 200
   con state=linked y relationId válidos → GET devuelve ambos pares → al
   recargar web y reabrir iPhone persisten 2/2. Desvincular uno no altera
   el otro; probar reintentos idempotentes, revisión errónea (409) y
   acceso no autorizado (401/403).

Las pruebas resolve-exact-episodes.test.cjs reproducen ambos IDs reales,
incluido WAITING, exponen los endpoints en el snapshot y conservan dos
asociaciones distintas. **Esta corrección está en GitHub, no desplegada en
ChatGPT Sites.** Las herramientas disponibles no pueden modificar el backend
privado del Site: el HTTP 400 solo se dará por resuelto tras integrar
el adaptador en el servicio real y confirmar los dos recibos.
La PR #365 contiene arreglos de la APP iOS, que por sí solos no eliminan
un rechazo HTTP 400 del servidor.

# TT Fotos — Recuperación local y monitor de imágenes

**Estado 11/11/2026:** código añadido a `main`; pruebas automáticas **10/10 superadas localmente con Node v22.16.0 en un entorno de ensayo**, no Windows del usuario. La ejecución de CI de GitHub Actions no está confirmada. Ningún original de producción se ha enviado desde esta conversación.

## Qué resuelve

El principal problema es que ImageGen puede generar más imágenes de las que llegan a la bandeja privada de TTActualidad iPhone. Esta herramienta inventaría todas las inscripciones que conoce el PC, los PNG existentes en `image-approval-receipts/immediate-originals` y `original-cache`, los recibos privados ya confirmados y los PNG sin asociación. En el panel local muestra también **miniaturas de imágenes huérfanas** sin asociarlas por parecido.

Funciones:
- `--scan`: solo lectura. Muestra estado por `commandId`, proyecto, ID, revisión, origen y motivo del receptor. No equivale a una lectura actual del backend privado.
- `--serve`: panel de monitor privado en `http://127.0.0.1:8765/`, con previsualización de originales verificados y huérfanos locales. Solo GET y sin carga de secretos.
- `--capture`: **lee** conversaciones ChatGPT ya abiertas mediante CDP de Windows (puertos 9223/9234). Solo conserva PNG cuando `rasterProbe(commandId,true)` acredita el comando exacto. No abre ni navega pestañas, no escribe prompts, no regenera.
- `--deliver`: usa el mismo `TTImageApprovalReceiver.send` y secreto DPAPI **por encargo**, verifica el job, proyecto, revisión, episodio, texto editorial y SHA del raster; reintenta entrega idempotente sin borrar el original. **No necesita cerrar el receptor periódico**: duplicados del mismo candidato son aceptables; no permite que otro PNG distinto sustituya una ficha arbitrariamente.
- `--rescue`: ejecuta `--capture` y después `--deliver`, con límite por pasada.
- `--import-dir "C:\\ruta\\a\\PNG"`: inventaría **PNG descargados manualmente** de ChatGPT Images. Cuando el nombre contiene un `command_id` conocido, solo lo marca como candidato para revisión; **NO lo asocia ni sube automáticamente** por el nombre o aspecto.

## Instalar desde ZIP local, sin GitHub durante la ejecución

1. Descargar el ZIP `TTFotos_Rescate_Local_20261111.zip` de la conversación, descomprimirlo en una carpeta nueva y conservar los cuatro archivos juntos.
2. Abrir PowerShell en esa carpeta y ejecutar:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Instalar-TTFotos-Local.ps1 -Serve
```

El instalador valida Node, ejecuta **10 pruebas locales**, guarda copias de cualquier archivo homónimo antes de instalar en `C:\TTiTTulares`, hace la auditoría de solo lectura y muestra el panel en `http://127.0.0.1:8765/`. Mantener PowerShell abierto mientras se utiliza el panel. No reinicia Chrome ni listeners y no reenvía imágenes por defecto.

3. Tras revisar los faltantes y sus identidades, la recuperación explícita:

```powershell
node C:\TTiTTulares\TTFotosRescate.cjs --rescue --limit 8 --base C:\TTiTTulares
```

Este comando intenta capturar solo originales exactos en conversaciones abiertas y reenviar originales con inscripción local válida al mismo inbox privado. Los fallos individuales se registran por `commandId`; conserva los PNG.

Para visualizar imágenes descargadas de ChatGPT Images en el mismo panel:

```powershell
node C:\TTiTTulares\TTFotosRescate.cjs --serve --base C:\TTiTTulares --import-dir "C:\Users\TU_USUARIO\Downloads\Imagenes"
```

**No automatizar rescates amplios sobre Chrome sin revisar antes el número de pestañas y la salud de CDP**. El usuario ha tenido muchas pestañas ChatGPT simultáneas y límites de memoria.

### Opción de instalador desde GitHub

`windows/Instalar-TTFotos-Rescate.ps1`, con descargas fijadas al commit `9f24ebe32319a2ef3bff68c1587a2ad9b2bcf563`. Por defecto audita sin enviar; `-Recover` realiza el rescate y `-Serve` abre el panel.

## Fuente de verdad y limitaciones estrictas

- El Site Next.js real `https://ttactualidad.rainyraven22.chatgpt.site` contiene `GET /api/image-inbox/v1/images`, `GET /.../{id}/original` y `POST /.../{id}/decision`; el receptor envía a `POST /api/image-inbox/v1/images/ingest` con el secreto de cada encargo.
- **La biblioteca ChatGPT Images completa no tiene una API de listado/exportación masiva confirmada** para esta herramienta. Los originales de conversaciones cerradas/no inscritas que no estén descargados no aparecen automáticamente.
- **Recibo local** = prueba de una entrega anterior, no garantía de que la tarjeta siga pendiente de aprobación ahora.
- Un `LAUNCHED` es prompt enviado, nunca prueba de raster generado.
- La interfaz privada real de aprobar/rechazar desde la web del Site **todavía no está desplegada**; el panel local es de lectura. No hay aprobación ni publicación X/Instagram automática.
- Una última entrega de PNG distinto **NO tiene** semántica de reemplazo confirmada en el backend. Solo se reintenta el mismo original por identidad exacta.
- Los PNG huérfanos sin metadatos suficientes permanecen visibles y no se vinculan por título/fecha/parecido automáticamente. La asociación manual será una segunda fase con autenticación y verificación.

## Código, tests y seguridad

- `windows/TTFotosRescate.cjs`
- `windows/TTFotosRescatePanel.html`
- `windows/TTFotosRescate.test.cjs` — 10 tests de inventario, no envío de huérfanos, colisiones de inscripciones, recibos, concurrencia con receptor, panel local y cabeceras seguras, previsualización de huérfanos y dos PNG distintos en un comando
- `.github/workflows/tt-fotos-rescate-tests.yml`

Si se pierde el inventario de inscripciones o el secreto DPAPI original, no inventar identidad, nueva revisión, SHA o credenciales. Documentar `ORIGINAL_HUERFANO_VERIFICADO` / `ORIGINAL_SIN_METADATOS_VERIFICABLES` y recuperarlo a la vista del editor. No modificar archivos de producción de los listeners ni reiniciar Chrome como parte del rescate.

**Próxima prueba física imprescindible:** ejecutar `--scan` en Windows; comprobar el número real de PNG conservados sin recibo; ejecutar `--rescue` de forma controlada; confirmar recepción mediante bandeja APP y respuesta Site (no solo JSON local); repetir con un titular y una tendencia. Después ampliar a exportación/sync de ChatGPT Images para casos sin inscripción.


## Versión V2 — 11 noviembre 2026 (filtro 10/11 y asociación manual)

**Código confirmado en GitHub:** \`windows/TTFotosRescate.cjs\`, \`windows/TTFotosRescatePanel.html\`, \`windows/TTFotosRescate.test.cjs\` y el instalador offline \`windows/Instalar-TTFotos-Local.ps1\`. En el entorno de ensayo Linux con Node 22 se ejecutaron **16/16 pruebas** de los caminos seguros; **sin ejecución real en Windows ni verificación directa de la bandeja iPhone**.

**Importante:** la captura original solo cubre inscripciones locales, PNG cacheados y conversaciones ChatGPT abiertas. La biblioteca completa de ChatGPT Imágenes no tiene API de inventario usada por este módulo. Por tanto 0 huérfanas en el PC no implica 0 imágenes sin entregar en ChatGPT.

### Uso recomendado desde el 10/11/2026

1. Detener el monitor anterior (PowerShell que escucha en el puerto 8765, \`Ctrl+C\`); NO reiniciar Chrome.
2. Descargar y descomprimir el ZIP V2 de la conversación. Desde la carpeta extraída:
   \`\`\`powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Instalar-TTFotos-Local.ps1 -Serve
   \`\`\`
   Crea \`C:\TTiTTulares\TTFotos-Importar\`, audita desde el día 10, conserva los scripts anteriores en .bak y abre \`http://127.0.0.1:8765/\`.
3. En **«Desde»** elegir 10/11/2026, o modificar el calendario. Los contadores son **solo los trabajos desde ese día**; \`Todo el histórico\` restaura el inventario completo.
4. Si aparece un PNG exacto sin entregar, probar en **otra PowerShell**:
   \`\`\`powershell
   node C:\TTiTTulares\TTFotosRescate.cjs --deliver --since 2026-11-10 --limit 15 --base C:\TTiTTulares
   \`\`\`
5. Para buscar imágenes dentro de conversaciones **ya abiertas** (sin generar):
   \`\`\`powershell
   node C:\TTiTTulares\TTFotosRescate.cjs --rescue --since 2026-11-10 --limit 8 --base C:\TTiTTulares
   \`\`\`
   El recuperador alterna los lotes mediante \`image-approval-receipts/tt-fotos-capture-cursor.json\` para no repetir eternamente los primeros ocho. \`--offset N\` permite una posición concreta. Un resultado \`NO_EXACT_ORIGINAL_VISIBLE\` no demuestra inexistencia de la imagen.
6. Para **imágenes descargadas de ChatGPT Imágenes**, guarda el PNG en \`C:\TTiTTulares\TTFotos-Importar\`, pulsa Actualizar. Abajo aparece la miniatura; busca una noticia o tendencia, selecciona el ID/revisión, comprueba personalmente la correspondencia y pulsa **«Confirmar asociación»**. El sistema copia el original por SHA-256 a \`image-approval-receipts/manual-originals\` y registra una atribución editorial en \`tt-fotos-manual-links.json\`; no falsifica un recibo ni afirma haber verificado el origen de ImageGen.
7. Busca arriba la ficha **«Asociada manualmente»** y pulsa **«Entregar PNG a bandeja»**. Se ejecuta una validación nueva de la identidad del encargo, su revisión y el episodio editorial contra GitHub, con el mismo endpoint de ingestión del inbox privado. Si el backend confirma la recepción y el recibo local se persiste, el estado pasa a recibido. El monitor **no** aprueba ni publica imágenes.

La reasignación desde un PNG descargado es explícitamente **atribución humana**. Si el encargo ya tiene recibo o perdió la credencial DPAPI, no se sobrescribe otra imagen: queda pendiente una operación autenticada separada del Site. Aún no está demostrada una semántica «última imagen distinta reemplaza a la anterior».

La API del monitor local incluye \`GET /api/status?since=YYYY-MM-DD\`, \`POST /api/associate\` y \`POST /api/deliver-manual\` con confirmación y comprobaciones de origen del mismo servidor. **No expone secretos ni imágenes a GitHub** y no acepta asociaciones por apariencia.


## V3 · 11/11/2026 · solo monitor, bandeja iPhone intacta

**La instrucción editorial más reciente sustituye la anterior:** cuando una foto se rescata y se vincula a la noticia o tendencia dentro del monitor, **NO se envía al inbox del iPhone**. El monitor solo guarda una copia PNG por SHA-256 en \`image-approval-receipts/manual-originals\` y la atribución local en \`image-approval-receipts/tt-fotos-manual-links.json\`.

- UI: desaparece el botón «Entregar PNG a bandeja». La ruta \`POST /api/deliver-manual\` devuelve 405. \`--deliver\` y cualquier llamada exportada de entrega manual fallan con \`INBOX_DELIVERY_DISABLED_FOR_MONITOR\`.
- \`--rescue\` **solo** intenta capturar PNG originales identificados en conversaciones de ChatGPT ya abiertas, sin enviarlos al Site/app.
- Una foto puede asociarse visualmente incluso a una ficha que tenga recibo antiguo u original previo. **La última asociación confirmada sustituye a la anterior en esa ficha local** y se conserva un historial en el mismo JSON (\`history[]\`). Esto NO modifica ni revoca la entrega histórica del iPhone, ni modifica las colas editoriales, ni publica.
- Se ve una nueva fase \`ASOCIADA_EN_MONITOR\` con miniatura de la imagen escogida y un contador \`manualAssociated\`.
- Solución de \`listen EADDRINUSE 127.0.0.1:8765\`: si el puerto predeterminado está ocupado, el servidor intenta 8766, 8767, etc. sin terminar procesos. Abrir la URL que aparece tras \`TT_FOTOS_PANEL\`, no dar por hecho que se usa 8765.
- El filtro de fecha desde 10/11/2026 se conserva. \`image-approval-receipts/tt-fotos-capture-cursor.json\` rota encargos entre las pasadas.
- Instalador offline: \`windows/Instalar-TTFotos-Local.ps1 -Serve\`; ZIP de esta conversación \`TTFotos_Monitor_Local_V3_sin_tocar_iPhone.zip\`. No usar los ZIP anteriores V1/V2 para esta política.
- **Pruebas reales en entorno de ensayo con Node 22 (no Windows del usuario): 18/18 superadas**, incluyendo recuperación de datos, reemplazo visual, conservación de imágenes, ausencia de rutas de entrega y apertura de puerto alternativo. No afirmar ninguna recuperación en el Windows del usuario ni una prueba física con su iPhone.
- La colección completa ChatGPT Imágenes aún debe exportarse/descargarse para asociar PNG no inscrito localmente. No existe enumeración masiva automática confirmada en este módulo.

**Instalación orientativa:**
\`\`\`powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Instalar-TTFotos-Local.ps1 -Serve
\`\`\`
Si ya hay un monitor abierto en 8765, abrir el puerto alternativo comunicado por Node o cerrar la ventana anterior mediante Ctrl+C. No cerrar ni reiniciar Chrome, ni detener los listeners de noticias/tendencias.

Los pasos anteriores sobre «Entregar PNG a bandeja», \`--deliver\` o \`--rescue\` con reenvío **son históricos de V2 y no se aplican a V3**.

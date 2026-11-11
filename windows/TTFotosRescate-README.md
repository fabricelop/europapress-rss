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

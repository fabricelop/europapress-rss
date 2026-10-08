# TTendencias — fase 1 sin Vercel (PR en borrador)

**Estado:** no desplegado. `main`, Vercel, la app TTendencias productiva, FabCalendar y SeLoRecordamos **no se modifican**.

## Qué funciona en esta fase

- Interfaz móvil de contingencia: `../ttendencias/index.html`, muestra Top 10 y próximas tendencias desde `trends/recent.json`, y el diagnóstico desde `trends/health-status.json`. Cachea una copia en el navegador y advierte cuando está anticuada.
- Worker Cloudflare opcional en `src/index.js`, con assets estáticos y `GET /api/ttendencias-control?view=state` (contrato base del panel), leyendo los siete JSON del repositorio con caché de 60 segundos sobre origen GitHub.
- Endpoint `GET /health`, para comprobación de infraestructura.
- **Nunca fabrica colas vacías**: los errores de lectura y JSON inválido dan HTTP 503.
- No se necesitan secretos para **esta prueba de solo lectura**.

## Qué no funciona aún (no sustituir producción)

- Operaciones POST del panel (preparar, descartar, publicar, reelaborar, copiar, valorar), solicitudes móviles, estados RUN y sus ACK.
- Imágenes IA (generación, petición, transferencia, regeneración).
- Telegram ni escritor de GitHub ni integración del listener Windows.
- El snapshot GET es el **contrato estructural básico**, no incluye todas las anotaciones, ratings, reconciliaciones ni recuperación de estado del controlador actual de Vercel. NO sirve todavía para apuntar el panel original sin pruebas de paridad.

## Comprobar y ejecutar SOLO en entorno de prueba

En `no-vercel/ttendencias-worker`:

```sh
npm ci
npm test
npx wrangler dev
```

La primera vez (sin lockfile), utilizar `npm install` en lugar de `npm ci`; no se ejecutará automáticamente ningún despliegue. Accede a `http://localhost:8787/`, `/health` y `/api/ttendencias-control?view=state`.

Para desplegar una vez validado, el propietario debe conectarse a su cuenta de Cloudflare y autorizarlo expresamente. No se han copiado credenciales ni tokens y no hay desplegado ningún Worker nuevo. Conserva el Worker FabCalendar completamente separado.

## Prioridades y migración posterior

1. Validar lecturas completas y compatibilidad del modelo visual (especialmente la cola `requests.json`, los ítems elaborados y su historial).
2. Añadir escritor GitHub autenticado con secretos de Cloudflare; preservar las operaciones existentes con consistencia de revisiones, protección contra duplicados, idempotencia y cuotas, sin insertar un token en el navegador.
3. Implementar orden remoto, estado, ACK, cola e imágenes IA, manteniendo el PC como ejecutor y el Worker activo si está apagado.
4. Montar la app original en una URL de pruebas, medir llamadas/CPU, hacer pruebas completas desde iPhone y realizar un cutover reversible.
5. Solo después, retirar las invocaciones TTendencias a Vercel. Favorecer que FabCalendar se quede donde funciona.

La cuota Vercel Hobby agotada no se recupera en el ciclo actual por desactivar un proyecto. La ganancia aparecerá en el siguiente ciclo. Una suspensión de todo el equipo podría bloquear cualquier ruta Vercel restante, incluso de FabCalendar si alguien sigue usando su antiguo proxy.

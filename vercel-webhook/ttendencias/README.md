# TTendencias Control Web

Panel web mobile-first para controlar el Top 10 de TTendencias sin usar Telegram como panel.

## Arquitectura

- Lectura directa y sin función Vercel: `trends/recent.json`, `trends/requests.json`, `trends/telegram-manual-explained.json` y `trends/health-status.json`.
- Escritura: API `/api/ttendencias-control`.
- La API usa el `GITHUB_TOKEN` ya disponible en el proyecto Vercel.
- Los cambios de estado se escriben en GitHub con control de conflictos.
- Telegram sigue siendo únicamente el canal de entrega de los tuits preparados.
- El objetivo editorial es principal + 3 alternativas de remate. Si excepcionalmente una redacción llega con menos de 3 alternativas, el sender avisa en el log pero la envía igualmente para no perder la tendencia.
- La opción con imagen queda fuera de esta primera versión.

## Estados visuales

- Nueva
- Elaborando
- Preparada
- Actualizando
- Explicada

## Acciones

- Selección múltiple y selección rápida de los elementos visibles.
- Enviar una selección a Elaborar.
- Reabrir una tendencia preparada o explicada como actualización.
- Marcar una selección como Explicada.
- Buscar cada tendencia directamente en X.
- Solicitar un refresco inmediato del Top 10.
- La selección y los filtros se conservan localmente en el dispositivo.
- Mostrar solicitudes en curso, historial reciente y salud del sistema.

## Consumo

La interfaz vuelve a leer el estado cada 15 minutos mientras la pestaña está visible. Estas lecturas se realizan contra los JSON públicos de GitHub y no ejecutan una función Vercel ni lanzan el workflow de captura.

El Top 10 mantiene su programación normal de 15 minutos. Solo el botón explícito `Actualizar Top 10` solicita una ejecución de `ttendencias-refresh.yml`.

## Despliegue

Los autodeploys Git de Vercel están desactivados deliberadamente en `vercel.json`. Los commits de datos de TTendencias, TTiTTulares y SeLoRecordamos no deben generar builds.

Desplegar la aplicación únicamente de forma controlada cuando haya una versión que probar o publicar.

## Seguridad

- El panel lleva `noindex` y cabeceras de seguridad.
- Los nombres de tendencia se insertan en la página como texto, no como HTML.
- Las lecturas son públicas, como los JSON del repositorio.
- Toda acción de escritura requiere `TTENDENCIAS_CONTROL_TOKEN`.
- El token se guarda únicamente en el almacenamiento local del dispositivo.
- El panel permite probar la credencial antes de guardarla.
- No debe almacenarse ningún token en el repositorio.

## Puesta en producción

1. Crear en Vercel la variable de entorno secreta `TTENDENCIAS_CONTROL_TOKEN` para Production.
2. Realizar un único deployment controlado de `europapress-rss`.
3. Abrir `/ttendencias/` en escritorio y móvil.
4. Introducir el token desde el botón de ajustes y usar `Probar acceso`.
5. Verificar primero solo lectura, selección y filtros.
6. Hacer una prueba real con una única tendencia nueva y comprobar que entra en `trends/requests.json`.
7. Confirmar que la redacción llega a Telegram y que el estado pasa a `ready`.
8. Solo después de validar la web, retirar el panel/listener continuo de Telegram para reducir consumo de GitHub Actions.

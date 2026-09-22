# TTendencias Control Web

Panel web mobile-first para controlar el Top 10 de TTendencias sin usar Telegram como panel.

## Arquitectura

- Lectura: `trends/recent.json`, `trends/requests.json` y `trends/telegram-manual-explained.json`.
- Escritura: API `/api/ttendencias-control`.
- La API usa el mismo `GITHUB_TOKEN` ya disponible en el proyecto Vercel.
- Los cambios de estado se escriben en GitHub con control de conflictos.
- Telegram sigue siendo el canal de entrega de los tuits preparados.
- La opción con imagen queda fuera de esta primera versión.

## Estados visuales

- Nueva
- Elaborando
- Preparada
- Actualizando
- Explicada

## Acciones

- Selección múltiple.
- Enviar selección a Elaborar.
- Marcar selección como Explicada.
- Solicitar refresco inmediato del Top 10.
- La selección se conserva localmente en el dispositivo.

## Consumo

La interfaz refresca solo la lectura cada 5 minutos mientras la pestaña está visible. Eso no lanza el workflow de captura; el Top 10 continúa actualizándose por su programación normal de 15 minutos. El botón de refresco manual sí solicita una ejecución de `ttendencias-refresh.yml`.

## Despliegue

Los autodeploys Git de Vercel están desactivados deliberadamente en `vercel.json`. Los commits de datos de TTendencias/TTiTTulares/SeLoRecordamos no deben generar builds. Desplegar la aplicación solo de forma controlada cuando sea necesario.

## Seguridad

Las lecturas son públicas, igual que los JSON del repositorio. Las acciones requieren un token de control. Puede sustituirse en producción definiendo `TTENDENCIAS_CONTROL_TOKEN`.

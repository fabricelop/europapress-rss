# RainETA — widget iPhone SIN Vercel y SIN Mac

La app gratuita [Scriptable](https://apps.apple.com/app/scriptable/id1405459188) permite mostrar un widget iOS real desde JavaScript. Este widget consulta Open-Meteo **directamente desde el iPhone**; no usa el dominio Vercel, despliegues, ni la API personalizada de RainETA.

## Instalación
1. Instalar Scriptable y crear script `RainETA Lluvia`.
2. Copiar completo `RainETA-Lluvia.js` al script. Si ya estaba instalado, **reemplazar el código antiguo** para activar búsqueda por nombre de ciudad y eliminar Vercel.
3. Ejecutar una vez en Scriptable para permitir localización (si se usará GPS).
4. Mantener pulsada la pantalla de inicio → Añadir widget → Scriptable pequeño → Editar widget → seleccionar script `RainETA Lluvia`.

## Cambiar ubicación en el propio widget
Mantener pulsado widget → **Editar widget** → campo **Parameter**.

- Vacío: ubicación GPS actual; Scriptable solicitará permiso.
- `Madrid`: la ciudad de Madrid.
- `Sevilla, España`: desambigua ciudades con el país o provincia.
- `40.4168,-3.7038|Madrid`: coordenadas explícitas y etiqueta a mostrar.

Al aceptar el cambio, iOS debe ejecutar otra vez el script según su política. La ciudad elegida aparece en el widget. Se cachean coordenadas de las ciudades consultadas para reducir llamadas al geocodificador de Open-Meteo.

## Limitaciones
Open-Meteo permite consulta de campos a 15 minutos que en buena parte de Iberia son **interpolaciones de modelos horarios**, así que el resultado muestra margen ±30 min. No equivale a radar de movimiento RainETA, que requiere procesamiento adicional todavía no incorporado en esta versión directa. El reloj visible puede avanzar en iOS aunque las actualizaciones de datos dependen de WidgetKit. Esto no sustituye avisos oficiales de AEMET.

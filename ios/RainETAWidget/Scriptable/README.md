# RainETA Widget para iPhone (Scriptable, sin Vercel)

El widget consulta **directamente Open-Meteo desde el iPhone**. No utiliza Vercel ni la app de RainETA como servidor. La vista es una previsión basada en modelos meteorológicos, **no una lectura de pluviómetro ni un radar local observado**.

## Instalar o actualizar

1. Instala Scriptable en el iPhone si todavía no lo tienes.
2. Abre el [script actualizado RainETA-Lluvia.js](RainETA-Lluvia.js). Copia **todo el código** y sustituye el contenido del script «RainETA Lluvia» en Scriptable; no basta con dejar el antiguo script instalado.
3. Ejecuta el script una vez en Scriptable. Muestra una previsualización **mediana**, con las 12 barras.
4. Para ver el gráfico en la pantalla de inicio, añade un widget de **Scriptable de tamaño mediano o grande**. El pequeño sigue mostrando la cuenta atrás, pero no cabe el gráfico de 12 horas con sus valores.
5. Mantén pulsado el widget → Editar widget → en **Script** elige RainETA Lluvia y en **When Interacting** puedes elegir «Run Script». Cierra el editor.

## Elegir ubicación

Mantén pulsado el widget → Editar widget → **Parameter**:

- Vacío: ubicación GPS actual.
- \`Madrid\`, \`Valencia\`, \`Sevilla, España\`: búsqueda geográfica directa.
- \`40.4168,-3.7038|Madrid\`: latitud,longitud y etiqueta.

## Barras de las próximas 12 horas

Cada barra indica un tramo de **una hora** y tres datos:

- Arriba: **probabilidad de precipitación (%)** según Open-Meteo.
- Altura y color: **lluvia líquida prevista** en milímetros acumulados durante la hora (equivalente a intensidad media **mm/h**). Umbrales: seco menos de 0,1; débil menos de 0,5; moderada menos de 2,5; fuerte menos de 7,5; muy fuerte a partir de 7,5 mm/h.
- Debajo: milímetros (con un decimal) y **hora local de inicio del intervalo**. La documentación de Open-Meteo refiere las cantidades horarias al período anterior a la marca temporal del dato: una marca 16:00 corresponde a lluvia de 15:00–16:00.

Las probabilidades y cantidades son métricas distintas y **no deben multiplicarse** para interpretar cada barra. Un valor ausente se muestra con raya, no como 0.

La cuenta atrás usa la señal de Open-Meteo de 15 minutos en los lugares donde está disponible; en buena parte de España está interpolada de un modelo horario, por lo que se marca ±30 minutos. Los modelos horarios pueden diferir del tiempo observado.

## Actualizaciones

El script solicita nuevos datos al ejecutarse y solicita a iOS la siguiente actualización a partir de 10 minutos, pero **Apple decide cuándo actualizar los widgets**: no hay garantía de que se vuelvan a consultar cada 10 minutos. En pantalla se muestra «Actualizado HH:MM».

Si la red falla, puede usar durante hasta una hora los últimos datos guardados **para la misma ubicación**, mostrando «Guardado HH:MM». Si la copia supera 30 minutos, no se muestra una cuenta atrás que pueda inducir a error.

Para forzar una consulta y revisar la gráfica en el momento, abre el script dentro de Scriptable y ejecútalo. La pantalla de inicio puede tardar más en refrescarse. Si necesitas observaciones de radar y múltiples fuentes de nowcasting, hará falta un motor adicional; esta versión funciona sin servidor.

### Verificaciones

Comprobadas en entorno simulado 7 condiciones: 12 barras en mediano y grande, pequeño sin gráfico ilegible, porcentajes, cantidades, consulta directa a Open-Meteo sin Vercel y recuperación de datos guardados. **Pendiente prueba visual en iPhone real.**

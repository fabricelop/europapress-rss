# RainETA: lluvia observada AHORA (beta Scriptable, sin Vercel)

## Por qué dos widgets pueden discrepar
`RainETA Lluvia` usa el modelo agregado Open-Meteo y `RainETA Consenso` calcula un consenso de modelos/ensembles. La salida `Termina en` de un modelo **no demuestra** que esté lloviendo en el punto. Son predicciones, con criterios distintos.

## Nuevas variantes independientes
- [RainETA-Lluvia-Radar.js](RainETA-Lluvia-Radar.js): modelo Open-Meteo, 12 barras y estado de radar observado.
- [RainETA-Consenso-Radar.js](RainETA-Consenso-Radar.js): consenso original de RainETA, 12 barras y estado de radar observado.

**No sobrescribir los scripts instalados hasta validar**: crear uno nuevo en Scriptable y pegar uno de estos archivos. Elegir en el widget mediano o grande. El parámetro sigue siendo ciudad o coordenadas `lat,lon|etiqueta`.

Los scripts consultan directamente la API de [RainViewer](https://www.rainviewer.com/api/) (meteorología observada: últimos frames) y recuperan la imagen centrada en las coordenadas. Una capa separada de cobertura distingue una zona sin eco de una zona sin datos. El muestreo local de 9×9 píxeles utiliza un umbral conservador de opacidad en la paleta Universal Blue: el resultado **solo significa ecos de precipitación en el radar**, no lluvia confirmada en el suelo. La resolución efectiva depende del zoom de radar 7 y puede abarcar varios kilómetros.

Estados:
- **RainViewer · Ecos de precipitación**: el radar reciente detecta ecos cerca del lugar seleccionado. No es observación de pluviómetro.
- **RainViewer · Sin eco detectado**: radar reciente con cobertura, sin ecos significativos en la muestra. No asegura ausencia de lluvia fina / bajo el haz.
- **RainViewer · Imagen antigua, sin confirmar**: el último frame tiene más de 25 minutos.
- **RainViewer · Fuera de cobertura**: la máscara no confirma cobertura.
- **RainViewer · Sin observación fiable**: fallo de fuente, del procesamiento de imagen o de iOS; no se interpreta como tiempo seco.

Los tiempos de imagen se muestran según zona horaria configurada en el dispositivo. El script cachea el estado durante 5 minutos y solicita actualización en la política habitual del widget (iOS puede retrasar). RainViewer puede cambiar o interrumpir cobertura y aplica condiciones de uso personal/educativo; dar atribución visible en la UI es obligatorio.

**Importante:** por eso la parte de cuenta atrás sigue rotulada como **modelo** cuando prevé el fin. Las barras tampoco son observaciones. Este parche no cambia el motor radar/los rayos de RainETA.

### Qué comprobar en el iPhone
1. Abrir `RainETA-Consenso-Radar.js` en Scriptable y crear script nuevo `RainETA Consenso Radar`.
2. Dar permiso de red/ubicación y ejecutarlo dentro de Scriptable con `Parameter` (por ejemplo `57.7815,14.1562|Jönköping`) para previsualizarlo.
3. En la pantalla de inicio, seleccionar el nuevo script en un widget mediano.
4. Enviar captura mostrando `RainViewer...` y el reloj. Si aparece `Sin observación fiable`, puede ser una limitación de WebView en los widgets de iOS que tendremos que depurar.

Validado en pruebas de lógica simuladas: radar con eco, radar sin eco, radar antiguo. **No validado todavía con teselas reales en Scriptable/iPhone.** Para verificar Jönköping directamente, consultar el [radar oficial de SMHI](https://www.smhi.se/en/weather/radar-and-satellite/radar-and-lightning/q/nordics/location/Stockholm/2673730), desplazar el mapa a Jönköping, y comparar la hora de la imagen.

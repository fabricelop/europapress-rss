# Diagnóstico verificable de Live Activity y widget desde Windows

Caso real: Mi Mapa solicita una Live Activity, ActivityKit devuelve un ID y estado active, pero no aparece ni en la pantalla bloqueada ni en la Dynamic Island. Mi Mapa tampoco aparece en la galería de widgets; Scriptable sí.

Esto no demuestra un fallo de firma: puede ser el registro, lanzamiento o renderizado de la extensión. La IPA compilada incluye MiMapaWidgets.appex y su WidgetBundle registra tanto el widget como la Live Activity.

## Comprobar en el iPhone
Mi Mapa → Ajustes → Bloqueo y widgets → Comprobar widgets y actividad y Probar ahora. Anota hora e ID parcial. Bloquea el teléfono unos 20 segundos.

## Obtener registros en Windows (sin cambiar la app)
Con el iPhone por USB, desbloqueado y confiando en el PC, si YA tienes idevicesyslog.exe del proyecto libimobiledevice, abre PowerShell. No viene instalado por defecto, y no se deben instalar binarios de origen dudoso. Documentación del proyecto: https://cgit.libimobiledevice.org/libimobiledevice.git/tree/docs/idevicesyslog.1

~~~powershell
Get-Command idevicesyslog.exe
# Graba el syslog hasta pulsar Ctrl+C:
idevicesyslog.exe -K -p "liveactivitiesd|chronod|widgetkitd|SpringBoard|ReportCrash" -o "$env:USERPROFILE\Desktop\mi-mapa-ios-log.txt"
~~~

Durante la captura pulsa Probar ahora, bloquea, desbloquea e intenta abrir la galería de widgets. Al terminar, busca errores relacionados:

~~~powershell
Select-String -Path "$env:USERPROFILE\Desktop\mi-mapa-ios-log.txt" -Pattern "mimapadeltiempo|MiMapaWidgets|activity|widget|extension|signature|XPCInputParticipant|chronod|error" | Select-Object -Last 120
~~~

Los mensajes que nos sirven son errores de firma/aprovisionamiento, lanzamiento de la extensión, incompatibilidad de ActivityConfiguration, XPCInputParticipant has no activity for update, o crashes de MiMapaWidgets. Si no aparecen, el syslog puede resultar insuficiente y puede ser necesario obtener registros de diagnóstico de iOS o usar Consola/Xcode en un Mac.

Importante: antes de compartir cualquier registro, ocultar datos personales, identificadores y coordenadas. No cambiar el bundle ID ni reinstalar desde cero: se conservará el contenedor SQLite.

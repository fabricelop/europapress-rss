# Mi Mapa del Tiempo · PRUEBA independiente (1.0.19)

Este IPA está diseñado **únicamente** para instalarlo mediante Impactor y compararlo
con la app original instalada con Sideloadly.

**Identidades separadas:**
- App original: `es.mimapadeltiempo.app`
- App de prueba: `es.mimapadeltiempo.appprueba`
- Widget de prueba: `es.mimapadeltiempo.appprueba.widgets`
- App Group de prueba: `group.es.mimapadeltiempo.appprueba.widgets`

Los contenedores de almacenamiento no se comparten. Ambas apps pueden coexistir.
No se borran ni reemplazan los datos de la app original.

## Precauciones antes de instalar

1. Conservar la copia cifrada `.mmapbak` fuera del iPhone (ya guardada en Windows).
2. Instalar la IPA **MiMapaPrueba-v19-unsigned.ipa** con Impactor, no la IPA de producción.
3. Mantener **desmarcada «Registrar solo el bundle principal»** para instalar también WidgetKit.
4. Si hay límite de instalaciones gratuitas, eliminar **Diagnóstico Widget** (no Mi Mapa del Tiempo).
5. No aceptar instrucciones del instalador para borrar o sustituir la app original.

## Después de instalar

1. Abrir **Mi Mapa Prueba** (icono con esquina amarilla «P»).
2. En **Ajustes → Seguimiento**, usar **Detener seguimiento por completo** si estuviera activo.
3. En **Ajustes → Copia cifrada · sin iCloud obligatorio**, escribir la contraseña y
   seleccionar **Elegir copia .mmapbak para restaurar**. Debe mostrar primero
   "Copia válida" con el recuento de posiciones, intervalos y zonas.
4. Confirmar la restauración **solo en Mi Mapa Prueba**.
5. Comparar totales, zonas, mapa y fechas con la instalación original.
6. **Ajustes → Pantalla de bloqueo → Widgets y actividad en directo**:
   probar galería **Mi Mapa Prueba** y actividad en directo, y revisar App Group.
7. Mantener original y prueba sin registrar simultáneamente movimientos de prueba
   prolongados; no existe sincronización entre las dos aplicaciones.

La firma gratuita puede no autorizar el App Group aunque aparezcan la galería
y la actividad en directo. Si aparece «App Group no autorizado», informarlo
antes de modificar nada. No hay datos reales compartidos sin el grupo.

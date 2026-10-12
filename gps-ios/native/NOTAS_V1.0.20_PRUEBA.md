# Mi Mapa Prueba v1.0.20 · cambios de actividad y widget

Esta es una actualización **solo de Mi Mapa Prueba instalada con Impactor**.
Conserva su identificador, almacenamiento privado y extensión WidgetKit respecto
a la edición de prueba 1.0.19. Mi Mapa del Tiempo original no se modifica.

## Qué cambia

- La actividad en directo da prioridad al nombre del lugar y admite dos líneas.
- El cronómetro queda separado del nombre, evitando el truncamiento.
- Una nueva estancia de la misma cuadrícula reinicia el cronómetro, aunque el
  nombre del lugar sea el mismo; un cambio de cuadrícula detecta identidad
  diferente aunque ambas estén dentro de la misma zona.
- El widget sin App Group autorizado ya no usa letras blancas sobre un fondo
  casi blanco. Presenta un botón visual de acceso al mapa sin cifras inventadas.
- Diagnóstico más claro: registrar un widget en galería no implica que el
  App Group esté disponible; iOS decide esa autorización en su perfil firmado.

## Comprobación de firma de Impactor

El `App.entitlements` y `Widgets/Widget.entitlements` solicitan ambos
`group.es.mimapadeltiempo.appprueba.widgets`, pero en el iPhone de prueba
no se ha autorizado: `containerURL(forSecurityApplicationGroupIdentifier:)`
devuelve `nil`.

**No se ha probado ningún método legítimo para forzar esta autorización**.
La firma gratuita no implica soporte del App Group: el perfil válido para ambos
targets lo debe conceder Apple. Impactor registra la extensión, como se ha
verificado con el widget estático y la Live Activity, pero no ha concedido
capacidad de compartición. No se debe afirmar que los widgets pueden leer los
datos de SQLite si la firma continúa sin App Group.

## Pruebas

1. Mantener una copia cifrada `.mmapbak` en Windows y **NO borrar la app original**.
2. Cargar `MiMapaPrueba-v20-unsigned.ipa` en Impactor, con el bundle ID
   `es.mimapadeltiempo.appprueba`. Dejar desmarcada
   «Registrar solo el bundle principal».
3. Si Impactor pretende borrar otra aplicación o alterar su identificador,
   detenerse y consultar antes de continuar.
4. Si la actualización de Mi Mapa Prueba conserva datos, no es necesario importar
   la copia. Si aparecen datos vacíos, **no eliminar la otra app** y restaurar
   `.mmapbak` en la prueba tras detener el GPS.
5. Comprobar si el App Group continúa sin autorización, el widget legible,
   la Activity en bloqueo y el cronómetro al cambiar de cuadrícula y regresar.

**Límite conocido:** la Activity funciona sin App Group con datos enviados
directamente por la app; un widget estático no puede leer la base local
privada de la app sin compartición autorizada.

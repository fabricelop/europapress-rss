# Mi Mapa del Tiempo 1.0.18 — diagnóstico nativo en iPhone

No utilizar Scriptable. El IPA de GitHub Actions se construye sin firma y contiene
la app, la extensión WidgetKit y ActivityKit. **Compilar no garantiza** que la
firma posterior con Sideloadly autorice los dos ejecutables y sus capacidades.

## Probar en iPhone

1. Instalar IPA completo (no solo Payload/MiMapaDelTiempo.app) con Sideloadly.
2. Abrir Ajustes de iOS, buscar Mi Mapa del Tiempo, permitir ubicación,
   notificaciones y actividades en directo si aparecen las opciones.
3. En app -> Ajustes -> Widgets y actividad en directo, anotar:
   - extensión presente y bundle ID;
   - disponibilidad de App Group;
   - permiso ActivityKit;
   - cantidad de actividades y estado;
   - configuración de widget añadida.
4. Mantener pulsado escritorio -> Editar -> Añadir widget -> buscar
   Mi Mapa del Tiempo. La inexistencia en la galería apunta primero al
   registro y firma de MiMapaWidgets.appex, no al JSON del widget.
5. Pulsar Crear actividad de prueba, bloquear iPhone y comprobar presentación.
   ActivityKit puede aceptar la solicitud aunque la vista no se muestre si
   iOS no registra la extensión o la firma es incorrecta.
6. Si falla, aportar captura de los mensajes exactos, versión de iOS y
   salida de instalación de Sideloadly. No interpretar «aceptada» como
   «renderizada».

## Verificaciones de CI

- xcodebuild compila iPhone app y extensión.
- Ambas Info.plist tienen versiones 1.0.18 / 19; extensionPointIdentifier
  es com.apple.widgetkit-extension.
- project.yml asigna App.entitlements a la app y
  Widgets/Widget.entitlements a la extensión; ambos declaran el mismo grupo.
- iPhone físico conserva o no esos derechos tras Sideloadly: solo se
  puede decidir con la instalación firmada real.
- Un App Group desautorizado impide que un widget nativo lea datos de la app.
  El paquete y la extensión pueden compilar sin esa autorización.

El sistema operativo decide la frecuencia de recarga de WidgetKit. Las
Actividades en directo muestran un temporizador con ActivityKit y NO leen
el GPS directamente dentro del widget.

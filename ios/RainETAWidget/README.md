# RainETA para iPhone — prototipo nativo sin despliegue

Este directorio contiene una app SwiftUI mínima y una extensión WidgetKit iOS 17+; no es una aplicación instalada ni compilada. La instalación requiere macOS + Xcode y firma de desarrollo de Apple. No requiere una suscripción meteorológica.

## Preparación (solo en Mac)

1. Instala Xcode y XcodeGen (`brew install xcodegen`), entra aquí y ejecuta `xcodegen generate`.
2. Abre `RainETA.xcodeproj` y configura un equipo de firma para la app y extensión.
3. Antes de compilar, modifica la propiedad `RainETAAPIBaseURL` del target `RainETAWidgetExtension` en `project.yml`, sustituyendo `https://example.invalid` por el origen HTTPS de una **preview validada** que incluya `/api/rain-widget` (sin barra final). Regenera el proyecto. El valor inválido por defecto bloquea consultas a producción sin permiso.
4. Instala en el iPhone con Xcode. Abre RainETA y autoriza ubicación; después añade el widget. iOS preguntará si puede compartir la ubicación con el widget.
5. Pulsa prolongadamente el widget → Editar widget para elegir si usa ubicación actual o unas coordenadas alternativas.

El widget muestra una cuenta atrás visual nativa y solicita un nuevo pronóstico en la timeline. iOS limita los refrescos: **no es una actualización de datos garantizada cada minuto**. La autorización o posición pueden no estar disponibles para la extensión; entonces usa las coordenadas alternativas.

## Backend / diagnóstico

`GET /api/rain-widget?lat=40.4168&lon=-3.7038`

El servicio combina lluvia a intervalos de Open-Meteo y nowcast del radar AEMET cuando existe una señal reciente y fiable. En Iberia, las franjas de 15 minutos de Open-Meteo no deben interpretarse automáticamente como observaciones o pronóstico nativo de esa resolución. Ante incertidumbre no se muestra una ETA inventada. Los datos sirven para orientación y deben contrastarse con avisos oficiales.

La alternativa web en `/rain/widget/` permite probar cuenta atrás y búsqueda de localidades sin instalar una aplicación nativa, pero **un icono de web en la pantalla de inicio no es un widget de WidgetKit**.

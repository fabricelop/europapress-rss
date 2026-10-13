# RainETA para iPhone — v0.1.0

Primera versión nativa en **SwiftUI / MapKit**. Se encuentra aislada en `ios/raineta/` dentro del repositorio de RainETA y **no modifica ni despliega** la PWA existente. No utiliza Vercel ni Cloudflare.

## Funciones incorporadas

- GPS con permiso solo durante el uso y localización provisional de Madrid mientras se concede.
- Consulta directa a Open-Meteo para precipitación de 15 minutos, temperatura actual y probabilidad horaria.
- Cuenta atrás hasta el siguiente inicio o final de lluvia *según los datos del modelo*. No se presenta como medida radar.
- Radar RainViewer **observado** en mapa MapKit, desplazamiento por los barridos históricos y hora de la imagen.
- Visualización de las próximas tres horas, con barras de intensidad por intervalo de 15 minutos.
- Live Activity sin App Group ni widgets tradicionales: pantalla bloqueada y Dynamic Island, con actualización de contador por iOS.
- Datos caducados: transcurridos 30 minutos desde la última actualización, En Vivo muestra advertencia de previsión desactualizada.
- Actualización manual y mientras la aplicación está activa. iOS puede suspender la app en segundo plano.

## Lo que NO hace todavía

- No dibuja la extrapolación futura radar en el mapa. El motor de movimiento de la PWA en `vercel-webhook/rain/radar-core.js` se incorporará en fase posterior, tras pruebas y validación en iOS.
- No realiza consultas meteorológicas garantizadas cada cinco minutos con la app bloqueada. Una Live Activity no es un servicio de segundo plano.
- No incluye widget de pantalla de inicio, App Group, notificaciones push, animación de rayos, vista siete días ni predicciones detalladas del consenso de 15 modelos.
- La instalación y la compatibilidad de Live Activities dependen de cómo Impactor firme la app y su extensión.

## Compilar IPA sin firma

GitHub Actions: [RainETA iPhone IPA](https://github.com/fabricelop/europapress-rss/actions/workflows/raineta-ios.yml)

En un Mac con Xcode y XcodeGen:
```sh
cd ios/raineta
xcodegen generate
xcodebuild -project RainETA.xcodeproj -scheme RainETA -sdk iphoneos -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
```

El workflow genera `RainETA-0.1.0-unsigned.ipa` con el paquete `RainETALive.appex` embebido. Impactor debe volver a firmar ambos paquetes para el iPhone.

## Instalación

1. Descargar el artefacto `RainETA-0.1.0-IPA` de GitHub Actions y extraer la IPA.
2. Abrir Impactor, seleccionar el iPhone conectado, pulsar el botón de elegir IPA y cargar `RainETA-0.1.0-unsigned.ipa`.
3. Mantener activada **Actualización automática [BETA]** si quieres que Impactor intente renovar la firma. La renovación no se da por comprobada hasta verificarla.
4. Instalar con Apple ID y confiar en el perfil si iOS lo solicita.
5. Autorizar la ubicación cuando la app lo pida.
6. Abrir RainETA y pulsar **Activar En Vivo** cuando exista una ETA de comienzo o final de lluvia. Si iOS no permite Live Activities, revisar los ajustes de la app.

## Fuentes

- [Open-Meteo](https://open-meteo.com/) para predicción, no para observación radar.
- [RainViewer](https://www.rainviewer.com/api.html) para las teselas de radar pasadas, no futuro.
- MapKit y ActivityKit de Apple.

No hay cuenta de usuario, telemetría propia ni backend de pago. Los datos se descargan directamente de los proveedores; se aplican sus límites y condiciones de servicio.

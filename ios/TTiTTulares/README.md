# TTiTTulares para iPhone + WidgetKit

Esta carpeta contiene una app iOS mínima que mantiene la interfaz web actual de TTiTTulares dentro de un WKWebView y añade un widget nativo WidgetKit.

## Qué muestra el widget

- Listas
- En elaboración
- Creciendo
- Tendencias

Cada bloque abre directamente la sección correspondiente de TTiTTulares mediante el esquema `ttittulares://`.

Los datos se leen desde:

`https://europapress-rss.vercel.app/api/ttittulares-widget`

WidgetKit solicita una nueva timeline cada 15 minutos como mínimo; iOS puede espaciar las actualizaciones según sus políticas de batería y uso.

## Generar el proyecto Xcode

1. Instalar Xcode 17 o posterior.
2. Instalar XcodeGen:
   `brew install xcodegen`
3. Desde esta carpeta:
   `xcodegen generate`
4. Abrir `TTiTTulares.xcodeproj`.
5. Seleccionar el Apple Development Team en los targets `TTiTTulares` y `TTiTTularesWidget`.
6. Si los bundle identifiers ya estuvieran ocupados en el Team, cambiar:
   - `com.fabricelop.ttittulares`
   - `com.fabricelop.ttittulares.widget`
7. Ejecutar la app en el iPhone.
8. Añadir el widget desde la galería de widgets de iOS.

## Publicación

Vercel publica la web y la API que alimenta el widget. El binario iOS/WidgetKit requiere firma de Apple y se instala mediante Xcode, TestFlight o App Store; no puede desplegarse mediante Vercel.


## TestFlight desde GitHub Actions

El workflow `.github/workflows/ttittulares-testflight.yml` genera el proyecto, archiva la app con Xcode 26, firma automáticamente y la sube a App Store Connect/TestFlight.

Antes de lanzarlo hay que completar una única vez:

1. Tener activa la membresía Apple Developer Program.
2. Registrar en Apple Developer/App Store Connect la app con bundle ID `com.fabricelop.ttittulares`.
3. Verificar que el identificador de la extensión `com.fabricelop.ttittulares.widget` pertenece al mismo Team.
4. Crear una Team API Key de App Store Connect con permisos suficientes para distribución/provisioning.
5. Añadir en GitHub > Settings > Secrets and variables > Actions estos secrets:
   - `APPLE_TEAM_ID`
   - `APPSTORE_KEY_ID`
   - `APPSTORE_ISSUER_ID`
   - `APPSTORE_PRIVATE_KEY` (contenido completo del archivo `.p8`)

Después, ejecutar manualmente el workflow **TTiTTulares TestFlight**. El número de build usa `GITHUB_RUN_NUMBER`, por lo que aumenta automáticamente en cada ejecución.

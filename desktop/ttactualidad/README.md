# TTActualidad Desktop · Windows (primer paquete)

Aplicación de escritorio **Windows**. No abre ni requiere el antiguo sitio web de TTActualidad. La app nativa del iPhone sigue funcionando sin cambios.

## Instalar

1. Descarga el artefacto **TTActualidad-Windows-Portable-EXE** del workflow «TTActualidad Windows - EXE».
2. Descomprime el ZIP y ejecuta `TTActualidad.exe` en Windows 10/11. No hace falta instalar Python, Node, Chrome ni mantener una web o Worker activo.
3. La primera vez, pulsa **Conectar GitHub** e introduce el **Client ID público** de la misma GitHub App configurada en el iPhone. Autoriza en GitHub con el código que se abre en el navegador. El token se guarda mediante Windows Credential Manager (`keyring`), no en un archivo de texto.
4. Usa **Actualizar desde GitHub** para sincronizar; la ventana también consulta cada dos minutos mientras permanece abierta.

## Funciones disponibles

- Noticias: Listas, En elaboración, Revisión, Creciendo, Tremending.
- Tendencias: Top 30, Listas, En elaboración.
- Vista conjunta **Todas las Listas**, buscador, panel de detalles, contadores, publicaciones confirmadas de últimas 24 h.
- **+ Noticia**, **Elaborar/Reelaborar**, **Desestimar**, **Quitar de Listas**, **Marcar publicada** envían los mismos eventos `ttactualidad_manual_news_v1` y `ttactualidad_action_v1` que la aplicación iPhone. GitHub siempre valida ID, revisión y estado.
- **Publicar en X** abre el borrador en el navegador, sin suponer publicación; **Copiar texto**, abrir fuente y ChatGPT Images.
- Las respuestas HTTP 204 **solo confirman recepción de solicitud**. Nada se marca como publicado/elaborado sin que los archivos de GitHub lo confirmen tras sincronizar.

**Pendiente de paridad completa**: algunas opciones avanzadas de la app iOS (fotos de archivo integradas en la interfaz, aportación de pistas, agrupación y órdenes editoriales manuales) aún no tienen controles propios en Windows. El programa muestra sus datos editoriales, pero no debe anunciarse como clon exacto.

## Seguridad e infraestructura

- Nunca almacena contraseñas, PAT ni secretos de Cloudflare en el repositorio o en el EXE.
- El Client ID es público y se guarda en `%APPDATA%\\TTActualidad\\desktop.json`. Los tokens OAuth se guardan en **Credential Manager**.
- Los datos proceden exclusivamente de `raw.githubusercontent.com/fabricelop/europapress-rss/main/`. Acciones autorizadas a `api.github.com/repos/fabricelop/europapress-rss/dispatches`.
- Sin web alojada, sin procesos persistentes cuando está cerrado, sin Worker, KV o servidor local.
- Si una fuente no responde, **no se sustituye toda la pantalla por cero**. La actualización parcial no reemplaza el último estado ya validado.
- Para el borrado de la web antigua, usar el procedimiento separado `Retirar-Web-Antigua.ps1` solo después de instalar y verificar la versión Windows; no borrar ningún Worker de TTendencias, TTiTTulares o Instagram.

## Compilación

`.github/workflows/ttactualidad-windows.yml` compila en `windows-latest` mediante PyInstaller y publica un EXE portable (sin firma digital). Es normal que Windows SmartScreen muestre una advertencia para binarios sin firmar.

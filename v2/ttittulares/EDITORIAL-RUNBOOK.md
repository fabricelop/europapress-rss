# Noticias V2 — instalar y verificar el consumidor editorial

Código listo para instalación independiente en Windows. La presencia de este
documento o un CI verde no significa que el consumidor esté instalado en el PC.
No usa ChatGPT API ni el ejecutor V1: abre ChatGPT web con la cuenta autenticada
del mismo usuario Windows, como los trabajadores de tendencias V2.

## Instalación

Ejecutar `Install-News-Editorial-V2.ps1` con el usuario que ya utiliza tendencias
V2 y `gh auth` (o GH_TOKEN/GITHUB_TOKEN), Python con Playwright y jsonschema.
El instalador:

1. Rechaza actualizar si hay un consumidor de noticias activo; no lo termina.
2. Descarga código fijado a un commit de la rama V2 y verifica cada blob Git.
3. Ejecuta las regresiones sin enviar noticias ni abrir navegadores.
4. Copia un perfil autenticado V2 **cerrado** a un AuthSeed exclusivo de Noticias;
   no copia un perfil en uso, no cierra Chrome ni toca las tareas de tendencias.
   Si no encuentra uno disponible, admite `-SeedProfile <ruta>` de un perfil
   autenticado cerrado. Una copia no equivale a autenticación comprobada.
5. Lee la cola real sin reclamar trabajos y ejecuta una noticia piloto. Si falla
   texto, persistencia o cierre, no activa el programador. Si la cola está vacía,
   informa idle explícitamente; no afirma haber elaborado una noticia.
6. Activa su propia tarea `TTActualidadNoticiasV2-Editorial`, con 3 puestos.
   La salida START_REQUESTED confirma una solicitud de arranque, no 3 READY.

`-PrepareOnly` instala y comprueba sin enviar ni activar. Los resultados privados
y perfiles se quedan en `%LOCALAPPDATA%\TTActualidadNoticiasV2`, protegido para
ese usuario Windows. No se instala en TTActualidadV2 ni en C:\TTiTTulares.

## Ejecución

- FIFO por fecha real de entrada a pendientes y desempate por ID. El CAS de
  GitHub limita a tres reservas globales incluso con varios consumidores.
- Por noticia se crea un perfil temporal propio desde AuthSeed, un puerto CDP
  propio y una página de ChatGPT nueva; se verifica autenticación positiva.
- Antes del único Enter se guarda send_intent. Después se exige el turno de
  usuario con ID/revisión/comando exactos y URL /c/ para confirmar envío.
- Heartbeat renueva el lease mientras se espera. Captura solo al terminar la
  respuesta y mantenerse estable. JSON completo, dos fuentes independientes,
  tuit hasta 256 caracteres y hash editorial son requisitos de READY.
- El proceso cierra exclusivamente su Chrome/perfil, comprueba el cierre y
  guarda el registro READY inmutable, verifica readback y actualiza la ficha.
- No publica en X, no escribe V1, no abre el trabajador de imágenes. El fallo
  de una noticia deja su incidencia y el resto puede continuar.
- Si falta autenticación global se pausa la bandera de Noticias para no agotar
  los intentos de todo el backlog. Reautenticar el seed antes de habilitarlo.

## Parada y recuperación

Escribir `TTN2_EDITORIAL_ENABLED=NO` en `editorial.enabled` detiene nuevas
reservas; los puestos activos terminan y cierran sus recursos. No matar Chrome
genérico ni los perfiles de tendencias. La tarea no reinicia un navegador en
reposo: el daemon es Python y abre Chrome solo al procesar/preflight.

Una intención de envío incierta no se reencola ni se vuelve a mandar. El diario
local conserva respuesta/chat/credencial de lease para reparación dirigida;
GitHub conserva solo referencias opacas y hashes. Los fallos de commit tras
capturar conservan ese texto para recuperación sin volver a investigar/enviar.
Esta entrega identifica y aísla esas incidencias; no implementa un reparador
automático de conversaciones ambiguas ni cancela peticiones en el servidor.

CI prueba Linux y Windows con dobles de navegador y una lectura real FIFO
**sin escrituras**. La validación real ChatGPT/READY/cierre debe constar en los
logs de la instalación y en el record/commit de la primera noticia real.

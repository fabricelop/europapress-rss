# Memoria operativa — TTActualidad V2 / retirada progresiva de V1
Actualización: 15 de noviembre de 2026.

## Nombres acordados
- **V2**: https://ttactualidad-v2-private-test.fabricelop.workers.dev/ (panel privado).
- **V1**: https://ttactualidad.rainyraven22.chatgpt.site/tendencias (site público).
- Repositorio: fabricelop/europapress-rss. Rama de trabajo V2: feature/ttactualidad-v2-clean; no confundir con main de los flujos V1.

## Política editorial V2
- La captura Top30 tiene proceso independiente; las explicaciones editoriales son trabajos de ChatGPT, separados de la generación de imágenes y sin publicación automática en X.
- RE reinicia explicación e imagen para la nueva revisión. Debe entrar con prioridad sobre nuevos Top30 incluso cuando la tendencia haya salido del ranking; nunca duplicar revisiones ya aplicadas.
- La cola canónica de editoriales está en v2/ttendencias/state/editorial-queue.json. Cloudflare D1 almacena acciones del editor. La sincronización RE de Windows consulta cada ~90 s; la GitHub Action de RE cada cinco minutos actúa como respaldo, con reintentos ante conflictos.
- RE-X solicitado por Fabrice: segundo botón junto a RE; recibe pistas del editor, obliga a intentar localizar y comprobar conversaciones/posts relevantes en X, y debe indicar claramente si X fue inaccesible. Las pistas no constituyen hechos y no autorizan acusaciones ni publicación automática. No introducir datos privados en el campo: las pistas viajan a la cola editorial del repositorio público.
- No mencionar «TTActualidad V2», IDs, revisiones ni metadatos del sistema en los párrafos periodísticos finales.

## Imágenes
- V2 privada puede mostrar imágenes sensibles.
- Interruptor de imagen pública: cuando está desactivado, oculta imagen solo en V1; un tema sensible se oculta por defecto salvo decisión editorial expresa.
- Botón de supresión total: la referencia queda bloqueada en V1 y V2; no afecta al texto de la tendencia.
- Cuando una imagen está oculta en V1, añadir junto a su icono IA el mismo icono con una X roja. Preferencias ancladas a tendencia y revisión.

## Instalación del consumidor Windows
- Tarea actual: TTActualidadV2-Editorial-Auto; perfiles, procesos y módulo V2 aislados de V1.
- El instalador histórico copia una vez los módulos: actualizar GitHub NO actualiza un consumidor ya instalado.
- Activador seguro: v2/ttendencias/Activate-V2-RE-Priority.ps1. Descarga una revisión fijada, prueba código, solicita salida cooperativa de un trabajo editorial en curso, respalda, instala y relanza. No mata Chrome ni V1.
- CI en Windows: workflow ttactualidad-v2-re-windows-check.yml. Superar la CI NO confirma activación en el ordenador del propietario. Estado: **pendiente de ejecutar el activador en Windows y verificar daemon-status.json**.

## Auditoría de tareas V1: aún sin desactivar
- ttendencias-refresh.yml: captura/cola histórica V1, cron cada 10 min.
- ttendencias-site-top30-sync.yml: proyección Top30 del antiguo Site, cron cada 5 min.
- ttendencias-editorial-apply.yml: aplica salida editorial V1, cron cada 5 min.
- ttendencias-editorial-reconcile.yml: reconcilia la cola V1, cron cada 15 min.
- ttactualidad-group-listas.yml y ttactualidad-listas-alerts.yml: compartidas con noticias/titulares, NO deshabilitar sin separar consumidores.
- La portada pública de tendencias V1 puede seguir ofreciendo datos V2; auditar cómo recibe el estado antes de retirar las tareas.
- Política de retirada: comprobar cero pendientes V1, cero dependencia real en envíos X/Telegram, compatibilidad de LISTAS, Site público y rutas/alertas. Solo entonces retirar cada cron V1 de manera recuperable, uno por uno.
- No confundir apagar captura y redacción V1 con quitar /tendencias del Site público: el usuario quiere conservar esa vista alimentada desde V2.

## Estado que no se debe exagerar
- CI Windows del activador pasó antes de la ampliación RE-X; repetir CI tras cambios.
- No afirmar «activado en Windows» sin lectura de salida de la tarea real.
- La modificación del código del Worker privado NO implica por sí sola despliegue de Cloudflare; verificar publicación real.
- V1 no ha sido apagada.

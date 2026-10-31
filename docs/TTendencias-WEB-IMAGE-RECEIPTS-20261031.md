# TTendencias: recepción independiente de imágenes — 31/10/2026

## Fallo observado
Las imágenes de Elvis, La Voz Batallas, La Reunión Secreta y Lawson existen como archivos originales. En los jobs públicos no hay ai_image materializada: dos quedan ERROR con generating:true y dos LAUNCHED. La inscripción del consumidor se realizaba después del ACK; un fallo de confirmación perdía la capacidad de recuperar la imagen. El receptor antiguo también bloqueaba ERROR y fichas copiadas/publicadas. Una quinta imagen existente (Espanyol) ocupa 3.231.673 bytes, superior al antiguo límite de 3 MiB.

## Cambios publicados
- europapress-rss dc2222283cf33b96ee49a572050c09438b5bdc93: registro DPAPI antes de enviar; descubrimiento de URL por target propio; consumidor independiente con reintentos, contrato previo, recepción idempotente y estado web_image separado.
- europapress-rss d031ed8a556c85417588cbef7e2a905fd8ab373c: receptor web hasta 8 MiB y cuerpo acotado; transporte de bytes originales sin recomprimir.
- Servicio REAL desplegado: ttendencias-no-vercel-test, a través de fabricelop/tt-control workflow deploy-ttendencias-web-image-receipts.yml. Se conserva gateway, service binding, secretos y TTiTTulares.
- Deploys exitosos: https://github.com/fabricelop/tt-control/actions/runs/41172967794 y https://github.com/fabricelop/tt-control/actions/runs/41173325954.
- Contrato público comprobado: /api/ttendencias-run-status?view=web-image-contract devuelve web_image_receipt:2 y generates_images:false.
- CI Windows (incluye DPAPI y parser PS5.1) exitoso: runs 41172952325 y 41173292921 de europapress-rss.
- Site público versión 8, commit 84e6b5b27e1fc5d6a0cc7025867df3461fa826e7: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/. Guard v4 con ID, revisión, comando, texto y fecha, independiente del job mutable.
- Recuperados cuatro PNG adicionales, sin ImageGen: Elvis 15e3190f0e6c, La Voz 48ff11230694, La Reunión 3d5ee1703a15, Lawson 9950fd2c5b18. Comandos exactos indexados en sus archivos coinciden con los jobs y textos actuales. HTTP200 y SHA-256 de los cuatro originales publicados comprobados.

## Límites verificados; no prometer más
La recuperación anterior es manual y NO prueba el circuito automático. A las 05:39 UTC no se había observado un nuevo job v32 ni telemetría web_image desde el PC. El host Windows no es accesible directamente desde esta sesión. La actualización se distribuye por el actualizador/listener existentes, sin reiniciar Chrome9223/9234 ni tocar TTImages. Hay que observar un caso real nuevo: web_handoff_saved → web_image waiting → ai_image guard v4 → confirmación en main. Sin esa evidencia no declarar automatización comprobada de extremo a extremo.

La imagen candidata Espanyol’s Joyful Victory Celebration.png (libfile_a6eb5bdd6fe081918a4d268fdc7235a0) no se adjuntó a listas-joint-e8fc1845064ef779: el contexto recuperado confirma el comando original pero no vincula inequívocamente ese raster al comando. No asociar por nombre, tema o fecha ni usar la imagen del Villarreal individual f90cc5271f93 en la agrupación. Armoni Brooks aún no tenía job de imagen en el estado consultado.

## Alternativas
Reconciliador independiente automático: opción implementada para lo nuevo; no genera ni duplica imágenes. Recuperación de archivos guardados con procedencia exacta: respaldo para atrasos cuyo registro local se perdió. Botón en la app editorial: opción útil para ejecutar el mismo reconciliador y mostrar resultado, no una segunda generación; no está añadido al binario nativo. Mantener la web pública solo consulta. No usar Work programado, nuevos servicios de pago ni publicaciones X.

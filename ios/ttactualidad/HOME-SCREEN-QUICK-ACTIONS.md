# TTActualidad 0.4.25 · Menú del icono del iPhone

Abre la app una vez tras instalarla. Al mantener pulsado su icono en la pantalla
de inicio, iOS muestra cuatro accesos dinámicos:

| Acceso | Información | Destino |
| --- | --- | --- |
| Noticias listas | Número de noticias de Listas | TTiTTulares → Listas |
| Tendencias listas | Número de tendencias de Listas | TTendencias → Listas |
| En elaboración | Suma de noticias y tendencias en elaboración | Vista conjunta de ambos proyectos |
| Órdenes por confirmar | Órdenes de este iPhone sin comprobante definitivo | Panel de órdenes abierto |

Los números se obtienen del estado canónico de la última consulta, sin sumar
altas optimistas todavía sin confirmar. El menú indica fecha y hora; si hay
fuentes en caché, avisa «Datos parciales». Antes de la primera consulta no se
presentan listas desconocidas como cero. Las órdenes son locales a este iPhone.

El menú se actualiza al terminar una consulta y al pasar la app al fondo.
Al tocar un acceso se abre el destino y se solicita una consulta de datos.
No ejecuta redacción, imágenes, publicación ni borrados. No hace consultas
permanentes en segundo plano; el menú no promete información en tiempo real.

Implementación: `HomeQuickActions.swift` registra `UIApplication.shortcutItems`,
guarda el resumen y recibe la selección mediante los delegados de aplicación y
escena. `HomeQuickActionRouter` conserva selecciones al arrancar y las consume
una vez. `TTDashboard` dirige la navegación sin depender de la pestaña previa.
`EditorialStore.updateHomeQuickActions()` excluye las operaciones provisionales.

Pruebas nativas: esquema Xcode `TTQuickActions`, siete pruebas de títulos,
contadores, datos desconocidos/parciales, persistencia y entrega de selecciones.
El flujo GitHub Actions ejecuta estas pruebas en iOS Simulator antes de compilar
el IPA para iPhone.

# TTendencias Site ORIGINAL — pie de página de apoyo, sugerencias y analítica

**Site existente, NO crear otro:**
https://ttactualidad-tendencias.rainyraven22.chatgpt.site/
**project_id** appgprj_6ae4dcf7d7488191a574e5b649e67370

## Estado exacto

Implementación React/CSS y pruebas preparada en GitHub, pero **NO publicada**
todavía en ChatGPT Sites. La única conexión de este chat para el Site
permite inspeccionar, adjuntar y verificar imágenes, no modificar la interfaz.
Requiere aplicar la edición en el editor del mismo Site.

## Cambios

1. Después de las 30 tendencias, añade el componente SupportFooter.jsx una
   sola vez (no dentro de cada ficha) y su support-footer.css.
2. Donaciones: solo enlace externo https://ko-fi.com/ttactualidad.
   Texto castellano «Invítanos a un café». Aportación puntual, libre y
   voluntaria, sin recompensas, productos, suscripciones ni ventajas.
   No mostrar nombre civil, dirección, teléfono o datos personales; no incluir
   capturas de PayPal, enlaces personales o widget de terceros incrustado.
3. Sugerencias: textarea y botón «Preparar correo de sugerencia» que abre
   mailto:ttactualidad@gmail.com con asunto y texto precompletados.
   El visitante pulsa Enviar desde SU cliente de correo. Si su dispositivo
   carece de cliente configurado, puede pulsar el correo mostrado.
   No implementar POST a servidor ni afirmar «Enviado» por abrir mailto.
   No recoger correos, nombre o mensaje en analítica.
4. Quitar de TODAS las tarjetas de tendencia y de sus detalles la llamada
   «Copiar prompt de imagen IA» y su instrucción «Pégalo en un chat del
   proyecto con la conexión TTendencias para generar y adjuntar la imagen.»
   Retirar el CTA global/plantilla que lo dibuja; no solo ocultarlo por CSS.
   Este requisito **NO** autoriza borrar imágenes IA ya asociadas,
   los pequeños iconos de imagen existente ni otros medios editoriales.
   Mantener explicación, fuentes, agrupaciones y ranking.
5. Mantener visible el pie en móvil y escritorio, bajo el Top 30,
   sin tapar acciones, las pestañas, pie existente ni elementos sticky.

## Métricas de visitas e interacciones

Recomendación comprobada: Umami Cloud plan Hobby gratuito.
Tiene 1 web / hasta 100.000 eventos al mes / 6 meses de histórico
(según https://umami.is/pricing a noviembre de 2026).
A diferencia de Cloudflare Web Analytics, Umami registra eventos
personalizados como clics en botones y apertura de fichas.

**Acción del propietario necesaria, solo una vez:**

- Crear cuenta de Umami Cloud en https://cloud.umami.is/signup y elegir
  región EU si se ofrece. No seleccionar Pro ni prueba de pago.
- Registrar exactamente el dominio
  ttactualidad-tendencias.rainyraven22.chatgpt.site
- Copiar el código de seguimiento de la nueva web desde la sección de Tracking
  en Umami. El código es personalizado: sin ese ID NO hay analítica activa.
- Pegar el script de la cuenta en HEAD del Site original a través de su
  editor (no inventar el ID). Revisa políticas CSP del Site y comprueba
  con herramienta Network del navegador que el script carga correctamente.
- Enlazar eventos de clic genéricos con los atributos data-umami-event ya
  incluidos en los botones del footer. En el controlador EXISTENTE de
  apertura de fichas Top 30, usar:
      trackSiteEvent(METRIC_EVENTS.expand, {rank: row.rank})
  solo al ABRIR. No registrar búsquedas por cada letra.
  Opcional: registrar evento «Usar buscador Top30» una vez al confirmar
  o empezar una búsqueda; JAMÁS pasar el término consultado.
- Verificar el panel Umami: visitante/visitas, navegación, país aproximado
  y eventos «Donacion Ko-fi», «Abrir correo sugerencia», «Abrir ficha
  tendencia», «Usar buscador Top30». No hay identificación individual ni
  grabación de pantalla; no prometer que se sabe exactamente quién entra.
- Informar en la página de la medición agregada. Si se usan otras
  herramientas, funciones de marketing, identificación, cookies o datos
  personales, revisar el consentimiento, el aviso de privacidad y la normativa
  aplicable antes de activarlos. No incluir publicidad ni identificadores.

*Nota:* Un clic en «Invítanos a un café» no demuestra que se haya donado.
El botón de correo indica intención de enviar, no un email recibido.

## Pruebas y publicación

Pruebas sin dependencias:
    node --test site-patches/ttendencias-support-footer/*.test.mjs

Comprobar manualmente en móvil y escritorio:
- Ko-fi abre la cuenta correcta con mensaje de donación voluntaria;
- formulario abre correo redactado al destinatario exacto y NO declara envío;
- enlace mailto funciona; sin JS la dirección de correo sigue visible;
- ya NO aparece «Copiar prompt de imagen IA» en NINGUNA tendencia;
- las imágenes originales existentes permanecen;
- Umami no muestra visitas/eventos antes de instalar el script específico;
- tras instalarlo, visitas y clics de prueba aparecen en el panel sin texto
  de formularios ni de búsquedas;
- no se altera el JSON editorial, ni la sincronización ni el Site público
  original.

No decir «publicado» sin verificar que el Site original fue guardado y
publicado por su editor.

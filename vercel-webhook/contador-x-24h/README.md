# Contador X 24 h — prueba local gratuita

**Alcance:** únicamente cuentas `@ttittulares` y `@ttendenciasesp`. Prueba de solo lectura. **No está activada en producción** y no modifica las aplicaciones actuales.

## Cómo probar sin instalar nada

1. Descarga `index.html` de esta carpeta usando **Raw / Guardar enlace como** y ábrelo en Chrome. También puedes ejecutar el archivo local sin conexión.
2. En otra pestaña, entra normalmente en X con tu propia sesión. Abre la búsqueda de tus posts en la pestaña **Más recientes** y desplázate **manualmente** hacia atrás hasta alcanzar publicaciones anteriores a las últimas 24 horas.
3. Usa **Guardar página como… (Ctrl+S)** y guárdala como HTML. Arrastra ese archivo al contador para analizar los enlaces a publicaciones que realmente hayan quedado en el HTML guardado.
4. También puedes pegar enlaces individuales `https://x.com/USUARIO/status/ID`, o cargar un archivo `tweets.js` de una exportación oficial de X.
5. Compara la cifra visible con X. Para la cuenta TTiTTulares, el usuario observó **51** publicaciones reales frente a **54** registros internos en la primera prueba de 2026-10-08 (cifras históricas, no límites fijos).

**Advertencia de exhaustividad:** el HTML guardado por Chrome puede contener únicamente las publicaciones que la página cargó y mantuvo en el DOM. Aunque aparezca un tuit de hace más de 24 horas, X puede no entregar todos los resultados, por lo que esto sigue siendo un **recuento identificado**, no un contador exacto garantizado. Una URL de búsqueda no contiene los resultados y no sirve como importación. Los archivos exportados por X pueden estar desactualizados.

## Seguridad y límites

- Todo el cálculo ocurre **localmente** en el navegador; el HTML no envía datos, ni abre conexiones de API, ni automatiza la web de X.
- El programa **no usa** Chrome DevTools Protocol, scraping, cookies, credenciales, extensiones, ni scripts sobre la web de X. X prohíbe la automatización de su sitio mediante scripts: https://help.x.com/en/rules-and-policies/x-automation.
- **No compartas archivos HTML guardados de una sesión iniciada**: pueden contener información privada. Analízalos solo en tu ordenador.
- La fecha y la hora se calculan a partir del identificador numérico público del post (Snowflake). Se deduplican enlaces repetidos por cuenta.
- No se puede comprobar con ello si un post fue borrado, si hubo publicación omitida por X o cómo calcula X internamente sus límites específicos.
- La estimación de «disponibles» usa un **límite de referencia editable** (51) y **no** es confirmación del saldo oficial de X.
- Nada se guarda en servidor ni en LocalStorage; al cerrar el archivo se pierde el recuento importado. Puedes exportar solo IDs y horas a JSON sin credenciales.

## Pruebas rápidas del parser

- `https://x.com/ttittulares/status/ID` cuenta para TTiTTulares.
- `https://x.com/ttendenciasesp/status/ID` **no** cuenta para TTiTTulares y viceversa.
- Enlaces HTML `href="/ttittulares/status/ID"` deben reconocerse.
- El mismo ID en distintos enlaces se cuenta **una vez**.
- La página `https://x.com/search?q=from%3Attittulares` no se cuenta como un post.
- Solo se incluyen ID con fecha calculada dentro de las **24 horas anteriores al instante actual**.

**Siguiente fase posible:** integración con la API oficial de X si se dispone de autorización, cuotas y presupuesto; no se conecta a X sin intervención del usuario.

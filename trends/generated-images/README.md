# TTendencias generated images

Repositorio público previsto para imágenes generadas cuando el flujo editorial pueda obtener el fichero binario/base64 de la generación.

Convención:
- Ruta: `trends/generated-images/<id>-r<revision>.<ext>`
- URL pública: `https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/<id>-r<revision>.<ext>`

El preparado debe usar:
```json
{
  "image": {
    "url": "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/<id>-r<revision>.png",
    "source": "TTendencias / ChatGPT",
    "source_url": "https://github.com/fabricelop/europapress-rss/blob/main/trends/generated-images/<id>-r<revision>.png",
    "rights_status": "generated",
    "alt": "...",
    "generated": true
  }
}
```

La app de preparados consume cualquier `prepared_item.image.url` HTTPS y permite abrir/copiar la imagen mediante el proxy existente.

# TTActualidad para Windows — alternativa sin EXE

Este paquete contiene archivos Python (.pyw y .py), no ejecutables .exe.

## Requisitos

- Windows 10/11 con Python 3.12 y el lanzador py.
- Permiso para instalar bibliotecas Python PySide6 y keyring.
- Acceso HTTPS normal a GitHub. No requiere la web anterior ni un Worker.

## Instalación y arranque

Descomprime todo el ZIP en la misma carpeta, abre Windows Terminal y ejecuta:

    py -m pip install -r requirements.txt
    py TTActualidad_Moderno.pyw

También puedes abrir el archivo .pyw con doble clic si el sistema tiene asociada esa extensión a Python.

## GitHub sin móvil

En la app, pulsa Conectar GitHub y usa el enlace para crear un fine-grained personal access token.
Limita el token al repositorio fabricelop/europapress-rss y otorga Contents: Read and write.
Pega el token en la ventana Windows. Se verifica con GitHub y se guarda en Windows Credential Manager (keyring), nunca en texto plano.
Puedes revocar el token desde GitHub. La lectura pública funciona sin conexión autenticada.
El código HTTP 204 confirma solo la recepción de una orden: el estado final se verifica después de actualizar.

## Seguridad de empresa

Un .pyw no evita ni debe intentar eludir las políticas corporativas; Python y sus dependencias pueden estar restringidos.
Si se bloquea la ejecución, solicita autorización a informática. Se conserva la app iPhone y el Worker antiguo.

Este proyecto es local: al cerrar la aplicación no deja un proceso residente.

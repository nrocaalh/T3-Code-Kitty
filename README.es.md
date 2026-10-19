# T3 Code Kitty 🐱

[English](README.md) | [Español](README.es.md)

Un gato flotante en el escritorio para [T3 Code](https://t3.tools). Vigila tus sesiones y te avisa cuando alguna termina, sin abrir la app.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Qué hace

- **Trabajando**: alguna sesión está corriendo (píldora con el contador).
- **Finalización**: cuando una sesión acaba, el gato hace una animación de salto con chispas.
- **Finalizado**: si no hay más sesiones trabajando, el gato se queda en alerta con un badge hasta que le hagas click o abras la sesión en T3 Code.
- **Dormido**: T3 Code está cerrado.

El click en el gato limpia los avisos de "finalizado" y abre T3 Code.

## Cómo funciona

Lee en **solo lectura** la caché local de T3 Code (IndexedDB/LevelDB en `~/Library/Application Support/t3code`) para conocer el estado de las sesiones. No usa red, no escribe en la base de datos de T3 Code y no envía ningún dato fuera de tu máquina.

## Descargar

Descarga el último `.zip` desde [Releases](https://github.com/nrocaalh/T3-Code-Kitty/releases), descomprímelo y mueve `T3CodeKitty.app` a `~/Applications`. Para actualizar, descarga la nueva versión y sustituye la app (tu configuración — posición del panel, idioma, etc. — se conserva).

## Construir

Requiere Xcode 16+ (herramientas Swift 6).

```sh
swift test    # tests unitarios del núcleo de parseo
./build.sh    # compila el bundle y lo instala
```

Instala la app en `~/Applications/T3CodeKitty.app` (firmada ad-hoc, sin sandbox). El CI (`.github/workflows/ci.yml`) ejecuta tests + build en cada push.

Para publicar una versión, sube `CFBundleShortVersionString` en `Info.plist`, crea un tag y el CI hace el resto:

```sh
git tag v1.2.0 && git push origin v1.2.0   # ejecuta tests, compila y adjunta el zip a un Release de GitHub
```

## Uso

- Barra de menú (icono de huella): estado, sesiones pendientes, abrir T3 Code, silencio de avisos/sonido, idioma (ES/EN), inicio con sesión de macOS.
- El panel se puede arrastrar con el ratón y recuerda su posición.
- Idiomas: español e inglés; sigue el idioma del sistema y se puede cambiar desde el menú (Idioma / Language).

## Estructura

```
Sources/
  main.swift       # modelo de estado, panel, menú, LaunchAgent
  CatView.swift    # render del gato (sprites generados + fallback vectorial)
  T3Watcher.swift  # lectura de la caché local de T3 Code (read-only)
Assets/            # iconos y sprites del gato
```

## Licencia

MIT

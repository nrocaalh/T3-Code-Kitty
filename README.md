# T3 Code Kitty 🐱

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

## Construir

```sh
./build.sh
```

Requiere Xcode command line tools. Instala la app en `~/Applications/T3CodeKitty.app` (firmada ad-hoc, sin sandbox).

## Uso

- Barra de menú (icono de huella): estado, sesiones pendientes, abrir T3 Code, silencio de avisos/sonido, inicio con sesión de macOS.
- El panel se puede arrastrar con el ratón y recuerda su posición.
- Interfaz en español por diseño.

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

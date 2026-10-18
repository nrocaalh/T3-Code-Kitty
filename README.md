# T3 Code Kitty 🐱

[English](README.md) | [Español](README.es.md)

A floating desktop cat for [T3 Code](https://t3.tools). It watches your sessions and alerts you when one finishes, without opening the app.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## What it does

- **Working**: some session is running (pill with the counter).
- **Finished**: when a session ends, the cat does a jump animation with sparkles.
- **Done**: if no more sessions are working, the cat stays alert with a badge until you click it or open the session in T3 Code.
- **Idle**: T3 Code is closed.

Clicking the cat clears the "done" alerts and opens T3 Code.

## How it works

Reads the local T3 Code cache (IndexedDB/LevelDB in `~/Library/Application Support/t3code`) in **read-only** mode to know the state of your sessions. No network, no writes to T3 Code's database, and no data leaves your machine.

## Build

```sh
./build.sh
```

Requires Xcode command line tools. Installs the app to `~/Applications/T3CodeKitty.app` (ad-hoc signed, no sandbox).

## Usage

- Menu bar (paw icon): status, pending sessions, open T3 Code, mute alerts/sound, language (ES/EN), launch at macOS login.
- The panel can be dragged with the mouse and remembers its position.
- Languages: Spanish and English; follows the system language and can be changed from the menu (Idioma / Language).

## Structure

```
Sources/
  main.swift       # state model, panel, menu, LaunchAgent
  CatView.swift    # cat rendering (generated sprites + vector fallback)
  T3Watcher.swift  # reads the local T3 Code cache (read-only)
Assets/            # icons and cat sprites
```

## License

MIT

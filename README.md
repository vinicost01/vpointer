# vpointer

A lightweight macOS menu bar utility focused on two essential conveniences for MacBook users with an external mouse:

1. **Automatic Natural Scrolling**:
   - **Disables Natural Scrolling** automatically whenever any external mouse (USB or Bluetooth) is connected.
   - **Re-enables Natural Scrolling** automatically when no external mouse is connected.
2. **MiddleClick (3-finger middle click)** on Trackpad and Magic Mouse:
   - **3-finger physical click** (including middle-button drag).
   - **3-finger light tap**.
3. **Hideable menu bar icon**:
   - Can be completely hidden to keep your menu bar clean; to show it again, simply open `vpointer` from Spotlight or the Applications folder.

## How It Works

- Monitors hardware connect/disconnect events in real time via `IOHIDManager` (IOKit) with zero polling overhead.
- Automatically ignores the built-in MacBook Trackpad and external trackpads.
- Applies Natural Scrolling changes **instantly** via CoreGraphics (`CGSSetSwipeScrollDirection`) and syncs the global `com.apple.swipescrolldirection` preference.
- Re-checks connected devices automatically when the MacBook wakes from sleep.

## Permissions

- Automatic **Natural Scrolling** switching requires **no special permissions**.
- The optional **MiddleClick (3-finger)** feature requests **Accessibility** permission (*System Settings > Privacy & Security > Accessibility*) when enabled in order to convert/post middle-click events.

## Build

```bash
./build.sh
```

The app bundle is generated at `build/vpointer.app`.

## Install & Run

1. Copy the app to `/Applications`:
   ```bash
   cp -R build/vpointer.app /Applications/
   ```
2. Launch it:
   ```bash
   open /Applications/vpointer.app
   ```
3. (Optional) Click the menu bar icon to enable **MiddleClick (3 dedos)**, **Iniciar com o macOS**, or **Ocultar ícone da barra de menus**.

# ScreenLock

<img src="Resources/icon-1024.png" width="128" alt="ScreenLock icon">

A tiny macOS menu-bar app that confines the mouse cursor to one display. Handy for full-screen games or remote-play sessions (e.g. League of Legends over UU 远程) where the cursor keeps escaping to a second monitor.

把鼠标锁在一块屏幕里的 macOS 菜单栏小工具，多屏打游戏/远程串流时防止鼠标跑到别的屏幕。

## Features

- Toggle with **⌥⌘L**, or pick a display from the menu-bar menu
- Template menu-bar icon that matches the system style (`rectangle` / `lock.rectangle`)
- Listen-only event tap: never rewrites mouse events, so dragging stays responsive; the cursor is pulled back only when it actually leaves the locked display
- No Dock icon (`LSUIElement`)

## Build

Requires Xcode command line tools (Swift).

```bash
./build.sh
open ~/Applications/ScreenLock.app
```

## Permissions

ScreenLock needs **Accessibility** access (System Settings › Privacy & Security › Accessibility). The build is ad-hoc signed, so after every rebuild remove the old entry and add the app again.

## License

MIT

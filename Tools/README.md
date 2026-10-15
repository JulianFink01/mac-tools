# App-Icons

`generate_app_icon.swift` zeichnet das MacTools-Icon (Mac-Display mit Werkzeug) und das passende monochrome Menüleisten-Icon nativ mit AppKit.

```sh
xcrun swift -module-cache-path build/SwiftModuleCache Tools/generate_app_icon.swift
```

Die erzeugten PNGs liegen unter `MacTools/Assets.xcassets/`. Der native Build erstellt daraus das ICNS im App-Paket.

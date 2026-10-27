# ClamAV-Laufzeit

`ClamAV/` wird durch `python3 Scripts/prepare-clamav.py` reproduzierbar erzeugt und nicht in Git gespeichert. Version 1.5.4, offizielles Universal-Paket und Quellarchiv, festgelegte SHA-256-Prüfung. Die Laufzeit erhält einen relativen Bibliothek-Suchpfad und lokale Signaturen; Engine-Code unverändert.

App und DMG enthalten ClamAV-Binaries, Bibliotheken, Zertifikate, Lizenztexte und das passende vollständige Quellarchiv. Ein Startbestand der Virensignaturen kann wie in `LOCAL_BUILD.md` beschrieben hinzugefügt werden. Die App aktualisiert die Signaturen über FreshClam.

## Terminal

`Terminal/` enthält xterm.js 6.0.0 und addon-fit 0.11.0 (MIT) mit lokalen Lizenzen und festgelegten Paket-/Dateihashes in `versions.json`. Die App lädt diese Ressourcen offline; Eingaben und Ausgabe laufen direkt über ein lokales Pseudoterminal zu OpenSSH.

## Chat-Rendering

`ChatRenderer/` enthält KaTeX 0.19.1 inklusive WOFF2-Schriften, Marked 18.1.2, DOMPurify 3.4.17, Plotly.js 4.1.2, Vega 6.4.0, Vega-Lite 6.5.0 und Vega Embed 7.3.0. Lizenzen liegen als `LICENSE-*` bei; Herkunft, feste Versionen, SHA-512-Paketintegrität und SHA-256-Dateihashes stehen in `versions.json`. `python3 Scripts/prepare-chat-renderer.py` reproduziert die unveränderten Bibliotheken aus dem offiziellen npm-Registry. `renderer.js` und `visualization.css` sind eigene MacTools-Dateien und werden beim Vendoring nicht überschrieben. Beide Buildwege liefern den gesamten Ressourcenordner mit aus.

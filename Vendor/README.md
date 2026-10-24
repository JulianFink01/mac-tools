# ClamAV-Laufzeit

`ClamAV/` wird durch `python3 Scripts/prepare-clamav.py` reproduzierbar erzeugt und nicht in Git gespeichert. Version 1.5.4, offizielles Universal-Paket und Quellarchiv, festgelegte SHA-256-Prüfung. Die Laufzeit erhält einen relativen Bibliothek-Suchpfad und lokale Signaturen; Engine-Code unverändert.

App und DMG enthalten ClamAV-Binaries, Bibliotheken, Zertifikate, Lizenztexte und das passende vollständige Quellarchiv. Ein Startbestand der Virensignaturen kann wie in `LOCAL_BUILD.md` beschrieben hinzugefügt werden. Die App aktualisiert die Signaturen über FreshClam.

## Terminal

`Terminal/` enthält xterm.js 6.0.0 und addon-fit 0.11.0 (MIT) mit lokalen Lizenzen und festgelegten Paket-/Dateihashes in `versions.json`. Die App lädt diese Ressourcen offline; Eingaben und Ausgabe laufen direkt über ein lokales Pseudoterminal zu OpenSSH.

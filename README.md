# MacTools

Dein Mac. Deine Werkzeuge. Eine native macOS-App von **[Julian Fink](https://julian.fink-cloud.net)**, gebaut mit Swift, SwiftUI und AppKit.

[MacTools herunterladen](https://github.com/JulianFink01/mac-tools/releases/latest/download/MacTools-universal.dmg) · [Alle Releases](https://github.com/JulianFink01/mac-tools/releases) · [Meine Website](https://julian.fink-cloud.net)

macOS 13 oder neuer · Universal Binary für Apple Silicon und Intel · lokale Verarbeitung

## Systemmonitor und Menüleiste

![MacTools-Systemmonitor mit nativer Fenster-Kopfleiste](docs/screenshots/mactools-monitor.png)

Die Startansicht zeigt echte Messwerte für CPU, RAM, GPU, Datenträger und Netzwerk. Karten mit Verlauf führen zu Detailansichten: CPU-Kerne, Speicherdruck, Apps/Wired/komprimierter RAM, Swap und Top-Prozesse. Messwerte werden alle zwei Sekunden aktualisiert; Verläufe bleiben lokal gespeichert. GPU-Daten erscheinen nur, wenn macOS sie bereitstellt.

CPU-, RAM-, GPU- und Disk-Widgets lassen sich in den Einstellungen einzeln aktivieren. Das Schnellpanel bietet aktuelle Werte, Speicherbelegung und Schnellaktionen. Priorisierte Live-Ereignisse – Funde, laufende Scans und angeheftete Fenster – stehen oben; zwischen Ereignissen kann man wischen oder mit Pfeilen wechseln. Angeheftete Fenster lassen sich einzeln lösen.


Die Duplikat-Abbildung verwendet eigene Beispieldateien.

## Disk & Sicherheit

Ein Gesamtscan erfasst den ausgewählten Ordner oder das Volume ohne feste Dateigrenze und verbindet Speicheranalyse, Duplikatprüfung und anschließende Virenprüfung. Die Dateiliste ist schon während der Inhaltsprüfung nutzbar.

- Ordner öffnen über die gesamte Zeile, Breadcrumbs, aktueller Pfad, Zurück/Vorwärts und eine Ebene höher.
- Große Dateien, Dateitypen, Ordnergrößen, Dateizahlen und Verlauf abgeschlossener Scans.
- Logische Größe, tatsächlich gemeldete Dateibelegung und freier Volume-Speicher werden getrennt dargestellt. Sparse-Dateien und APFS-Kopien können deutlich weniger Platz belegen als ihre logische Größe.
- Persistente Ergebnisse einschließlich Dateilisten, Ordnern und Duplikaten. Große Berichte werden atomar in Blöcken gespeichert und nach Neustart im Hintergrund geladen.
- Fortschritt unten in der Seitenleiste und im Schnellpanel. Zugriffshinweise stehen nur in der Übersicht; geänderte laufende Datenbanken und Cloud-Platzhalter sind neutrale Scan-Informationen.

### Duplikate bewusst auswählen

![Duplikate mit Medien- und Dokumentfilter und getrennten Zählern](docs/screenshots/mactools-duplicates.png)

Standardmäßig zeigt der Filter Bilder, GIFs, Videos, Audio, PDFs, Office-Dateien und CSV. Der Filter lässt sich ausschalten; getrennte Zähler zeigen Medien/Dokumente und alle Dateitypen.

Die Erkennung prüft Dateigröße, liest bei großen Dateien zunächst Ausschnitte und bestätigt Übereinstimmungen mit vollständigem SHA-256. Bis zu vier begrenzte Arbeiter und ein Cache für unveränderte Dateien beschleunigen weitere Scans. Der Cache berücksichtigt Dateiidentität, Größe sowie Änderungszeiten inklusive ctime. Hardlinks zählen einmal; Symlinks werden nicht verfolgt und Cloud-Dateien werden für die Inhaltsprüfung nicht automatisch heruntergeladen.

Dateien lassen sich vergleichen und **nur nach ausdrücklicher Auswahl und Bestätigung** in den Papierkorb verschieben. Auch App-, Library-, Projekt- und WhatsApp-Dateien sind manuell auswählbar. Heikle Pfade sind orange markiert; der Löschdialog erläutert mögliche Folgen. „Alle Kopien dieser Gruppe auswählen“ wählt auch große Gruppen gesammelt aus. Mindestens eine Kopie bleibt erhalten. **Keine automatische Bereinigung.** Beim Entfernen werden Dateimetadaten kontrolliert; danach werden nur die tatsächlich entfernten Einträge und ihre Statistiken aktualisiert und gespeichert. Es folgt kein automatischer Neu- oder Virenscan. Löschungen werden zentral an Dateilisten, Duplikate und Virenfunde weitergegeben; auch entfernte App-Daten werden berücksichtigt.

### Lokaler Virenscan

ClamAV-Engine, Bibliotheken und initiale Signaturen gehören zum Anwendungspaket; Homebrew ist für die Benutzung nicht erforderlich. Schutzdaten lassen sich aktualisieren. Der tägliche Gesamtscan führt Speicher-, Duplikat- und Virenprüfung gemeinsam aus. Warnkarten beschränken sich auf Funde, fehlgeschlagene Prüfungen, Signaturprobleme und akut knappen Speicher; einzelne ausgelassene Dateien stehen im Scan-Ergebnis.

Die Virenprüfung nutzt beim Gesamtscan dessen Dateiliste. Bis zu vier begrenzte parallele Worker laden ihre Engine jeweils einmal; die Anzahl berücksichtigt CPU und verfügbaren Systemspeicher. Aktuell identische und durch den Disk-Scan bestätigte Inhalte werden einmal geprüft; Funde werden den entsprechenden Kopien zugeordnet. Geänderte Dateien werden nicht zusammengefasst. Die Oberfläche zeigt Vorbereitungsphase, gemeinsamen Dateifortschritt, Workerzahl, Durchsatz, aktuelle Datei und Funde. Kleine Dateien werden zuerst geprüft. Dateien über 2 GiB werden ausdrücklich als nicht geprüft gezählt; je Datei gelten außerdem 400 MiB entpackter Prüfinhalt und 30 Sekunden Engine-Zeitlimit. Erreichte Limits erscheinen im Ergebnis und gelten nicht als Entwarnung. Die Virenprüfung kann für die gespeicherte Dateiliste erneut gestartet werden, ohne einen neuen Duplikatscan auszulösen. EICAR-Testdateien werden ausdrücklich als Test erkannt.

Die Fundliste zeigt verdächtige Dateien und harmlose EICAR-Testdateien getrennt von eingeklappten Prüflimits. Einzelne Dateien und eine manuelle Mehrfachauswahl lassen sich direkt nach Bestätigung in den Papierkorb verschieben, auch aus gespeicherten Ergebnissen. Entfernte Einträge bleiben nach Neustart entfernt; dafür wird kein neuer Scan gestartet. Der ursprüngliche technische Prüfbericht bleibt als Historie erhalten.

Dateien werden nicht hochgeladen oder automatisch gelöscht. Dies ist kein Echtzeitschutz. Alte Signaturen, nicht zugängliche Inhalte und Engine-Limits werden sichtbar; unbekannte Malware kann übersehen werden. Ein vollständiger Virenscan über Millionen Dateien kann trotz Optimierungen längere Zeit benötigen.

## Weitere Tools

**Apps:** Installierte Anwendungen mit zugehörigen Daten anzeigen und ausgewählte Bestandteile in den Papierkorb verschieben. Exakte Bundle-ID-Zuordnung, Hinweis auf Namenszuordnungen, Schutz gemeinsamer Daten und Sperre gegen Selbst-Deinstallation.

**Live-Hintergrund:** Videos importieren, auswählen, zufällig wechseln, pausieren und fortsetzen. Darstellung einpassen oder füllen. Enthält ein installierbares macOS-Bildschirmschoner-Modul für das ausgewählte Video; Passwortabfrage und Sperrverhalten verwaltet macOS.

**Fenster vorn halten:** Globales konfigurierbares Tastenkürzel (standardmäßig ⌥⌘P), explizite Fensterwahl und mehrere unabhängig vom Popup gehaltene Fenster. Eigene MacTools-Fenster schweben nativ. Für fremde Fenster prüft MacTools zunächst die tatsächliche Original-Fensterebene. Falls macOS deren Änderung verweigert, erhält das Original eine eigene virtuelle Retina-Fensterfläche und eine lokale schwebende ScreenCaptureKit-Ansicht. Die Maus bedient das Original dort nativ; ScreenCaptureKit zeigt den nativen macOS-Cursor direkt im Live-Bild. Eine zusätzliche Cursor-Zeichenschleife entfällt. Hover, Klicks, Scrollen und Tastenkombinationen benötigen dadurch keine app-spezifische Nachbildung. Mit Escape oder am Rand der Ansicht kehrt die Maus zum normalen Bildschirm zurück. Schließen, „Lösen“ und „Original öffnen“ bringen das Originalfenster auf deinen Bildschirm zurück und entfernen seine virtuelle Fläche. Einzelne separate App-Dialoge oder geschützte Inhalte können das Original benötigen; uneingeschränkte Kompatibilität mit jeder App ist nicht zugesichert. Fenstersteuerungs- und Bildschirmaufnahme-Freigaben sind getrennt erforderlich. Keine Aufnahme auf der Festplatte und kein Upload; kein Eingriff in SIP.

## Installation und Freigaben

1. DMG aus dem GitHub-Release laden und `MacTools.app` nach `Programme` ziehen.
2. App starten; Systemmonitor, Menüleisten-Widgets und Schnellpanel sind verfügbar.
3. Benötigte macOS-Freigaben in den jeweiligen Tool-Einstellungen prüfen. Festplattenvollzugriff hilft beim Lesen geschützter Dateien; Fenstersteuerung und Bildschirmaufnahme werden nur für die Fensterfunktion benötigt.

**Das aktuelle Paket ist lokal mit einem Apple-Development-Zertifikat signiert, nicht mit Developer ID notarisiert.** Auf anderen Macs kann Gatekeeper den Start zunächst verweigern. Die Veröffentlichung ist kein Nachweis einer Apple-Notarisierung. Für eine reibungslose öffentliche Distribution ist ein notarisiertes Developer-ID-Release noch offen.

Die etablierte Bundle-ID `com.julianfink.LiveWallpaper` und der Datenordner `~/Library/Application Support/LiveWallpaper/` bleiben für bestehende Installationen erhalten. Neue ClamAV-Daten liegen unter `~/Library/Application Support/MacTools/ClamAV/`.

## Lokal bauen und prüfen

```sh
bash Scripts/build-native.sh
bash Scripts/package-release.sh
bash Scripts/test-scanner.sh
bash Scripts/test-scan-cache.sh
bash Scripts/test-file-browser.sh
bash Scripts/test-monitoring-persistence.sh
bash Scripts/test-security.sh
bash Scripts/test-removal-state.sh
bash Scripts/test-cursor-boundaries.sh
bash Scripts/test-app-inventory.sh
```

Xcode-Projekt: `MacTools.xcodeproj`. Der native Build erstellt Apple-Silicon- und Intel-Binaries sowie das Bildschirmschoner-Modul. Die optionale Signieridentität wird lokal gewählt; es werden keine Zertifikate oder Schlüssel ins Repository aufgenommen. ClamAV-Vendoring ist in [Vendor/README.md](Vendor/README.md) dokumentiert. Enthaltene Drittanbieter-Lizenzen werden mit dem Anwendungspaket ausgeliefert.

Prüfstand und bekannte Grenzen: [VERIFICATION.md](VERIFICATION.md).

# Prüfstand MacTools 0.2.0

Stand: 15. Oktober 2026. Lokale Nachweise sind keine Zusicherung für jede macOS-Version oder fremde App.

## Lokal bestätigt

- Nativer vollständiger Home-Disk-/Duplikatscan: 2.541.370 Dateien, ohne 250.000-Dateien-Grenze. Vier nicht lesbare Dateien ausgewiesen. Dateigrößen und Volume-Belegung getrennt; Sparse-Dateien können erheblich kleinere physische Belegung haben.
- Dateinavigation: Ordnerzeilen, Breadcrumbs, Zurück/Vorwärts, Ebene höher und Suche nativ bedient. Indexchecks mit 300.100 Dateien, Abbruch und konkurrierenden Suchanfragen bestanden.
- Duplikatindex: Medien/Dokumente einschließlich OPUS, GIF, PDF, Excel und CSV; getrennte Medien-/Gesamtzähler; Papierkorbpfade ausgeschlossen. 9.141 OPUS-Kopien korrekt gezählt. Nativ: Medienfilter 2 Gruppen, ausgeschaltet 3 einschließlich Library; Seitenauswahl 19 Kopien, gesamte Gruppe 9.140 Kopien. Eine eigene OPUS-Kopie über den Zeilen-Papierkorb entfernt: sofort 9.140 Dateien in der Gruppe, keine Wiederholung und kein neuer Scan. Größte Dateien: 1 / 1.143 → 2 / 1.143 → 1 / 1.143 mit wechselnden Einträgen.
- Bereinigung: echte wiederherstellbare Testdatei über macOS-Papierkorb entfernt. Fehlende Pfade werden aus Ergebnissen entfernt. Metadatenwechsel und Symlinks abgewiesen. Ergebnis und Löschjournal ohne neuen Inhalts-/Gesamtscan gespeichert; große Basiscache-Datei bleibt identisch.
- ClamAV: echte lokale EICAR-Erkennung, Zuordnung zu identischen Kopien und explizite Limitmeldung für eine 3-GiB-Testdatei. Vier parallele Worker prüften 1.024 einzigartige Testdateien vollständig in 7,76–9,11 Sekunden inklusive Engine-Start (lokale Testläufe). Mock-Prozesstest bestätigt überlappende Worker, Ergebnisaggregation, Live-Fortschritt, Fehlererhalt und gemeinsamen Abbruch.
- Systemmonitor: native CPU/RAM/Volume-Daten und RAM-Detailansicht gelesen; Menüleisten-Widget-Konfiguration und Persistenz geprüft.
- Videowiedergabe: echter AVPlayer-/AppDelegate-Test: 0,867 Sekunden → Pause 0,868 → Fortsetzung 1,939 → zweite Fortsetzung 2,601. Screensaver kompiliert und Video gestartet; Passwort-/Sperrverhalten verwaltet macOS.
- Apps: native Inventarliste mit 44 Apps; exakte Bundle-ID-, gemeinsame-Daten-, Symlink- und Selbst-Deinstallationsprüfungen bestanden. Keine persönliche App testweise entfernt.

- Zentraler Löschzustand: unmittelbare Aktualisierung in Disk-/Duplikat- und Virenansicht, zwei aufeinanderfolgende Löschungen, Ordner-Nachfahren, Neustart und unveränderte Basiscache-Datei im gezielten Modelltest bestätigt. Kein neuer Scan. Synthetischer Index mit 100.000 Gruppen: Aufbau 0,365 Sekunden, Änderung einer Gruppe 0,010 Sekunden. Dies misst das Modell, nicht die komplette UI-Ladezeit.

- Installation: 0.2.0 Build 4 am 15. Oktober in Programme ersetzt; vorherige App gesichert. Signaturprüfung und identisches Release-/Installationsbinary bestätigt. Native Fundliste mit gespeicherten Ergebnissen und direkten Papierkorb-Aktionen gelesen. Wechsel in den bereits geladenen Duplikat-Tab bei 213.944 Gruppen: 0,808 Sekunden einschließlich CUA-Readback; initiales Laden des gesamten gespeicherten Scans ist darin nicht enthalten.

## Grenzen und weitere Nachweise

- Der vorherige reale Home-Virenscan ist abgeschlossen und gespeichert (14. Oktober): 844.827 direkt geprüfte und 1.184.207 über identischen Inhalt geprüfte Dateien. 29 Phishing-Heuristikmeldungen, zwei EICAR-Testdateien und 99 Engine-Limits im Bericht; diese Meldungen wurden nicht automatisch gelöscht. Der Durchsatz dieses älteren seriellen Laufs belegt nicht die Leistung der separat geprüften neuen Parallelverarbeitung.
- Fenstersteuerung: ältere synthetische Hintergrund-Fokus-Varianten waren trotz einzelner erfolgreicher Tests unzuverlässig und wurden ersetzt. Die aktuelle Implementierung legt das Original auf eine eigene virtuelle Fläche und verwendet native Eingaben; der sichtbare Cursor gehört ausschließlich zur schwebenden Ansicht. Benutzer bestätigt Hover, Scrollen, Tippen und Tabs in der eigenen Chrome-Testseite. Retina-Modus nativ gelesen: 1280 × 960 Punkte / 2560 × 1920 Pixel. „Original öffnen“ löst die Ansicht und entfernt die Fläche. Zwei eigene AppKit/SwiftUI-Fenster gleichzeitig nativ angeheftet: eigene Flächen 13/14, Originalpositionen (1572,60) und (2852,60) außerhalb des physischen Bildschirms. Schließen des ersten erhält den zweiten; beide Originale kehren zur ursprünglichen AX-Position zurück, etwa (200,190) beim zweiten. Im getrennten nativen Zielprozess Texteingabe und zwei Button-Klicks gelesen. Nach den Auflösungs- und Rückkehrkorrekturen bestätigt der Benutzer die aktuelle Variante mit „jetzt ist es perfekt“. Universelle Kompatibilität mit jeder fremden App ist damit nicht belegt.
- Der Warnungsfilter ist implementiert; kein weiterer nativer Einzeltest nach dem gewünschten Teststopp.
- Veröffentlichungsscreenshots zeigen den nativen Systemmonitor und eigene Duplikat-Beispieldateien mit Fenster-Kopfleiste.
- Paket ist Apple-Development-signiert, nicht Developer-ID-notarisiert. Installation auf einem anderen Mac/Intel-Mac ist nicht praktisch geprüft.

Es werden weder persönliche Scanpfade noch das vom Benutzer bereitgestellte Bildschirmvideo als Veröffentlichungsscreenshots verwendet.

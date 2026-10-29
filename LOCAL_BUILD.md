# Lokaler Build und Anwendungspaket

```sh
python3 Scripts/prepare-clamav.py
bash Scripts/build-native.sh
bash Scripts/package-release.sh
```

Ergebnis: `build/Release/MacTools.app` und `build/Release/MacTools-universal.dmg`.

Es bleibt nur der neueste verifizierte Build erhalten. Sobald der neue Build erfolgreich geprüft ist, ältere App-Kopien, DMGs, QA-Apps und temporäre Rollback-Dateien direkt entfernen; bis dahin den letzten funktionierenden Build erhalten. Keine vollständigen App-Sicherungen bei jeder Installation sammeln. Die verbindlichen Regeln stehen in `AGENTS.md`. Statische ClamAV-Linkerarchive (`*.a`) werden nicht ins App-Paket kopiert; Lizenz- und Quellmaterial bleibt enthalten.

Beide App-Architekturen sowie die mitgelieferte ClamAV-Engine sind Universal (arm64 und x86_64). Die lokale App wird mit dem vorhandenen Apple-Development-Zertifikat signiert. Die Auswahl steht ausschließlich im ignorierten `build/code-signing-identity.txt`. Alternativ `MACTOOLS_SIGNING_IDENTITY` setzen. Ohne Auswahl wird ad-hoc signiert und vor erneut nötigen macOS-Freigaben gewarnt. Bei Updates dieselbe Identität beibehalten; der Wechsel von ad-hoc auf das Zertifikat benötigt eine einmalige neue Freigabe. Der Betrieb auf einem anderen Mac bzw. einer anderen macOS-Version muss dort zusätzlich geprüft werden. Für öffentliche Weitergabe ohne Gatekeeper-Warnungen: Developer-ID-Signierung aller enthaltenen Mach-O-Dateien, danach App/Paket notarisiert ausliefern.

Für einen aktuellen Startbestand der Virensignaturen:

```sh
mkdir -p build/clamav-database
cat > build/clamav-database/freshclam.conf <<'CONFIG'
DatabaseMirror database.clamav.net
ConnectTimeout 15
ReceiveTimeout 60
CONFIG
CVD_CERTS_DIR="$PWD/Vendor/ClamAV/etc/certs" Vendor/ClamAV/bin/freshclam \
  --config-file=build/clamav-database/freshclam.conf \
  --datadir="$PWD/build/clamav-database" \
  --cvdcertsdir="$PWD/Vendor/ClamAV/etc/certs" --stdout
mkdir -p Vendor/ClamAV/database
cp build/clamav-database/*.cvd Vendor/ClamAV/database/
cp build/clamav-database/*.sign Vendor/ClamAV/database/
```

Anschließend App/Paket neu bauen. Die App kopiert den Startbestand bei Bedarf in ihr beschreibbares Datenverzeichnis und aktualisiert ihn selbst. Eine neu vorbereitete Engine ohne Startbestand benötigt beim ersten Scan Internetzugriff.

Die offiziellen Downloads werden gegen die im Vorbereitungsskript festgelegten SHA-256-Werte geprüft. Originalquellen, Lizenztexte und Änderungen am Laufzeit-Suchpfad liegen im ausgelieferten `Contents/Resources/ClamAV/`.

Für einen stabilen Autostart MacTools nach `/Applications` kopieren und dort starten. Bestehende LiveWallpaper-Daten bleiben erhalten. Der Projektordner kann weiterhin `LiveWallpaper` heißen; App, Source-Verzeichnis, Xcode-Projekt und Scheme heißen MacTools.

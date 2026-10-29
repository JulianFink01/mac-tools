# Lokale Build-Artefakte

- Der Nutzer benötigt nur den jeweils neuesten verifizierten MacTools-Build. Bis zur erfolgreichen Verifikation eines neuen Builds den letzten funktionierenden Build erhalten.
- Sobald ein neuer Build erfolgreich verifiziert wurde, alle älteren Builds, Release-Kopien, DMGs und temporären Rollback-/Installationssicherungen direkt löschen. Nicht für spätere Chats oder eine spätere manuelle Bereinigung aufbewahren.
- Temporäre QA-Apps, große Testbestände und Benchmark-Kopien nach der Prüfung entfernen. Kleine Prüfnachweise dürfen bleiben.
- Keine dauerhafte Vollkopie der App bei jeder Installation anlegen. Für einen nötigen Rollback nur die geänderten kleinen Dateien vorübergehend sichern und nach erfolgreicher Prüfung entfernen.
- Statische Linker-Archive (`*.a`) gehören nicht in das ausgelieferte App-Paket. Benötigte Laufzeitbibliotheken, Quell-/Lizenzmaterial und private Konfiguration erhalten.
- WhatsApp und den Papierkorb nicht bereinigen oder ändern; darum kümmert sich der Nutzer selbst.

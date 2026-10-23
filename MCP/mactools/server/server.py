#!/usr/bin/python3
"""MacTools local stdio MCP. No shell commands, network listener or cloud service."""
import json
import os
from pathlib import Path
import stat
import sys
import time
import uuid

ROOT = Path(os.environ.get('MACTOOLS_BRIDGE_ROOT', str(Path.home() / 'Library/Application Support/MacTools/Bridge')))

def call_app(action, arguments):
    folder = ROOT / 'app'
    try:
        for path in [ROOT, folder, folder / 'token']:
            info = path.lstat()
            if info.st_uid != os.getuid() or stat.S_ISLNK(info.st_mode) or info.st_mode & 0o077:
                raise RuntimeError('Unsichere lokale MacTools-Verbindung.')
        token = (folder / 'token').read_text()
    except FileNotFoundError:
        raise RuntimeError('MacTools läuft nicht oder die lokale Schnittstelle ist noch nicht bereit.')
    identifier = str(uuid.uuid4())
    request = folder / (identifier + '.request')
    response = folder / (identifier + '.response')
    temporary = folder / (identifier + '.tmp')
    now = time.time()
    message = dict(id=identifier, token=token, action=action, parameters=arguments, createdAt=now, expiresAt=now + 28)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(message, stream)
    temporary.rename(request)
    try:
        while time.time() < now + 30:
            if response.exists():
                result = json.loads(response.read_text())
                if 'error' in result:
                    raise RuntimeError(result['error'])
                return result.get('result', {})
            time.sleep(0.05)
        raise RuntimeError('Keine Bestätigung von MacTools. Vor Wiederholung einer Steueraktion den Zustand prüfen.')
    finally:
        request.unlink(missing_ok=True)
        response.unlink(missing_ok=True)

def tool(name, description, properties=None, required=None, readonly=True):
    return dict(name=name, description=description, inputSchema=dict(type='object', properties=properties or {}, required=required or [], additionalProperties=False), annotations=dict(readOnlyHint=readonly, destructiveHint=not readonly, idempotentHint=readonly, openWorldHint=False))

STRING = {'type': 'string', 'minLength': 1}
TOOLS = [
    tool('mactools_overview', 'Aktuelle CPU-, RAM-, GPU-Werte und Anzahl laufender/wartender Codex-Chats.'),
    tool('mactools_open', 'Öffnet ein Werkzeug in MacTools.', {'section': dict(type='string', enum=['Alle Werkzeuge','MacTools MCP','Codex-Limit','Codex-Chats','Container','Disk & Sicherheit','Systemmonitor','Apps','Live-Hintergrund','Fenster vorn halten','Einstellungen'])}, ['section'], False),
    tool('mactools_wallpaper_pause', 'Pausiert oder startet den Live-Hintergrund.', {'paused': {'type':'boolean'}}, ['paused'], False),
    tool('codex_usage', 'Zeigt Codex-Nutzungsfenster mit verbleibendem Prozent und Rücksetzzeiten.'),
    tool('codex_list', 'Listet lokale Codex-Chats mit IDs, Status und Aktivitätszeit. Keine Chat-Inhalte.'),
    tool('codex_open', 'Öffnet ein unabhängiges Chatfenster. Mit id den vorhandenen Chat; ohne id einen neuen Entwurf.', {'id': STRING}, [], False),
    tool('codex_windows', 'Listet offene MacTools-Chatfenster mit eigener Auswahl und Pin-Zustand. Keine Nachrichteninhalte.'),
    tool('codex_window_pin', 'Hält genau dieses eigene Chatfenster im Vordergrund oder löst seinen Pin.', {'id': STRING, 'pinned': {'type': 'boolean'}}, ['id', 'pinned'], False),
    tool('codex_window_close', 'Schließt ein eigenes Chatfenster. Der Codex-Chat bleibt erhalten.', {'id': STRING}, ['id'], False),
    tool('containers_list', 'Listet lokal laufende Docker-/Podman-Container.'),
    tool('container_stop', 'Stoppt einen ausdrücklich gewählten lokalen Container. Unterbricht dessen laufende Arbeit.', {'id': STRING}, ['id'], False),
    tool('windows_list', 'Listet durch MacTools angeheftete Fenster.'),
    tool('window_unpin', 'Löst ein ausgewähltes angeheftetes Fenster.', {'id': STRING}, ['id'], False),
    tool('disk_status', 'Zeigt Scanstatus und freien/physischen Gesamtspeicher der Datenträger.'),
    tool('mactools_menu_status', 'Prüft konfigurierte und native macOS-Menüleisten-Einträge.'),
    tool('mactools_menu_restore', 'Erstellt die eingeschalteten MacTools-Menüleisten-Einträge neu. Verändert keine Auswahl oder Reihenfolge.', readonly=False),
]
ACTIONS = {'mactools_overview':'overview','mactools_open':'open','mactools_wallpaper_pause':'wallpaper_pause','mactools_menu_status':'menu_status','mactools_menu_restore':'menu_restore', **{x['name']: x['name'] for x in TOOLS if not x['name'].startswith('mactools_')}}

def validate(arguments, schema):
    if not isinstance(arguments, dict) or set(arguments) - set(schema['properties']) or set(schema['required']) - set(arguments):
        raise ValueError('Ungültige Werkzeugargumente.')
    for key, value in arguments.items():
        spec = schema['properties'][key]
        kind = spec.get('type')
        if kind == 'string' and (not isinstance(value, str) or not value): raise ValueError('Ungültiger Textparameter.')
        if kind == 'boolean' and not isinstance(value, bool): raise ValueError('Wahrheitswert erwartet.')
        if 'enum' in spec and value not in spec['enum']: raise ValueError('Ungültiger Auswahlwert.')
        if key == 'value' and (not isinstance(value, (bool, int, float))): raise ValueError('Numerischer Wert oder Wahrheitswert erwartet.')

def handle(message):
    method, params = message.get('method'), message.get('params', {})
    if method == 'initialize': return dict(protocolVersion='2024-11-05', capabilities={'tools': {'listChanged': False}}, serverInfo={'name':'mactools','version':'0.1.0'})
    if method == 'ping': return {}
    if method == 'tools/list': return {'tools': TOOLS}
    if method == 'tools/call':
        entry = next((x for x in TOOLS if x['name'] == params.get('name')), None)
        if entry is None: raise ValueError('Unbekanntes Werkzeug.')
        try:
            args = params.get('arguments', {})
            validate(args, entry['inputSchema'])
            result = call_app(ACTIONS[entry['name']], args)
            return dict(content=[dict(type='text', text=json.dumps(result, ensure_ascii=False))], isError=False)
        except Exception as error:
            return dict(content=[dict(type='text', text=str(error))], isError=True)
    raise ValueError('Unbekannte MCP-Methode.')

def main():
    for line in sys.stdin:
        message = None
        try:
            if len(line) > 1_048_576: raise ValueError('Nachricht zu groß.')
            message = json.loads(line)
            if 'id' not in message: continue
            response = dict(jsonrpc='2.0', id=message['id'], result=handle(message))
        except Exception as error:
            response = dict(jsonrpc='2.0', id=message.get('id') if isinstance(message,dict) else None, error=dict(code=-32600, message=str(error)))
        print(json.dumps(response, ensure_ascii=False), flush=True)

if __name__ == '__main__': main()

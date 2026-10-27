#!/usr/bin/python3
"""Read-only local peer: drop two owner sockets, then keep the third stream alive."""
import json, os, socket, struct, sys, time

path = sys.argv[1]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
os.chmod(path, 0o600)
server.listen(3)
try:
    for cycle in range(3):
        client, _ = server.accept()
        def read(n):
            value = b''
            while len(value) < n:
                part = client.recv(n - len(value))
                if not part:
                    raise EOFError()
                value += part
            return value
        def write(value):
            data = json.dumps(value).encode()
            client.sendall(struct.pack('<I', len(data)) + data)
        try:
            while True:
                message = json.loads(read(struct.unpack('<I', read(4))[0]))
                method = message.get('method')
                if method in ('initialize', 'thread-owner-discovery'):
                    result = dict(clientId='client-' + str(cycle)) if method == 'initialize' else {}
                    write(dict(type='response', requestId=message['requestId'], resultType='success', result=result, handledByClientId='owner-' + str(cycle)))
                elif method == 'thread-stream-following-changed':
                    write(dict(type='broadcast', method='thread-stream-state-changed', version=11, sourceClientId='owner-' + str(cycle),
                        params=dict(hostId='local', conversationId='old-selected', change=dict(type='snapshot', revision=1,
                            conversationState=dict(reconnectCycle=cycle, threadRuntimeStatus=dict(type='active'), turns=[])))))
                    if cycle < 2:
                        time.sleep(0.4)
                        break
                else:
                    raise AssertionError('Reconnect must not mutate or send input: ' + str(method))
        except EOFError:
            pass
        finally:
            client.close()
finally:
    server.close()
    if os.path.exists(path):
        os.unlink(path)

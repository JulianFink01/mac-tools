#!/usr/bin/python3
"""First owner discovery fails on a stale IPC connection; a fresh connection recovers. No prompts."""
import socket,struct,json,os,sys
path=sys.argv[1]
server=socket.socket(socket.AF_UNIX);server.bind(path);os.chmod(path,0o600);server.listen(3)
try:
 for connection_number in range(2):
  client,_=server.accept()
  def read(n):
   value=b''
   while len(value)<n:
    part=client.recv(n-len(value))
    if not part:raise EOFError()
    value+=part
   return value
  def write(value):
   data=json.dumps(value).encode();client.sendall(struct.pack('<I',len(data))+data)
  try:
   while True:
    message=json.loads(read(struct.unpack('<I',read(4))[0]));method=message.get('method')
    if method=='initialize':write(dict(type='response',requestId=message['requestId'],resultType='success',result=dict(clientId='recovery-client'),handledByClientId='owner'))
    elif method=='thread-owner-discovery':
     write(dict(type='response',requestId=message['requestId'],resultType='failure' if connection_number==0 else 'success',result=dict(supportsUntrustedAppInput=True),error='owner discovery temporarily unavailable',handledByClientId='owner'))
    elif method=='thread-stream-following-changed':
     write(dict(type='broadcast',method='thread-stream-state-changed',version=11,sourceClientId='owner',params=dict(conversationId='recover-thread',hostId='local',change=dict(type='snapshot',revision=1,conversationState=dict(threadRuntimeStatus=dict(type='active'),turns=[])))))
    else:raise AssertionError('Recovery must not send prompts or mutations: '+str(method))
  except (EOFError, BrokenPipeError, ConnectionResetError):pass
  finally:client.close()
finally:
 server.close()
 if os.path.exists(path):os.unlink(path)

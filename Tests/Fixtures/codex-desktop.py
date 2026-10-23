#!/usr/bin/python3
"""Private fake local IPC peer; never reaches a real Codex process."""
import socket, struct, json, sys, os
path=sys.argv[1]
s=socket.socket(socket.AF_UNIX);s.bind(path);os.chmod(path,0o600);s.listen(1)
c,_=s.accept()
def write(m):
 d=json.dumps(m).encode(); frame=struct.pack('<I',len(d))+d
 c.sendall(frame[:3]);c.sendall(frame[3:])
def response(m,result):write(dict(type='response',requestId=m['requestId'],resultType='success',result=result,handledByClientId='owner'))
def recv(n):
 b=b''
 while len(b)<n:
  d=c.recv(n-len(b))
  if not d:raise EOFError()
  b+=d
 return b
try:
 while True:
  m=json.loads(recv(struct.unpack('<I',recv(4))[0]))
  method=m.get('method');p=m.get('params',{})
  if method=='initialize':
   assert p['clientType']=='mactools';response(m,dict(clientId='test-client'))
  elif method=='thread-owner-discovery':response(m,dict(supportsUntrustedAppInput=True))
  elif method=='thread-stream-following-changed':
   state=dict(type='snapshot',revision=1,conversationState=dict(threadRuntimeStatus=dict(type='active'),turns=[dict(items=[dict(id='m',type='agentMessage',text='before')])]))
   if os.environ.get('MACTOOLS_TEST_LARGE_FRAME'):state['conversationState']['largeFixture']='x'*(70*1024*1024)
   write(dict(type='broadcast',method='thread-stream-state-changed',version=11,sourceClientId='owner',params=dict(conversationId='test-thread',hostId='local',change=state)))
   patch=dict(type='patches',baseRevision=1,revision=2,patches=[dict(op='replace',path=['turns',0,'items',0,'text'],value='after')])
   write(dict(type='broadcast',method='thread-stream-state-changed',version=11,sourceClientId='owner',params=dict(conversationId='test-thread',hostId='local',change=patch)))
   write(dict(type='broadcast',method='thread-queued-followups-changed',version=2,sourceClientId='owner',params=dict(conversationId='test-thread',hostId='local',messages=[dict(id='native-message',text='native queued',context=dict(prompt='native queued'),unknownFutureField=42)])))
  elif method=='thread-follower-remove-queued-message':
   assert m['version']==2 and p['messageId']=='native-message';response(m,dict(result=dict(removed=True)))
  elif method=='thread-follower-set-queued-follow-ups-state':
   assert m['version']==2 and p['state']['test-thread'][0]['unknownFutureField']==42;response(m,dict(result=dict(ok=True)))
  elif method=='thread-follower-start-turn':
   assert m['version']==2 and p['turnStart']['request']['threadId']=='test-thread'
   assert p['turnStart']['context']['inheritThreadSettings'] is True
   assert p['turnStart']['request']['input'][0]['text']=='start'
   assert p['turnStart']['request']['input'][0]['text_elements']==[]
   response(m,dict(result=dict(status='accepted')))
  elif method=='thread-follower-steer-turn':
   assert m['version']==1 and p['input'][0]['text'] in ('steer','Text mit Bild')
   assert p['input'][0]['text_elements']==[] and p['attachments']==[]
   assert p['restoreMessage']['id']==p['clientUserMessageId']
   context=p['restoreMessage']['context']
   assert context['workspaceRoots']==[] and context['commentAttachments']==[] and context['fileAttachments']==[]
   if p['input'][0]['text']=='Text mit Bild':assert p['input'][1]==dict(type='localImage',path='/tmp/fixture.png')
   response(m,dict(result=dict(status='accepted')))
  elif method=='thread-follower-load-complete-history':
   assert m['version']==1 and p['conversationId']=='test-thread'
   response(m,dict(revision=3))
  elif method=='thread-follower-command-approval-decision':
   assert m['version']==2 and p['requestId']=='approval-fixture' and p['decision']=='accept';response(m,dict(ok=True))
  elif method=='thread-follower-interrupt-turn':
   assert m['version']==4 and p['expectedTurnId']=='turn-test';response(m,dict(ok=True))
except EOFError:pass
finally:c.close();s.close();os.unlink(path)

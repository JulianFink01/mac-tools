#!/usr/bin/python3
"""Real installed CLI, isolated CODEX_HOME; never mutates the user's chats."""
import json,os,pathlib,subprocess,tempfile,uuid,time
started=time.monotonic()
with tempfile.TemporaryDirectory(prefix='mactools-codex-lifecycle-') as directory:
 home=pathlib.Path(directory); env=dict(os.environ,CODEX_HOME=str(home))
 (home/'config.toml').write_text('model = "fixture"\nmodel_provider = "fixture"\n[model_providers.fixture]\nname = "Unreachable local test provider"\nbase_url = "http://127.0.0.1:9/v1"\nwire_api = "responses"\nrequest_max_retries = 0\nstream_max_retries = 0\n')
 cli='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
 process=subprocess.Popen([cli,'app-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=env)
 sequence=0
 def request(method,params):
  global sequence
  sequence+=1; identifier=sequence
  process.stdin.write(json.dumps({'id':identifier,'method':method,'params':params})+'\n');process.stdin.flush()
  while True:
   line=process.stdout.readline(); assert line,'server closed'
   reply=json.loads(line)
   if reply.get('id')==identifier:
    assert 'error' not in reply,(method,reply.get('error'))
    return reply['result']
 try:
  request('initialize',{'clientInfo':{'name':'mactools-lifecycle-check','version':'1'},'capabilities':{'experimentalApi':True}})
  project=request('project/create',{'idempotencyKey':str(uuid.uuid4()),'name':'QA Destination','roots':[{'path':directory}]})['project']
  thread=request('thread/start',{'cwd':directory,'ephemeral':False})['thread']; identifier=thread['id']
  turn=request('turn/start',{'threadId':identifier,'input':[{'type':'text','text':'Local persistence fixture; never send to an external provider.'}]})['turn']
  try: request('turn/interrupt',{'threadId':identifier,'turnId':turn['id']})
  except AssertionError: pass
  time.sleep(0.2)
  request('thread/metadata/update',{'threadId':identifier,'projectId':project['id']})
  read=request('thread/read',{'threadId':identifier,'includeTurns':False})['thread'];assert read['projectId']==project['id']
  goal=request('thread/goal/get',{'threadId':identifier});assert goal.get('goal') is None
  request('thread/goal/set',{'threadId':identifier,'objective':'Isolated lifecycle fixture','tokenBudget':100,'status':'active','origin':'user'})
  goal=request('thread/goal/get',{'threadId':identifier})['goal'];assert goal['objective']=='Isolated lifecycle fixture' and goal['tokenBudget']==100
  request('thread/goal/set',{'threadId':identifier,'status':'paused','origin':'user'})
  assert request('thread/goal/get',{'threadId':identifier})['goal']['status']=='paused'
  request('thread/goal/clear',{'threadId':identifier});assert request('thread/goal/get',{'threadId':identifier}).get('goal') is None
  request('thread/archive',{'threadId':identifier})
  archived=request('thread/list',{'archived':True,'limit':10})['data'];assert any(t['id']==identifier for t in archived)
  request('thread/unarchive',{'threadId':identifier})
  live=request('thread/list',{'archived':False,'limit':10})['data'];assert any(t['id']==identifier for t in live)
  print('PASS: real CLI project assignment → persisted readback → goal set/read/pause/clear → archive → archived list → unarchive → active list; isolated home, unreachable loopback provider, no real inference, %.2f s'%(time.monotonic()-started))
 finally:
  process.terminate();process.wait(timeout=10)

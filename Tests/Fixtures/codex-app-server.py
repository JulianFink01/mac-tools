#!/usr/bin/python3
"""Local JSONL fixture; never contacts Codex or writes a real chat."""
import json
import sys
import time
import os
NOW = time.time()
archived_ids = set()
assigned_projects = {}


def emit(message, split=False):
    data = json.dumps(message) + '\n'
    if split:
        sys.stdout.write(data[:7])
        sys.stdout.flush()
        data = data[7:]
    sys.stdout.write(data)
    sys.stdout.flush()


def reply(message, result):
    emit({'id': message['id'], 'result': result}, split=True)


def event(method, params):
    emit({'method': method, 'params': params})


def chat(identifier):
    return {'id': identifier, 'name': 'Prüfchat äöü', 'cwd': '/tmp',
            'updatedAt': NOW - (60 if identifier == 'test-older' else 0), 'status': {'type': ('active' if os.environ.get('MACTOOLS_QA_LONG_HISTORY') and identifier=='test-old' else 'idle')}}


def turn(identifier, text):
    return {'id': identifier, 'status': 'completed', 'items': [
        {'id': identifier + '-message', 'type': 'agentMessage', 'text': text}]}


initialized = False
usage_failure = None
usage_refreshes = 0
async_question=False
async_answered=False
async_reply=None
elicitation_accepted=False
held = None
turn_counter = 0
last_started_cwd = None
native_queue = [{'id':'server-queue-1','clientUserMessageId':'client-1','input':[{'type':'text','text':'Native wartende Nachricht'},{'type':'localImage','path':'/tmp/native-context.png'}]}, {'id':'server-queue-2','input':[{'type':'text','text':'Zweite native Nachricht'}]}]
if os.environ.get('MACTOOLS_QA_LONG_HISTORY'):
    path=os.environ.get('MACTOOLS_QA_IMAGE_PATH', '')
    native_queue[0]['input']=[{'type':'text','text':'# Files mentioned by the user:\n\n## screenshot.png: '+path+'\n\n## My request:\nBitte dieses Bild prüfen\n<image name="Bild" path="'+path+'"></image>'},{'type':'localImage','path':path}]
catalog_calls = {}
ui_command_updates = 0
queue_failure = False
for line in sys.stdin:
    m = json.loads(line)
    method = m.get('method')
    p = m.get('params', {})
    if method in ('app/list','skills/list','plugin/list'):catalog_calls[method]=catalog_calls.get(method,0)+1
    if method == 'initialize':
        reply(m, {'userAgent': 'fixture'})
    elif method == 'initialized':
        initialized = True
    elif 'method' not in m and m['id']==959:
        assert m['result']=={'action':'accept','content':{}}
        elicitation_accepted=True
        event('serverRequest/resolved',{'threadId':'test-old','requestId':959})
    elif 'method' not in m:
        assert m['id'] == 900 and m['result']['decision'] == 'decline'
        event('serverRequest/resolved', {'threadId': 'test-new', 'requestId': 900})
        event('turn/completed', {'threadId': 'test-new', 'turn': {'id': tid, 'status': 'completed'}})
    elif not initialized:
        emit({'id': m['id'], 'error': {'code': -1, 'message': 'handshake missing'}})
    elif method == 'test/elicitation':
        reply(m,{})
        emit({'id':959,'method':'mcpServer/elicitation/request','params':{'threadId':'test-old','serverName':'cua_repl','mode':'form','message':'Allow Computer Use to use MacToolsPreview58?','requestedSchema':{'type':'object','properties':{}}}})
    elif method == 'test/elicitation-state':
        reply(m,{'accepted':elicitation_accepted})
    elif method == 'test/async-question':
        async_question=True
        event('turn/started',{'threadId':'test-old','turn':{'id':'async-turn','status':'inProgress'}})
        reply(m,{})
    elif method == 'test/async-answer-state':
        reply(m,{'answered':async_answered,'reply':async_reply})
    elif method == 'test/usage-failure':
        usage_failure=p.get('mode');reply(m,{})
    elif method == 'test/usage-refresh-stats':
        reply(m,{'refreshes':usage_refreshes})
    elif method == 'account/read':
        assert p['refreshToken'] is True
        usage_refreshes+=1
        if usage_failure=='once':usage_failure=None
        reply(m,{'account':{'type':'chatgpt'},'requiresOpenaiAuth':True})
    elif method == 'account/rateLimits/read' and usage_failure:
        emit({'id':m['id'],'error':{'code':-1,'message':'401 Unauthorized token_expired' if usage_failure!='server' else '503 Service Unavailable'}})
    elif method == 'account/rateLimits/read':
        reply(m, {'rateLimits':{}, 'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':30,'windowDurationMins':300,'resetsAt':int(time.time())+3600},'secondary':{'usedPercent':45,'windowDurationMins':10080,'resetsAt':int(time.time())+86400}}}})
    elif method == 'test/catalog-stats':
        reply(m,catalog_calls)
    elif method == 'model/list':
        reply(m, {'data': [{'model':'fixture-model','displayName':'Prüfmodell','isDefault':True,'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':'low'},{'reasoningEffort':'high'}],'serviceTiers':[]}], 'nextCursor':None})
    elif method == 'skills/list':
        reply(m, {'data':[{'cwd':'/tmp','skills':[{'name':('data-analytics:product-business-analysis' if os.environ.get('MACTOOLS_QA_LONG_HISTORY') else 'Prüfskill'),'description':'Analyze product or business data to support a decision.','path':'/tmp/SKILL.md','enabled':True}]}]})
    elif method == 'plugin/list':
        reply(m, {'marketplaces':[{'plugins':[{'id':'private@created-by-me-remote','name':'private','interface':{'displayName':'Eigenes MCP','shortDescription':'Eigene Werkzeuge'},'installed':True,'enabled':True}]}]} if p.get('marketplaceKinds') else {'marketplaces':[{'plugins':[{'id':'fixture@local','name':'Prüfplugin','installed':True,'enabled':True}]}]})
    elif method == 'app/list':
        if os.environ.get('MACTOOLS_TEST_SLOW_CATALOG'):time.sleep(0.3)
        reply(m, {'data':[{'id':'fixture-app-2','name':'AlphaTraderMCP','description':'AlphaTrader Werkzeuge','isAccessible':True,'isEnabled':True}], 'nextCursor':None} if p.get('cursor') == 'apps-2' else {'data':[{'id':'fixture-app','name':'Prüfapp','isAccessible':True,'isEnabled':True}, {'id':'unlinked','name':'Nicht verbunden','isAccessible':False}], 'nextCursor':'apps-2'})
    elif method == 'fuzzyFileSearch':
        if os.environ.get('MACTOOLS_QA_LONG_HISTORY') and p.get('query')=='test-scroll':event('item/completed',{'threadId':'test-old','item':{'id':'new-scroll-live','type':'agentMessage','text':'NEUE LIVE-NACHRICHT – darf beim Nachlesen nicht springen'}})
        reply(m, {'files':[{'file_name':'test.txt','path':'test.txt','root':'/tmp'}]})
    elif method == 'project/list':
        reply(m, {'data':[{'id':'project-fixture','name':'Zielprojekt','roots':[{'path':'/tmp/destination'}]}], 'nextCursor':None})
    elif method == 'thread/metadata/update':
        metadata_attempts = globals().get('metadata_attempts', 0) + 1
        if os.environ.get('MACTOOLS_TEST_PROJECT_STARTUP_FAILURE') and metadata_attempts <= 2:
            emit({'id':m['id'],'error':{'code':-1,'message':'failed to read session metadata: rollout is empty'}})
            continue
        assigned_projects[p['threadId']] = p['projectId']; reply(m, {})
    elif method == 'thread/resume':
        assert p['threadId']=='test-old'
        reply(m,{'thread':chat('test-old')})
    elif method == 'thread/read':
        value = chat(p['threadId']); value['projectId'] = assigned_projects.get(p['threadId']); reply(m, {'thread':value})
    elif method in ('thread/archive', 'thread/unarchive'):
        if method == 'thread/archive': archived_ids.add(p['threadId'])
        else: archived_ids.discard(p['threadId'])
        reply(m, {})
    elif method == 'thread/list':
        if p.get('ancestorThreadId'):
            assert p['ancestorThreadId'] in ['test-old', 'test-second-root', 'test-third-root']
            child = chat('test-agent-archived' if p.get('archived') else 'test-agent')
            child.update(parentThreadId='test-old', agentNickname='Prüfagent', agentRole='explorer')
            nested = chat('test-nested'); nested['parentThreadId'] = 'test-agent'
            unrelated = chat('test-unrelated'); unrelated['parentThreadId'] = 'different-root'
            reply(m, {'data': ([child] if p.get('archived') else [child, nested]) if p['ancestorThreadId'] == 'test-old' else [unrelated], 'nextCursor': None})
        else:
            assert 'appServer' in p['sourceKinds']
            assert p['sortDirection'] == 'desc' and p['sortKey'] == 'updated_at'
            old = chat('test-outdated'); old['updatedAt'] = time.time() - 90000
            values = [chat('test-older'), old] if p.get('cursor') else [chat('test-old')]
            values = [v for v in values if (v['id'] in archived_ids) == bool(p.get('archived'))]
            for v in values: v['projectId'] = assigned_projects.get(v['id'])
            reply(m, {'data': values,
                      'nextCursor': None if p.get('cursor') else 'next-list'})
    elif method == 'thread/queue/list':
        if queue_failure: emit({'id':m['id'],'error':{'code':-1,'message':'temporary queue failure'}})
        else: reply(m, {'data':native_queue,'nextCursor':None})
    elif method == 'thread/queue/reorder':
        assert set(p['queuedSubmissionIds'])==set(x['id'] for x in native_queue)
        by_id={x['id']:x for x in native_queue};native_queue=[by_id[x] for x in p['queuedSubmissionIds']];reply(m,{})
    elif method == 'thread/queue/update':
        target=next(x for x in native_queue if x['id']==p['queuedSubmissionId']);target['input']=p['input'];reply(m, {'queuedSubmission':target})
    elif method == 'thread/queue/delete':
        old=len(native_queue);native_queue=[x for x in native_queue if x['id']!=p['queuedSubmissionId']];reply(m, {'deleted':len(native_queue)!=old})
    elif method == 'test/ui-command-update':
        assert os.environ.get('MACTOOLS_QA_LONG_HISTORY')
        ui_command_updates += 1
        event('item/completed', {'threadId':'test-old','item':{'id':'qa-finished-command','type':'commandExecution','command':'printf "Fertiger Testbefehl\\n"','cwd':'/tmp','status':'completed','durationMs':1500,'exitCode':0,'aggregatedOutput':'AKTUALISIERTE AUSGABE '+str(ui_command_updates)}})
        event('item/commandExecution/outputDelta',{'threadId':'test-old','itemId':'qa-running-command','delta':'Live-Ausgabe '+str(ui_command_updates)+'\n'})
        reply(m,{})
    elif method == 'test/activity':
        event('item/started',{'threadId':'test-new','item':{'id':'activity-fixture','type':'commandExecution','command':'echo fixture','cwd':'/tmp','status':'inProgress'}})
        event('item/commandExecution/outputDelta',{'threadId':'test-new','itemId':'activity-fixture','turnId':'fixture-turn','delta':'Ausgabe äöü'})
        event('item/completed',{'threadId':'test-new','item':{'id':'activity-fixture','type':'commandExecution','command':'echo fixture','cwd':'/tmp','status':'completed','durationMs':1500,'exitCode':0,'aggregatedOutput':'Ausgabe äöü'}})
        reply(m,{})
    elif method == 'test/queue-failure':
        queue_failure = p['enabled'];reply(m,{})
    elif method == 'test/queue-empty':
        native_queue=[];reply(m,{})
    elif method == 'thread/turns/list':
        if os.environ.get('MACTOOLS_QA_MULTI_HISTORY') and p.get('cursor'):
            time.sleep(0.6)
            if p['cursor'] == 'next-turns':
                reply(m, {'data':[{'id':'older-collapsed','items':[{'id':'older-command-'+str(i),'type':'commandExecution','command':'echo fixture','status':'completed','exitCode':0} for i in range(80)]}], 'nextCursor':'older-second'})
            else:
                reply(m, {'data':[turn('oldest-marker','VERLAUF_SEITE_2 – automatisch nachgeladen')], 'nextCursor':None})
            continue
        image_item={'id':'image-message','type':'userMessage','content':[{'type':'localImage','path':os.environ.get('MACTOOLS_QA_IMAGE_PATH','')}] }
        recent=turn('recent','Neuere Antwort')
        if os.environ.get('MACTOOLS_QA_LONG_HISTORY'):
            recent['items']=[{'id':'long-'+str(i),'type':'agentMessage','text':'Historie Nachricht '+str(i)+' – alter Verlauf. '*8} for i in range(180)]+[{'id':'final-qa','type':'agentMessage','text':'ENDE DES PRUEFCHATS – neueste Nachricht'}]
        if os.environ.get('MACTOOLS_QA_MULTI_HISTORY'):
            recent['items'][:0]=[{'id':'initial-command-'+str(i),'type':'commandExecution','command':'echo fixture','status':'completed','exitCode':0} for i in range(8)]
        if os.environ.get('MACTOOLS_QA_LONG_HISTORY'):
            recent['items'][-1:-1]=[
                {'id':'qa-finished-command','type':'commandExecution','command':'printf "Fertiger Testbefehl\\n"','cwd':'/tmp','status':'completed','durationMs':1500,'exitCode':0,'aggregatedOutput':'Fertiger Testbefehl\n'},
                {'id':'qa-running-command','type':'commandExecution','command':'sleep 120 # reine UI-Fixture, wird nicht ausgeführt','cwd':'/tmp','status':'inProgress','processId':'fixture-42','aggregatedOutput':'Fortschritt aus der Fixture …\n'}]
            recent['commandExecutionStartedAtMsById']={'qa-running-command':int((NOW-87)*1000)}
        if os.environ.get('MACTOOLS_QA_IMAGE_PATH'):recent['items'].insert(0,image_item)
        if async_question:
            recent['status']='inProgress'
            recent['items'].append({'id':'async-item','type':'agentMessage','text':'Bitte wähle eine Option.','questions':[{'title':'Welche Ansicht soll geöffnet werden?','options':['Übersicht','Details']}]})
            if async_reply:recent['items'].append({'id':'async-answer','type':'userMessage','content':[{'type':'text','text':async_reply}]})
        reply(m, {'data': [turn('old', 'Ältere Antwort')] if p.get('cursor') else [recent],
                  'nextCursor': None if p.get('cursor') else 'next-turns'})
    elif method == 'thread/start':
        assert p['cwd'] in ['/tmp', '/tmp/destination']
        last_started_cwd = p['cwd']
        if p.get('projectId'): assigned_projects['test-new'] = p['projectId']
        value = chat('test-new'); value['projectId'] = assigned_projects.get('test-new')
        reply(m, {'thread': value})
        event('thread/started', {'thread': value})
    elif method == 'turn/start':
        turn_counter += 1
        tid = 'turn-test-' + str(turn_counter)
        reply(m, {'turn': {'id': tid, 'status': 'inProgress'}})
        if p['input'][0]['text'] == 'Optionscheck':
            assert p['model']=='fixture-model' and p['effort']=='high'
            assert p['approvalPolicy']=='untrusted' and p['sandboxPolicy']['type']=='workspaceWrite'
            assert p['collaborationMode']['mode']=='plan'
            assert p['input'][1]['type']=='skill' and p['input'][1]['path']=='/tmp/SKILL.md'
            event('turn/completed', {'threadId':'test-new','turn':{'id':tid,'status':'completed'}})
            continue
        if p['input'][0]['text'] == 'Sofort':
            event('turn/started', {'threadId': 'test-new', 'turn': {'id': tid}})
            event('turn/completed', {'threadId': 'test-new', 'turn': {'id': tid, 'status': 'completed'}})
            continue
        event('turn/started', {'threadId': 'test-new', 'turn': {'id': tid}})
        event('item/started', {'threadId': 'test-new', 'item': {
            'type': 'userMessage', 'id': 'user-test', 'content': p['input']}})
        event('item/agentMessage/delta', {'threadId': 'test-new', 'itemId': 'reply-test', 'delta': 'Hallo äöü'})
        event('item/completed', {'threadId': 'test-new', 'item': {
            'type': 'agentMessage', 'id': 'reply-test', 'text': 'Hallo äöü!'}})
        emit({'id': 900, 'method': 'item/commandExecution/requestApproval',
              'params': {'threadId': 'test-new', 'turnId': tid, 'command': 'fixture-only'}})
    elif method == 'turn/steer' and p['input'][0]['text'].startswith('<send_user_message_question_reply>'):
        async_reply=p['input'][0]['text']
        answers=json.loads(async_reply[len('<send_user_message_question_reply>'):-len('</send_user_message_question_reply>')])
        assert p['threadId']=='test-old' and json.loads(answers[0]['questionItemId'])==['request_user_input_async','async-item',0]
        assert answers[0]['answer']=='Details'
        async_answered=True
        reply(m,{'turnId':p['expectedTurnId']})
        event('item/completed',{'threadId':'test-old','item':{'id':'async-answer','type':'userMessage','content':p['input']}})
    elif method == 'turn/steer':
        assert p['threadId'] == 'test-new' and p['input'][0]['text'] == 'Steuerung'
        reply(m, {'turnId': p['expectedTurnId']})
    elif method == 'test/start-state':
        reply(m, {'cwd': last_started_cwd, 'projectId': assigned_projects.get('test-new'), 'metadataAttempts':globals().get('metadata_attempts',0), 'turns':turn_counter})
    elif method == 'test/complete-turn':
        event('turn/completed', {'threadId':'test-new','turn':{'id':'turn-test-'+str(turn_counter),'status':'completed'}})
        reply(m,{})
    elif method == 'test/first':
        held = m
    elif method == 'test/second':
        reply(m, {'value': 2})
        reply(held, {'value': 1})
    elif method == 'test/exit':
        sys.exit(0)
    else:
        emit({'id': m['id'], 'error': {'code': -32601, 'message': 'fixture rejection'}})

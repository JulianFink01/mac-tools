#!/usr/bin/python3
import sys,json,os
kind=os.environ['MACTOOLS_MCP_FIXTURE_KIND'];server='mactools_private_'+kind;failed=False;healthy_strategies=False;near_limit=False;missing_capacity=False
for line in sys.stdin:
 m=json.loads(line);method=m.get('method');p=m.get('params',{})
 if 'id' not in m:continue
 result={}
 if method=='initialize':result={'userAgent':'fixture'}
 elif method=='thread/start':
  assert p['ephemeral'] is True and p['sandbox']=='read-only' and p['approvalPolicy']=='never'
  result={'thread':{'id':'private-fixture'}}
 elif method=='mcpServerStatus/list':
  assert p['threadId']=='private-fixture' and p['serverName']==server
  result={'data':[{'name':server,'authStatus':'bearerToken'}],'nextCursor':None}
 elif method=='mcpServer/tool/call':
  assert p['threadId']=='private-fixture' and p['server']==server
  assert p['tool'] in (['get_system_health','get_platform_health'] if kind=='infrapilot' else ['get_operational_health','get_leadership_status','get_database_storage','list_workspaces','list_shadow_runtimes','list_portfolio_deployments','list_paper_runtimes'])
  data={'kubernetes':{'pods':{'checked':True,'total':20,'ready':20,'pending':0,'failed':0,'unknown':0}},'machine':{'cpu':{'percent':7.8},'memory':{'percent':55.2},'storage':{'percent':61.3,'used':76137547264,'total':124193909760},'hostname':'fixture-node','uptimeSeconds':14425721,'loadAverage':[0.12,0.13,0.23],'diskThroughput':{'readBytesPerSecond':8765,'writeBytesPerSecond':471890}}} if kind=='infrapilot' else {'liveness':'UP','trafficReady':True,'runtimeReady':True}
  if p['tool']=='get_platform_health':data={'version':'2.0.94-alpha.1','clusterMode':'in-cluster'}
  elif p['tool']=='get_leadership_status':data={'state':'ACTIVE','trafficReady':True,'runtimeReady':True}
  elif p['tool']=='get_database_storage':data={'usedBytes':18000000000 if near_limit else 9179633331,'capacityBytes':19327352832}
  elif p['tool']=='list_workspaces':data={'workspaces':[{'workspaceId':'fixture-workspace'}]}
  elif p['tool']=='list_portfolio_deployments':
   assert p['arguments']=={'workspaceId':'fixture-workspace','limit':100}
   data={'portfolioDeployments':[{'executionMode':'PAPER','allocations':[{'strategyDeploymentId':'paper-strategy'}]}]}
  elif p['tool']=='list_shadow_runtimes':
   assert p['arguments']=={'workspaceId':'fixture-workspace','limit':100}
   data={'runtimes':[{'runtimeId':'good','strategyDeploymentId':'good-strategy','observedState':'RUNNING','desiredState':'RUNNING','activityState':'PROCESSING'},{'runtimeId':'bad','strategyDeploymentId':'bad-strategy','observedState':'RUNNING' if healthy_strategies else 'DEGRADED','desiredState':'RUNNING','activityState':'PROCESSING' if healthy_strategies else 'HEARTBEAT_MISSING'}]}
  elif p['tool']=='list_paper_runtimes':
   assert p['arguments']=={'workspaceId':'fixture-workspace','strategyDeploymentId':'paper-strategy','limit':100}
   data={'runtimes':[{'runtimeId':'paused','strategyDeploymentId':'paper-strategy','observedState':'PAUSED','desiredState':'PAUSED'}]}
  if p['tool']=='get_database_storage' and missing_capacity:data.pop('capacityBytes')
  result={'content':[],'isError':failed,'structuredContent':{'status':200,'result':data} if kind=='infrapilot' else {'data':data}}
 elif method=='test/healthyStrategies':healthy_strategies=True
 elif method=='test/nearLimit':near_limit=p['enabled']
 elif method=='test/missingCapacity':missing_capacity=p['enabled']
 elif method=='test/failHealth':failed=True
 elif method=='mcpServer/oauth/login':result={'authorizationUrl':'http://unsafe.invalid/login','loginId':'test-login'}
 else:raise AssertionError(method)
 print(json.dumps({'id':m['id'],'result':result}),flush=True)

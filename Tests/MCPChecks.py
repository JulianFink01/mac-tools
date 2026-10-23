"""Real stdio MCP -> disposable private app bridge. Never controls user devices."""
import json, os, pathlib, subprocess, tempfile, threading, time
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='mactools-mcp-') as temporary:
    bridge = pathlib.Path(temporary); bridge.chmod(0o700)
    app = bridge/'app'; app.mkdir(mode=0o700)
    token=app/'token'; token.write_text('fixture-token-'*4); token.chmod(0o600)
    process = subprocess.Popen(['/usr/bin/python3',str(root/'MCP/mactools/server/server.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,'MACTOOLS_BRIDGE_ROOT': str(bridge)})
    calls=[]; stopped=threading.Event()
    def serve():
        while not stopped.wait(0.01):
            for request in app.glob('*.request'):
                value=json.loads(request.read_text()); assert value['token']==token.read_text()
                assert value['expiresAt']>time.time() and value['expiresAt']-value['createdAt']<=30
                calls.append(value)
                result={'cpuPercent':12.5} if value['action']=='overview' else {'items':[]}
                response=request.with_suffix('.response'); response.write_text(json.dumps({'result':result})); response.chmod(0o600); request.unlink(missing_ok=True)
    thread=threading.Thread(target=serve,daemon=True);thread.start()
    def rpc(method,params=None):
        process.stdin.write(json.dumps({'jsonrpc':'2.0','id':len(calls)+1,'method':method,'params':params or {}})+'\n');process.stdin.flush()
        return json.loads(process.stdout.readline())['result']
    try:
        assert rpc('initialize')['serverInfo']['name']=='mactools'
        tools=rpc('tools/list')['tools']; assert len(tools)==16 and all(x['inputSchema']['additionalProperties'] is False for x in tools)
        overview=rpc('tools/call',{'name':'mactools_overview','arguments':{}}); assert not overview['isError'] and json.loads(overview['content'][0]['text'])['cpuPercent']==12.5
        result=rpc('tools/call',{'name':'mactools_menu_status','arguments':{}}); assert not result['isError'] and calls[-1]['action']=='menu_status'
        result=rpc('tools/call',{'name':'codex_open','arguments':{}}); assert not result['isError'] and calls[-1]['action']=='codex_open'
        result=rpc('tools/call',{'name':'codex_window_pin','arguments':{'id':'fixture-window','pinned':True}}); assert not result['isError'] and calls[-1]['parameters']=={'id':'fixture-window','pinned':True}
        count=len(calls)
        invalid=rpc('tools/call',{'name':'mactools_open','arguments':{'section':'invalid-section'}}); assert invalid['isError'] and len(calls)==count
        token.chmod(0o644)
        insecure=rpc('tools/call',{'name':'mactools_overview','arguments':{}}); assert insecure['isError'] and len(calls)==count
        print('PASS: stdio initialize/discovery, real bridge roundtrip, menu forwarding, validation and private-token permissions')
    finally:
        stopped.set();thread.join();process.terminate();process.wait(timeout=3)

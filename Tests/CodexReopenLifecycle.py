#!/usr/bin/python3
"""Verify the installed CLI across two processes, using only an unreachable local test provider."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

CLI = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'

class Peer:
    def __init__(self, home):
        self.process = subprocess.Popen([CLI, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, env=dict(os.environ, CODEX_HOME=str(home)))
        self.messages = queue.Queue()
        self.sequence = 0
        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)
        threading.Thread(target=read, daemon=True).start()
        self.request('initialize', dict(clientInfo=dict(name='mactools-reopen-check', version='1'), capabilities=dict(experimentalApi=True)))
    def request(self, method, params):
        self.sequence += 1
        identifier = self.sequence
        self.process.stdin.write(json.dumps(dict(id=identifier, method=method, params=params)) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while True:
            reply = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            assert reply is not None, 'CLI closed'
            if reply.get('id') == identifier:
                return reply
            assert time.monotonic() < deadline, method
    def result(self, method, params):
        reply = self.request(method, params)
        assert 'error' not in reply, (method, reply.get('error'))
        return reply['result']
    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)

with tempfile.TemporaryDirectory(prefix='mactools-reopen-') as directory:
    home = Path(directory)
    (home / 'config.toml').write_text('model="fixture"\nmodel_provider="fixture"\n[model_providers.fixture]\nname="Local-only unavailable fixture"\nbase_url="http://127.0.0.1:9/v1"\nwire_api="responses"\nrequest_max_retries=0\nstream_max_retries=0\n')
    first = Peer(home)
    try:
        thread = first.result('thread/start', dict(cwd=directory, ephemeral=False, historyMode='paginated'))['thread']['id']
        started = first.result('turn/start', dict(threadId=thread, input=[dict(type='text', text='Local-only reopen fixture')]))['turn']
        first.request('turn/interrupt', dict(threadId=thread, turnId=started['id']))
        for _ in range(100):
            page = first.result('thread/read', dict(threadId=thread, includeTurns=True))
            if page.get('thread', {}).get('turns'):
                break
            time.sleep(0.02)
        assert page.get('thread', {}).get('turns'), 'Initial turn was not persisted'
    finally:
        first.close()
    second = Peer(home)
    try:
        second.result('thread/read', dict(threadId=thread, includeTurns=False))
        page = second.result('thread/read', dict(threadId=thread, includeTurns=True))
        assert page.get('thread', {}).get('turns'), 'Canonical history must be readable before runtime resume'
        inputs = [dict(type='text', text='Follow-up in the same local fixture')]
        rejected = second.request('turn/start', dict(threadId=thread, input=inputs))
        assert rejected.get('error', {}).get('message') == 'thread not found: ' + thread, rejected
        resumed = second.result('thread/resume', dict(threadId=thread))['thread']
        assert resumed['id'] == thread
        recovered = second.result('turn/start', dict(threadId=thread, input=inputs))['turn']
        assert recovered.get('id')
        second.request('turn/interrupt', dict(threadId=thread, turnId=recovered['id']))
    finally:
        second.close()
    print('PASS: real installed CLI reproduces thread-not-found after process restart; canonical history remains readable; resume restores the same ID and accepts one follow-up; isolated CODEX_HOME and no external provider')

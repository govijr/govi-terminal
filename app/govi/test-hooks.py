#!/usr/bin/env python3
"""Check the shipped agent hook helper without launching an agent or a model."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import uuid

helper = Path(__file__).resolve().parent / 'Govi/Tools/govi-notify'
with tempfile.TemporaryDirectory(prefix='govi-h-', dir='/private/tmp') as temporary:
    path = str(Path(temporary) / 's')
    server = socket.socket(socket.AF_UNIX)
    server.bind(path); server.listen(8); server.settimeout(3)
    received = []
    def collect():
        for _ in range(5):
            peer, _ = server.accept()
            with peer:
                data = b''
                while b'\n' not in data:
                    data += peer.recv(4096)
                kind, sequence, payload = data.decode().strip().split('\t', 2)
                assert kind == 'A' and sequence == '0'
                received.append(json.loads(payload))
    thread = threading.Thread(target=collect)
    thread.start()
    session = str(uuid.uuid4())
    env = dict(os.environ, GOVI_SESSION_ID=session, GOVI_SUGGEST_SOCKET=path)
    label = 'Fix "login" \\ path $literal;\nsecond line'
    for state in ['working', 'needsInput', 'done', 'error', 'idle']:
        result = subprocess.run(['/bin/zsh', '-f', str(helper), state, label], env=env, input='PRIVATE PROMPT MUST NOT BE READ', text=True, capture_output=True, timeout=3)
        assert result.returncode == 0 and result.stdout == '' and result.stderr == ''
    thread.join(timeout=5)
    assert not thread.is_alive() and len(received) == 5
    assert [item['state'] for item in received] == ['working', 'needsInput', 'done', 'error', 'idle']
    assert all(item['id'] == session and item['label'] == label.replace('\n', ' ') for item in received)
    for state, test_env in [('invalid', env), ('done', dict(env, GOVI_SESSION_ID='bad"id')), ('done', dict(env, GOVI_SUGGEST_SOCKET=path + '-missing'))]:
        result = subprocess.run(['/bin/zsh', '-f', str(helper), state], env=test_env, text=True, capture_output=True, timeout=3)
        assert result.returncode == 0 and result.stdout == '' and result.stderr == ''
    server.close()
print('Passed hook transport, all five states, JSON escaping, ignored stdin, silent failure, invalid events and missing-app behavior.')

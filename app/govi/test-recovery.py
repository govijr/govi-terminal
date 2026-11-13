#!/usr/bin/env python3
"""Exercise the production reconnect script using only disposable test sessions.

Never stops/restarts the helper server or reads the user's existing sessions.
"""
import json
import os
from pathlib import Path
import pty
import queue
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import uuid

root = Path(__file__).resolve().parent.parent
out = root / '.build/recovery-tests'
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['swiftc', '-module-cache-path', str(out / 'modules'), str(root / 'macos/Sources/Features/Terminal/GoviWorkspaceModels.swift'), str(root / 'macos/Sources/Features/Terminal/GoviModModels.swift'), str(root / 'macos/Sources/Features/Terminal/GoviProcess.swift'), str(root / 'macos/Sources/Features/Terminal/GoviRemoteModels.swift'), str(root / 'govi/test_recovery.swift'), '-o', str(out / 'fixture')], check=True)
hc = shutil.which('hc') or str(Path.home() / '.local/bin/hc')
assert Path(hc).is_file(), 'Install herdr-core to run the live reconnect regression.'
packets = queue.Queue()
names, programs, descriptors = [], [], []

def q(value):
    return "'" + value.replace("'", "'\\''") + "'"

def command(*args):
    return subprocess.run([hc, *args], text=True, capture_output=True, timeout=8)

def receive(server):
    while True:
        try:
            peer, _ = server.accept()
        except OSError:
            return
        with peer:
            line = b''
            while b'\n' not in line:
                part = peer.recv(8192)
                if not part:
                    break
                line += part
            if line:
                kind, _, value = line.decode().strip().split('\t', 2)
                assert kind == 'P'
                packets.put(json.loads(value))

def launch(fixture, destination):
    destination.write_text(json.dumps(fixture))
    script = subprocess.check_output([str(out / 'fixture'), str(destination)], text=True)
    master, slave = pty.openpty()
    process = subprocess.Popen(['/bin/sh', '-c', script], stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    programs.append(process); descriptors.append(master)
    return process, master

def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=4)

try:
    with tempfile.TemporaryDirectory(prefix='govi-r-', dir='/private/tmp') as temporary:
        temporary = Path(temporary)
        cwd = temporary / "folder with 'quotes' and $literal"
        cwd.mkdir()
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(temporary / 's')); server.listen(8)
        threading.Thread(target=receive, args=(server,), daemon=True).start()
        name = uuid.uuid4().hex
        names.append(name)
        fixture = dict(hc=hc, name=name, id=str(uuid.uuid4()), directory=str(cwd), socket=str(temporary / 's'), restoring=False,
                       program='/bin/sh -c ' + q("printf 'GOVI_RECONNECT_SENTINEL\\n'; while :; do sleep 1; done"))
        first, _ = launch(fixture, temporary / 'fixture.json')
        packet = packets.get(timeout=12)
        assert packet['live'] and not packet['recovered']
        stop(first)  # Abruptly lose the entire attach process group.
        reading = command('get', '--json', name)
        assert reading.returncode == 0 and '"live"' in reading.stdout
        fixture['restoring'] = True
        second, master = launch(fixture, temporary / 'fixture.json')
        packet = packets.get(timeout=12)
        assert packet['live'] and not packet['recovered'], 'An existing program must reattach.'
        content = b''
        deadline = time.monotonic() + 8
        while b'GOVI_RECONNECT_SENTINEL' not in content and time.monotonic() < deadline:
            if select.select([master], [], [], 0.2)[0]:
                content += os.read(master, 65536)
        assert b'GOVI_RECONNECT_SENTINEL' in content, 'Reattach should replay previous output.'
        stop(second)
        names.append(uuid.uuid4().hex)
        fixture.update(name=names[-1], program='/bin/sh -l', restoring=True)
        fresh, _ = launch(fixture, temporary / 'fixture.json')
        packet = packets.get(timeout=12)
        assert packet['live'] and packet['recovered'], 'A missing saved program needs a recovery notice.'
        stop(fresh)
        fixture.update(hc='/nonexistent/govi-hc', name=uuid.uuid4().hex)
        fallback, _ = launch(fixture, temporary / 'fixture.json')
        packet = packets.get(timeout=12)
        assert not packet['live'] and packet['recovered'], 'A fallback shell must never count as persistent.'
        stop(fallback)
        server.close()
finally:
    for process in programs:
        stop(process)
    for name in names:
        command('kill', name); command('rm', name)
    for descriptor in descriptors:
        os.close(descriptor)
print('Passed abrupt attach loss, live reattach/output replay, missing-session recovery, helper failure and literal paths; disposable sessions removed.')

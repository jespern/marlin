#!/usr/bin/env python3
"""Real isolated daemon/TUI handoff test; emulates Kitty terminal responses.
Usage: python3 scripts/mk64_tui_smoke.py zig-out/bin/marlin [bundle-or-ROM]
No prompts are sent to a model. State and socket live in a temporary directory.
"""
import shutil, re
from pathlib import Path
import os, sys, pty, select, time, subprocess, tempfile, signal, struct, fcntl, termios
binary = os.path.abspath(sys.argv[1])
asset = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
with tempfile.TemporaryDirectory(prefix='mk-tui-') as state:
 env = os.environ.copy()
 for name in ('HOME','XDG_STATE_HOME','XDG_CONFIG_HOME','XDG_DATA_HOME'):
  env[name] = state
 env['XDG_CACHE_HOME'] = state + '/cache'
 if not asset:
  root = Path(__file__).resolve().parent.parent
  digest = re.search(r'digest_hex = "([a-f0-9]+)"', (root / 'src/mk64/cache.zig').read_text()).group(1)
  fixture = root / 'assets/mk64' / (digest + '.mkassets')
  dest = Path(env['XDG_CACHE_HOME']) / 'marlin/mk64' / fixture.name
  dest.parent.mkdir(parents=True)
  shutil.copyfile(fixture, dest)
 env.pop('MARLIN_MK64_ROM', None)
 env.pop('MARLIN_MK64_ASSETS', None)
 if asset: env['MARLIN_MK64_ASSETS'] = asset
 env.update(TERM='xterm-kitty', MARLIN_SOCKET=state+'/daemon.sock',
            MARLIN_DAEMON_PGID='inherit', MARLIN_NETWORK_BLOCKLISTS='')
 env.pop('MARLIN_REMOTE', None)
 os.makedirs(state+'/marlin', exist_ok=True)
 with open(state+'/marlin/config.toml','w') as config:
  config.write('[setup]\ncompleted = true\n[model]\ndefault = \"local/testing\"\n')
 with open(state+'/daemon.log', 'wb') as log:
  daemon = subprocess.Popen([binary,'daemon'],env=env,stdout=log,stderr=log,start_new_session=True)
  pid = fd = None
  try:
   deadline=time.monotonic()+10
   while not os.path.exists(env['MARLIN_SOCKET']):
    if daemon.poll() is not None or time.monotonic()>deadline: raise RuntimeError('daemon did not start')
    time.sleep(.05)
   session=state+'/session'
   pid,fd=pty.fork()
   if pid==0: os.execve(binary,[binary,'attach','--session-file',session],env)
   fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,800,600))
   output=bytearray(); pending=b''
   def pump(seconds):
    global pending
    until=time.monotonic()+seconds
    start=len(output)
    while time.monotonic()<until:
     if not select.select([fd],[],[],.02)[0]: continue
     chunk=os.read(fd,262144)
     if not chunk: raise RuntimeError('TUI exited unexpectedly')
     output.extend(chunk)
     data=pending+chunk
     if b'\x1b[5n' in data: os.write(fd,b'\x1b[0n')
     if b'\x1b[c' in data:
      os.write(fd,b'\x1b[?31u\x1b_Gi=1;OK\x1b\\\x1b[?1;2c')
     pending=data[-3:]
    return bytes(output[start:])
   def command(text):
    os.write(fd,b'\x1b[200~'+text.encode()+b'\x1b[201~\r')
   pump(2)
   original=open(session).read()
   for text,mode in [('!mk', b'MANUAL |'),('/screensaver mariokart', b'AUTO |')]:
    command(text)
    data=pump(2)
    assert b'a=T,f=24' in data,(text,data[-1000:])
    if text=='!mk':
     os.write(fd,b'\x1b[104;1:1u\x1b[104;1:3u')
    data=pump(3)
    assert mode in data,(text,data[-1000:])
    os.write(fd,b'\x1b[27;1:1u')
    pump(2)
    assert open(session).read()==original,'returned to a different session'
    print(text.decode() if isinstance(text,bytes) else text, 'launched', mode.decode(), 'and returned to', original.strip())
   command('/detach')
  finally:
   if pid:
    try: os.kill(pid,signal.SIGTERM)
    except ProcessLookupError: pass
    os.waitpid(pid,0)
   if fd is not None: os.close(fd)
   if daemon.poll() is None: os.killpg(daemon.pid,signal.SIGTERM)
   try: daemon.wait(timeout=5)
   except subprocess.TimeoutExpired:
    os.killpg(daemon.pid,signal.SIGKILL); daemon.wait()

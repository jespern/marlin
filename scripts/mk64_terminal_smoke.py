#!/usr/bin/env python3
"""PTY transport regression: demo charge/boost, input HUD, autopilot and takeover.
This emulates terminal protocol responses; it does not measure a GUI compositor.
Usage: python3 scripts/mk64_terminal_smoke.py zig-out/bin/marlin /path/to/ROM.z64
"""
import shutil, re
from pathlib import Path
import os, pty, select, time, fcntl, termios, struct, signal, argparse, tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary')
parser.add_argument('rom', nargs='?')
args=parser.parse_args()
binary=os.path.abspath(args.binary)
rom=os.path.abspath(args.rom) if args.rom else None
def run(supported):
 pid,fd=pty.fork()
 if pid==0:
  os.environ['TERM']='xterm-kitty'
  os.environ.pop('MARLIN_MK64_ROM', None)
  os.environ.pop('MARLIN_MK64_ASSETS', None)
  os.execv(binary,[binary,'mk64'] + ([rom] if rom else []))
 fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,800,600))
 output=bytearray();answered=False;started=None;sent=set();status=None
 schedule=[(.05,b'\x1b[116;1:1u'),(.1,b'\x1b[116;1:2u'),(.2,b'\x1b[116;1:3u'),(2.2,b'\x1b[112;1:1u'),(2.3,b'\x1b[112;1:2u'),(2.4,b'\x1b[112;1:3u'),(2.6,b'\x1b[112;1:1u'),(2.7,b'\x1b[112;1:3u'),(2.9,b'\x1b[119;1:1u'),(3.0,b'\x1b[119;1:3u'),(3.2,b'\x1b[111;1:1u'),(3.3,b'\x1b[111;1:2u'),(3.4,b'\x1b[111;1:3u'),(3.7,b'\x1b[O'),(3.75,b'\x1b[119;1:1u'),(3.77,b'\x1b[119;1:3u'),(3.8,b'\x1b[I'),(4.0,b'\x1b[112;1:1u'),(4.1,b'\x1b[112;1:3u'),(4.3,b'\x1b[114;1:1u'),(4.4,b'\x1b[114;1:2u'),(4.5,b'\x1b[114;1:3u'),(4.97,b'\x1b[104;1:3u')]
 schedule += [(4.6,b"\x1b[104;1:1u"),(4.65,b"\x1b[104;1:3u"),(4.7,b"\x1b[104;1:1u"),(4.75,b"\x1b[104;1:3u"),(4.8,b"\x1b[103;1:1u"),(4.85,b"\x1b[103;1:3u"),(4.9,b"\x1b[99;1:1u"),(4.92,b"\x1b[99;1:2u"),(4.95,b"\x1b[99;1:3u"),(5.1,b"\x1b[109;1:1u"),(5.12,b"\x1b[109;1:2u"),(5.15,b"\x1b[109;1:3u"),(8.4,b"\x1b[111;1:1u"),(8.45,b"\x1b[111;1:3u"),(8.6,b"\x1b[101;1:1u"),(8.65,b"\x1b[101;1:2u"),(8.7,b"\x1b[101;1:3u"),(8.8,b"\x1b[101;2:1u"),(8.85,b"\x1b[101;2:2u"),(8.9,b"\x1b[101;2:3u"),(10.0,b"\x1b[27;1:1u")]
 deadline=time.monotonic()+15
 try:
  while time.monotonic()<deadline:
   ready,_,_=select.select([fd],[],[],.02)
   if ready:
    try:chunk=os.read(fd,262144)
    except OSError:break
    if not chunk:break
    output.extend(chunk)
    if b'\x1b[5n' in chunk:os.write(fd,b'\x1b[0n')
   if not answered and b'\x1b[c' in output:
    os.write(fd,(b'\x1b[?31u\x1b_Gi=1;OK\x1b\\' if supported else b'')+b'\x1b[?1;2c')
    answered=True
   if started is None and b'a=T,f=24' in output:started=time.monotonic()
   if started is not None:
    elapsed=time.monotonic()-started
    for i,(when,data) in enumerate(schedule):
     if elapsed>=when and i not in sent:os.write(fd,data);sent.add(i)
    if elapsed>1.95 and 'resize' not in sent:
     fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,640,480));sent.add('resize')
   result=os.waitpid(pid,os.WNOHANG)
   if result[0]:status=result[1];break
  if status is None:
   result=os.waitpid(pid,os.WNOHANG)
   if result[0]:status=result[1]
   else:
    os.kill(pid,signal.SIGTERM);_,status=os.waitpid(pid,0)
  code=os.waitstatus_to_exitcode(status)
  data=bytes(output)
  if supported:
   assert code==0,(code,data[-500:])
   count=data.count(b'a=T,f=24')
   assert count>=520,count
   assert b'0 km/h | Lap 1/3' in data, 'restart did not reset speed/lap'
   assert b' km/h | Lap' in data, 'speed readout missing'
   assert b'DRIFT READY' in data, 'charge never appeared'
   assert b'MINI-TURBO!' in data, 'boost never appeared'
   assert b'DRIFT DEMO | [W]' in data, 'demo keys missing'
   assert b'AUTO | [W]' in data, 'autopilot missing'
   focus_end=data.rfind(b'PAUSED')
   assert b'AUTO | [W]' in data[focus_end:], 'P did not resume autopilot after focus loss'
   assert b'MANUAL | [W]' in data, 'manual takeover missing'
   assert b'[SPACE]' in data, 'hop input missing'
   assert b'PAUSED' in data,'pause not rendered'
   assert b'\x1b[?1004l' in data,'focus not restored'
   assert b'\x1b[?1049l' in data,'alternate screen not restored'
   assert b'a=d,d=I' in data,'images not deleted'
   print(f'capable terminal: {count} frames; drift-ready, boost, demo keys, autopilot, takeover, pause, focus, resize, class/mode switches and cleanup passed')
  else:
   assert code==1,(code,data[-500:])
   assert b'KittyGraphicsRequired' in data,data[-500:]
   assert b'\x1b[?1049l' in data
   print('unsupported terminal: refused graphics and restored alternate screen')
 finally:
  os.close(fd)
with tempfile.TemporaryDirectory(prefix="mk64-cache-") as cache, tempfile.TemporaryDirectory(prefix="mk64-smoke-") as state:
 os.environ['XDG_CACHE_HOME'] = cache
 if not rom:
  root = Path(__file__).resolve().parent.parent
  digest = re.search(r'digest_hex = "([a-f0-9]+)"', (root / 'src/mk64/cache.zig').read_text()).group(1)
  fixture = root / 'assets/mk64' / (digest + '.mkassets')
  dest = Path(cache) / 'marlin/mk64' / fixture.name
  dest.parent.mkdir(parents=True)
  shutil.copyfile(fixture, dest)
 os.environ["MARLIN_MK64_STATE_DIR"]=state
 run(True)
 run(False)
 assert not os.listdir(state), "assisted/practice run wrote a best ghost"

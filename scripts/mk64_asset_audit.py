#!/usr/bin/env python3
"""Measure a minimal resource bundle from mk64-probe's decoded asset audit.
Usage: python3 scripts/mk64_asset_audit.py /tmp/audit.json /tmp/luigi.mkassets
Writes an EXPERIMENTAL bundle and a JSON manifest beside it. The game does not
load this format yet. Output contains extracted game assets; keep it out of git.
Python is investigation tooling only; the proposed shipping converter is Zig.
"""
import hashlib, json, struct, sys, zlib
from pathlib import Path
source, output = map(Path, sys.argv[1:3])
a = json.loads(source.read_text())
a['schema'] = bytes(a['schema']).decode() if isinstance(a['schema'], list) else a['schema']
a['source_sha1'] = bytes(a['source_sha1']).decode() if isinstance(a['source_sha1'], list) else a['source_sha1']
assert a['schema'] == 'marlin-mk64-asset-audit-v1'
resources = []
def resource(name, encoding, data, count=None):
    resources.append((name, encoding, bytes(data), count))
def integer(value):
    n = int(value)
    assert n == value, ('lossy conversion', value)
    return n
def position(p):
    return struct.pack('<3h', *(integer(p[c]) for c in ('x','y','z')))
def rgba16(pixel):
    r,g,b,alpha = pixel
    assert alpha in (0,255)
    assert all(((c >> 3) << 3 | (c >> 3) >> 2) == c for c in (r,g,b))
    return struct.pack('<H', ((r>>3)<<11)|((g>>3)<<6)|((b>>3)<<1)|(alpha!=0))
def palette(colors):
    return b''.join(map(rgba16, colors))
def intern(value, values, lookup):
    if value not in lookup:
        lookup[value] = len(values)
        values.append(value)
    return lookup[value]
# Keep complete referenced texture tiles, but no unreferenced pages.
intervals = sorted((t['style']['offset'], t['style']['offset']+t['style']['width']*t['style']['height']*2)
                   for t in a['visual'] if t['style']['textured'])
merged = []
for start,end in intervals:
    assert 0 <= start < end <= len(a['textures'])
    if merged and start <= merged[-1][1]: merged[-1][1] = max(end,merged[-1][1])
    else: merged.append([start,end])
tex = bytes(a['textures'])
texture_blob = bytearray(); remaps = []
for start,end in merged:
    remaps.append((start,end,len(texture_blob)))
    texture_blob.extend(tex[start:end])
def remap(offset, length):
    for start,end,dest in remaps:
        if start <= offset and offset+length <= end:
            new = dest+offset-start
            assert texture_blob[new:new+length] == tex[offset:offset+length]
            return new
    raise ValueError('unmapped texture')
resource('course/textures','rgba5551-or-ia16-be',texture_blob)
vertices=[]; vertex_ids={}; materials=[]; material_ids={}; faces=bytearray()
for tri in a['visual']:
    ids=[]
    for v in tri['vertices']:
        data=position(v['pos'])+struct.pack('<2h',integer(v['u']*32),integer(v['v']*32))+bytes(v['color'])
        ids.append(intern(data,vertices,vertex_ids))
    s=tri['style']; length=s['width']*s['height']*2
    data=struct.pack('<IHHBBBBB', remap(s['offset'],length) if s['textured'] else 0,
                     s['width'],s['height'],s['cms'],s['cmt'],s['fmt'],s['textured'],s['decal'])
    material=intern(data,materials,material_ids)
    faces.extend(struct.pack('<4H',*ids,material))
resource('course/vertices','xyz-i16-uv-i16-over32-rgb8-le',b''.join(vertices),len(vertices))
resource('course/materials','offset-u32-wh-u16-wrap-format-flags-u8-le',b''.join(materials),len(materials))
resource('course/triangles','vertex3-material-u16-le',faces,len(a['visual']))
# Collision consumes positions + surfaces only, never UVs/materials/colours.
collision_vertices=[]; collision_ids={}; collision_faces=bytearray()
for tri in a['collision']:
    ids=[intern(position(v['pos']),collision_vertices,collision_ids) for v in tri['vertices']]
    collision_faces.extend(struct.pack('<3HB',*ids,tri['surface']))
resource('collision/vertices','xyz-i16-le',b''.join(collision_vertices),len(collision_vertices))
resource('collision/triangles','vertex3-u16-surface-u8-le',collision_faces,len(a['collision']))
resource('course/path','xyz-i16-section-u16-le',b''.join(position(p['pos'])+struct.pack('<H',p['section']) for p in a['path']),len(a['path']))
# Keep CI8 indices for palette animation. Store only referenced palette colours.
names=['mario','luigi','yoshi','toad','dk','wario','peach','bowser']
for name,sprite in zip(names,a['sprites']):
    used_base=sorted({p for indices in sprite['indices'] for p in indices if p<192})
    base=sprite['palettes'][0][0]
    for f,indices in enumerate(sprite['indices']):
        for phase in range(4):
            for p in set(indices):
                if p<192: assert sprite['palettes'][f][phase][p] == base[p]
    resource(f'karts/{name}/body-palette','count-u16-index-u8-rgba5551-u16-le',
             struct.pack('<H',len(used_base))+b''.join(bytes([p])+rgba16(base[p]) for p in used_base),len(used_base))
    for f,indices in enumerate(sprite['indices']):
        resource(f'karts/{name}/{f:02}/indices','ci8-64x64',indices,4096)
        used_wheels=sorted({p for p in indices if p>=192})
        wheels=struct.pack('<H',len(used_wheels))+b''.join(bytes([p])+palette([sprite['palettes'][f][phase][p] for phase in range(4)]) for p in used_wheels)
        resource(f'karts/{name}/{f:02}/wheels','count-u16-index-u8-four-rgba5551-u16-le',wheels,len(used_wheels))
for field,encoding in [('spark_small','i8-16x16'),('spark_large','i8-32x32')]:
    data=bytes(a['sprites'][0][field])
    assert all(bytes(s[field])==data for s in a['sprites'])
    resource('particles/'+field,encoding,data)
resource('hud/font','rgba5551-le-128x32',palette(a['hud']['font']))
resource('hud/box-question','rgba5551-le-32x64',palette(a['hud']['box']))
for name,icon in zip(['mushroom','banana','green-shell','red-shell'],a['hud']['icons']):
    resource('hud/'+name,'rgba5551-le-40x32',palette(icon))
for name,label in zip(['lap1','lap2','lap3','time'],a['hud']['labels']):
    resource('hud/'+name,'rgba5551-le-32x16',palette(label))
# Independently framed zlib entries with content deduplication. Explicit byte
# encodings avoid Zig struct padding, host pointers and ABI dependencies.
payload=bytearray(); entries=[]; shared={}
for name,encoding,raw,count in resources:
    digest=hashlib.sha256(raw).hexdigest()
    key=(digest,len(raw))
    if key not in shared:
        packed=zlib.compress(raw,9)
        shared[key]=(len(payload),len(packed))
        payload.extend(packed)
    offset,size=shared[key]
    entries.append(dict(name=name,encoding=encoding,count=count,offset=offset,
                        compressed_bytes=size,raw_bytes=len(raw),sha256=digest))
manifest=dict(format='MKASXP01',status='experimental; no runtime loader',source_sha1=a['source_sha1'],
              counts=dict(loaded_vertices=a['loaded_vertices'],visual_vertices=len(vertices),
                          visual_triangles=len(a['visual']),materials=len(materials),
                          collision_vertices=len(collision_vertices),collision_triangles=len(a['collision']),
                          path_points=len(a['path']),characters=8,kart_frames=120),
              texture_bytes_loaded=len(tex),texture_bytes_referenced=len(texture_blob),entries=entries)
meta=json.dumps(manifest,separators=(',',':'),sort_keys=True).encode()
blob=b'MKASXP01'+struct.pack('<I',len(meta))+meta+payload
blob+=hashlib.sha256(blob).digest()
output.write_bytes(blob)
# Reopen the actual file and verify every entry, not just the compressor result.
saved=output.read_bytes()
assert saved[:8]==b'MKASXP01' and hashlib.sha256(saved[:-32]).digest()==saved[-32:]
meta_len=struct.unpack('<I',saved[8:12])[0]
parsed=json.loads(saved[12:12+meta_len]); start=12+meta_len
for entry,(_,_,raw,_) in zip(parsed['entries'],resources):
    unpacked=zlib.decompress(saved[start+entry['offset']:start+entry['offset']+entry['compressed_bytes']])
    assert unpacked==raw and hashlib.sha256(unpacked).hexdigest()==entry['sha256']
summary=dict(rom_bytes=a['rom_bytes'],bundle_bytes=len(blob),metadata_bytes=len(meta)+12+32,
             compressed_payload_bytes=len(payload),logical_resource_bytes=sum(len(r[2]) for r in resources),
             resource_entries=len(entries),unique_payloads=len(shared),counts=manifest['counts'],
             texture_bytes_loaded=len(tex),texture_bytes_referenced=len(texture_blob),
             groups={group:dict(raw_bytes=sum(len(raw) for name,_,raw,_ in resources if name.startswith(group+'/')),
                               compressed_entry_bytes=sum(e['compressed_bytes'] for e in entries if e['name'].startswith(group+'/')))
                     for group in ['course','collision','karts','particles','hud']})
output.with_suffix(output.suffix+'.manifest.json').write_text(json.dumps(dict(summary=summary,manifest=manifest),indent=2)+'\n')
print(json.dumps(summary,indent=2))
print(f'Verified {len(entries)} entries after reopening {output}; runtime loading remains to be implemented.')

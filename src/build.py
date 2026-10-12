import json, os, re, struct, zipfile, hashlib, sys
from PIL import Image, ImageDraw, ImageFont
MAGIC, LUA = 0xF0000011, 0xa14e8dfa2cd117e2
# python3 build.py test N   -> numbered test build (test GUID, tester logging, logs to Logs\\test)
# python3 build.py release  -> the release zip (live GUID, tester and research code stripped) and its Tester zip
#                               (test GUID, tester logging, research code stripped, logs to Logs)
RELEASE_VERSION = '0.6.0'
TEST_GUID = '8d3f6b21-4e7a-4c95-b2d0-7a1e9c5f3b64'   # shared by the test builds and the release Tester
LIVE_GUID = 'a651a7db-0eb8-40b9-9d1d-4e7812958694'   # the released mod (never changes)
TITLE = 'Realistic Resistances'
mode = sys.argv[1] if len(sys.argv) > 1 else 'test'
if mode == 'test':
    builds = [dict(kind='test', n=int(sys.argv[2]))]
elif mode == 'release':
    builds = [dict(kind='release'), dict(kind='release_tester')]
else:
    sys.exit('usage: build.py test N | release')
def resource_hash(name):
    data = name.encode(); mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask; end = len(data) // 8 * 8
    for (w,) in struct.iter_unpack('<Q', data[:end]):
        w = w * mix & mask; w ^= w >> 47; value = (value ^ (w * mix & mask)) * mix & mask
    if data[end:]: value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47; value = value * mix & mask; value ^= value >> 47
    return value
def lua_archive(path, module, src):
    data = struct.pack('<II', len(src), 2) + src
    head = struct.pack('<III', MAGIC, 1, 1) + b'\0' * 60 + struct.pack('<QQQII', 0, LUA, 1, 16, 16)
    cursor = len(head) + 80; pad = -cursor % 16; cursor += pad
    row = struct.pack('<7Q6I', resource_hash(module), LUA, cursor, 0, 0, 0, 0, len(data), 0, 0, 16, 16, 0)
    out = bytearray(head + row + b'\0' * pad + data)
    # ((0.5.1 review) +32 holds where the data ends, as the other mods' patch writer has it (it held the padded total))
    struct.pack_into('<I', out, 32, len(out)); out += b'\0' * (-len(out) % 16)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(out); open(path + '.gpu_resources', 'wb').write(b''); open(path + '.stream', 'wb').write(b'')
    entries = check_archive(path)   # (read back: one Lua entry holding exactly this data)
    assert [(rid, tid, body) for rid, tid, body in entries] == [(resource_hash(module), LUA, data)], f'{path}: read back differs'
def check_archive(path):
    # ((0.5.1 review) reads a written patch back (the checks of the other mods' patch_writer.check()): magic, type rows
    # that add up, each entry's data inside the file and 16-byte aligned, gpu/stream data inside their files and
    # 64-byte aligned, a TOC of at least 256 bytes per entry, and +32 = the end of the last entry's data. Returns the
    # entries as (id, type, data).
    toc = open(path, 'rb').read(); gpu = open(path + '.gpu_resources', 'rb').read(); stream = open(path + '.stream', 'rb').read()
    def bad(why): raise ValueError(f'{path}: patch layout: {why}')
    if len(toc) < 72: bad('shorter than its header')
    magic, nt, n = struct.unpack_from('<III', toc, 0)
    if magic != MAGIC: bad('magic %08x' % magic)
    if len(toc) < 72 + 32 * nt + 80 * n: bad('rows run past the end')
    if len(toc) < 256 * n: bad('TOC %d bytes for %d entries (fewer than 256 a entry)' % (len(toc), n))
    counts = {}
    for k in range(nt):
        _, tid, cnt, _, _ = struct.unpack_from('<QQQII', toc, 72 + 32 * k)
        counts[tid] = cnt
    seen, out, end = {}, [], 0
    for k in range(n):
        rid, tid, off, soff, goff, _, _, size, ssize, gsize, _, _, _ = struct.unpack_from('<7Q6I', toc, 72 + 32 * nt + 80 * k)
        seen[tid] = seen.get(tid, 0) + 1
        if off % 16 or off + size > len(toc): bad('entry %016x data at %d (+%d)' % (rid, off, size))
        if gsize and (goff % 64 or goff + gsize > len(gpu)): bad('entry %016x gpu data at %d (+%d)' % (rid, goff, gsize))
        if ssize and (soff % 64 or soff + ssize > len(stream)): bad('entry %016x stream data at %d (+%d)' % (rid, soff, ssize))
        out.append((rid, tid, toc[off:off + size])); end = max(end, off + size)
    if seen != counts: bad('type rows %s, entries %s' % (counts, seen))
    if struct.unpack_from('<I', toc, 32)[0] != end: bad('+32 is %d, the data ends at %d' % (struct.unpack_from('<I', toc, 32)[0], end))
    return out
def flag_addon(module, flag, what):
    return (f'-- HD2-Addon: {module}\n-- Realistic Resistances option: {what}. Needs the core option.\n'
            f"rawset(_G, '{flag}', true)\n").encode()
def strip_blocks(src, tag):
    # drops the --@<tag>-begin ... --@<tag>-end blocks
    out, skip = [], 0
    for line in src.split('\n'):
        t = line.strip()
        if t == f'--@{tag}-begin': skip += 1; continue
        if t == f'--@{tag}-end': skip -= 1; assert skip >= 0, tag; continue
        if not skip: out.append(line)
    assert skip == 0, tag
    return '\n'.join(out)
# ((0.5.1 review) the research code (numbered test builds only) is marked --@research-begin / --@research-end and is
# left out of the release and of the release Tester; these names must not be left in either)
RESEARCH_SYMBOLS = ('@research', 'damage_queue_research', 'arc_research', 'research_log', 'raw_log', 'map_all',
                    'passive_map_dump', 'passive_layout_dump', 'dmgq', 'DQ.')
def strip_research(src):
    src = strip_blocks(src, 'research')
    left = [w for w in RESEARCH_SYMBOLS if w in src]
    assert not left, f'research code left in: {left}'
    return src
def strip_tester(src):
    # release: tester-only code goes too (--@tester-begin ... --@tester-end blocks and one-line tester events)
    out = []
    for line in strip_blocks(src, 'tester').split('\n'):
        if re.fullmatch(r'if TESTER then event\(.*\) end', line.strip()): continue
        out.append(line)
    src = '\n'.join(out)
    assert '@tester' not in src and 'research' not in src.replace('research-only', ''), 'tester code left in the release'
    return src
# ((0.5.1 review) personal paths and names: checked in the manifest and in every Lua file that goes into the zip)
PERSONAL = (r'\bDon\b', r'Users\\', r'\\Users', r'C:\\', r'D:\\', 'SteamLibrary', '/home/', '/mnt/')
def check_personal(what, text):
    for bad in PERSONAL:
        assert not re.search(bad, text, re.I), f'{what}: {bad}'

def font(size):
    # ((0.5.1 review) DejaVu Sans Bold when it is there, else Pillow's own font)
    try: return ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', size)
    except OSError:
        try: return ImageFont.load_default(size)
        except TypeError: return ImageFont.load_default()
def test_thumbnail(label):
    im = Image.new('RGB', (512, 512), (20, 20, 24)); d = ImageDraw.Draw(im)
    d.rectangle([12, 12, 499, 499], outline=(255, 196, 0), width=10)
    f, g = font(54), font(30)
    d.text((256, 175), 'REALISTIC', font=f, fill=(255, 196, 0), anchor='mm'); d.text((256, 245), 'RESISTANCES', font=f, fill=(255, 196, 0), anchor='mm')
    d.text((256, 320), 'FIRE  \u2022  GAS  \u2022  ARC', font=g, fill=(255, 255, 255), anchor='mm')
    d.text((256, 400), label, font=g, fill=(220, 220, 220), anchor='mm')
    return im

def build(b):
    kind = b['kind']
    tester = kind != 'release'
    thumb = None   # ((0.5.1 review) only test builds get the generated thumbnail; the release and its Tester use the art)
    if kind == 'test':
        version, label = RELEASE_VERSION, f"Test {b['n']}"
        name = f"{TITLE} {RELEASE_VERSION} Test {b['n']} (tester)"; guid = TEST_GUID
        zname = f"Realistic-Resistances-{RELEASE_VERSION}-Test-{b['n']}-Tester.zip"; logs = 'Logs\\test'; thumb = f"{RELEASE_VERSION} Test {b['n']}"
    elif kind == 'release_tester':
        version, label = RELEASE_VERSION, 'beta (tester)'
        name = f'{TITLE} {RELEASE_VERSION} Tester'; guid = TEST_GUID
        zname = f'Realistic-Resistances-{RELEASE_VERSION}-Tester.zip'; logs = 'Logs'
    else:
        version, label = RELEASE_VERSION, 'beta'
        name = f'{TITLE} {RELEASE_VERSION} (beta)'; guid = LIVE_GUID
        zname = f'Realistic-Resistances-{RELEASE_VERSION}.zip'; logs = 'Logs'
    core = open('core.lua').read()
    core = re.sub(r"local VERSION = '[^']*'", f"local VERSION = '{version} {label}'", core, count=1)
    core = re.sub(r"local TESTER = (true|false)", f"local TESTER = {'true' if tester else 'false'}", core, count=1)
    core = re.sub(r"local TEST_LOGS = (true|false)", f"local TEST_LOGS = {'true' if kind == 'test' else 'false'}", core, count=1)
    if kind != 'test': core = strip_research(core)
    if not tester: core = strip_tester(core)
    os.makedirs('out', exist_ok=True)
    open(f'out/core-{kind}.lua', 'w').write(core)
    files = {
      'Core/9ba626afa44a3aa3.patch_0': ('mods/chef/realistic_resistances', core.encode()),
      'Harder to Ignite/9ba626afa44a3aa3.patch_0': ('mods/chef/realistic_resistances_ignite', flag_addon('mods/chef/realistic_resistances_ignite', 'RealisticResistancesIgnite', 'harder to ignite')),
      'Self-Extinguish/9ba626afa44a3aa3.patch_0': ('mods/chef/realistic_resistances_extinguish', flag_addon('mods/chef/realistic_resistances_extinguish', 'RealisticResistancesExtinguish', 'self-extinguish')),
      'Gas Resistance/9ba626afa44a3aa3.patch_0': ('mods/chef/realistic_resistances_gas', flag_addon('mods/chef/realistic_resistances_gas', 'RealisticResistancesGas', 'gas resistance')),
      'Arc Resistance/9ba626afa44a3aa3.patch_0': ('mods/chef/realistic_resistances_arc', flag_addon('mods/chef/realistic_resistances_arc', 'RealisticResistancesArc', 'arc resistance')),
      'No Gas Slow/9ba626afa44a3aa3.patch_0': ('mods/chef/realistic_resistances_no_gas_slow', flag_addon('mods/chef/realistic_resistances_no_gas_slow', 'RealisticResistancesNoGasSlow', 'no gas slow')),
      'Grounded/9ba626afa44a3aa3.patch_0': ('mods/chef/realistic_resistances_grounded', flag_addon('mods/chef/realistic_resistances_grounded', 'RealisticResistancesGrounded', 'grounded')),
    }
    for rel, (m, src) in files.items():
        check_personal(rel, src.decode())
        lua_archive('build/stage/' + rel, m, src)
    if thumb: test_thumbnail(thumb).save('build/thumbnail.png')
    else: Image.open('art/thumbnail_512.png').save('build/thumbnail.png')   # (release art)
    manifest = {'Version': 1, 'Guid': guid, 'Name': name,
      'Description': 'Elemental resistances: fire, gas and arc. Armor passives that resist fire, gas or arc also resist catching fire, the gas effects, the electric effect and EMS stuns, by the passive\'s own amount and the armor\'s weight; arc-resistant passives also take a quarter of the arc damage they did. The fire, gas and stun changes apply only to your own helldiver. Requires Bingus Shared Loader.' + (' Beta: report anything odd on the mod page.' if kind != 'test' else '') + f' Log: %LOCALAPPDATA%\\CowboyBingus\\Helldivers2\\{logs}\\RealisticResistances.log',
      'IconPath': 'thumbnail.png',
      'Options': [
        {'Name': 'Core (required)', 'Image': 'options/core.png', 'Description': 'The core of the mod. Keep this on.', 'Include': ['Core']},
        {'Name': 'Fire Resistance', 'Image': 'options/fire.png', 'Description': 'Fire-resistant armor resists catching fire, not just the fire damage, by the passive\'s own fire resistance and the armor\'s weight.', 'SubOptions': [
          {'Name': 'Harder to Ignite and Self-Extinguish', 'Image': 'options/fire_both.png', 'Description': 'Both: fire takes a flat time to set you alight (Inflammable: 2 s in medium armor, 1.5 s light, 2.5 s heavy) and the burn runs out sooner once you leave the flames.', 'Include': ['Harder to Ignite', 'Self-Extinguish']},
          {'Name': 'Only Harder to Ignite', 'Image': 'options/fire_ignite.png', 'Description': 'Fire takes a flat time to set you alight (Inflammable: 2 s in medium armor, 1.5 s light, 2.5 s heavy; other armors by their fire resistance). Burns last as normal.', 'Include': ['Harder to Ignite']},
          {'Name': 'Only Self-Extinguish', 'Image': 'options/fire_extinguish.png', 'Description': 'You catch fire as normal, but the burn runs out sooner once you leave the flames, by the passive\'s fire resistance.', 'Include': ['Self-Extinguish']}]},
        {'Name': 'Gas Resistance', 'Image': 'options/gas.png', 'Description': 'Gas-resistant armor resists the gas effects, not just the gas damage, by the passive\'s own gas resistance and the armor\'s weight.', 'SubOptions': [
          {'Name': 'Filtration Buffer and No Gas Slow', 'Image': 'options/gas_both.png', 'Description': 'Both: gas holds off longer, by the passive gas resistance (50%: twice as long in medium armor) and wears off sooner once you are out of it, and with 80% gas resistance or more (Advanced Filtration) the gas stumbling and slowing never takes hold.', 'Include': ['Gas Resistance', 'No Gas Slow']},
          {'Name': 'Only Filtration Buffer', 'Image': 'options/gas_buffer.png', 'Description': 'Gas holds off longer, by the passive gas resistance (50%: twice as long in medium armor) and wears off sooner once you are out of it. The stumbling and slowing work as normal once the gas takes hold.', 'Include': ['Gas Resistance']},
          {'Name': 'Only No Gas Slow', 'Image': 'options/gas_noslow.png', 'Description': 'With 80% gas resistance or more (Advanced Filtration) the gas stumbling and slowing never takes hold. Otherwise gas works as normal.', 'Include': ['No Gas Slow']}]},
        {'Name': 'Arc Resistance', 'Image': 'options/arc.png', 'Description': 'Arc-resistant armor resists the electric effect and EMS stuns, not just the arc damage (Electrical Conduit is never stunned by EMS), and arc-resistant passives take a quarter of the arc damage they did.', 'SubOptions': [
          {'Name': 'Resistance and Grounded', 'Image': 'options/arc_both.png', 'Description': 'Both: the electric effect holds off and wears off sooner, EMS stuns wear off sooner (Electrical Conduit: never stunned by EMS), arc-resistant passives take a quarter of the arc damage they did, and with Electrical Conduit arcs end at you instead of chaining on.', 'Include': ['Arc Resistance', 'Grounded']},
          {'Name': 'Only Resistance', 'Image': 'options/arc_resist.png', 'Description': 'The electric effect holds off and wears off sooner, EMS stuns wear off sooner (Electrical Conduit: never stunned by EMS), and arc-resistant passives take a quarter of the arc damage they did. Arcs chain as normal.', 'Include': ['Arc Resistance']},
          {'Name': 'Only Grounded', 'Image': 'options/arc_grounded.png', 'Description': 'Electrical Conduit only: arcs end at you instead of chaining on to others.', 'Include': ['Grounded']}]},
      ]}
    manifest_text = json.dumps(manifest, indent=2)
    check_personal('manifest.json', manifest_text)
    # (0.6.0) every entry gets the same fixed date, so the same source always gives the same zip, byte for byte
    def put(name, data):
        zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = 0o644 << 16
        z.writestr(zi, data)
    with zipfile.ZipFile(zname, 'w', zipfile.ZIP_DEFLATED) as z:
        put('manifest.json', manifest_text); put('thumbnail.png', open('build/thumbnail.png', 'rb').read())
        for icon in sorted(os.listdir('art/options')): put('options/' + icon, open('art/options/' + icon, 'rb').read())
        for rel in files:
            for ext in ('', '.gpu_resources', '.stream'): put(rel + ext, open('build/stage/' + rel + ext, 'rb').read())
    print(zname, os.path.getsize(zname), hashlib.md5(core.encode()).hexdigest())


for b in builds: build(b)

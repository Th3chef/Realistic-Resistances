"""Renders Realistic Resistances' art with Chromium (Playwright), in the same family as the other mods: Anton +
Barlow Condensed, yellow on black with a hazard stripe. Three element cards (fire, gas, arc) carry the mod's real
numbers. Everything is drawn here (no game assets, logos or emblems).
Outputs (this folder): thumbnail_1254.png, thumbnail_512.png (mod manager), header_1300x372.png,
gallery_1920x1080.png, values_1920x1080.png, GitHub-Social-1280x640.png, options/*.png (option icons)."""
import base64, os
from PIL import Image
from playwright.sync_api import sync_playwright

ART = os.path.dirname(os.path.abspath(__file__))
BADGE = '0.5 BETA'
YELLOW = '#ffe710'
FIRE, GAS, ARC = '#ff7a1a', '#9be23c', '#5ad8ff'


def font(name):
    return base64.b64encode(open(os.path.join(ART, 'fonts', name), 'rb').read()).decode()


FONTS = f'''
  @font-face {{ font-family: Anton; src: url(data:font/woff2;base64,{font('anton-latin-400-normal.woff2')}); }}
  @font-face {{ font-family: Barlow; font-weight: 500; src: url(data:font/woff2;base64,{font('barlow-condensed-latin-500-normal.woff2')}); }}
  @font-face {{ font-family: Barlow; font-weight: 600; src: url(data:font/woff2;base64,{font('barlow-condensed-latin-600-normal.woff2')}); }}
  @font-face {{ font-family: Barlow; font-weight: 700; src: url(data:font/woff2;base64,{font('barlow-condensed-latin-700-normal.woff2')}); }}'''

# ---------------------------------------------------------------- icons (100 x 100 viewBox)
def glow(id_, color, sd=3.5):
    return (f'<filter id="{id_}" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="{sd}" result="b"/>'
            f'<feFlood flood-color="{color}" flood-opacity="0.9"/><feComposite in2="b" operator="in" result="g"/>'
            f'<feMerge><feMergeNode in="g"/><feMergeNode in="g"/><feMergeNode in="SourceGraphic"/></feMerge></filter>')


def flame(uid):
    return f'''<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><defs>{glow('gf' + uid, FIRE)}
      <linearGradient id="fg{uid}" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#ffd54a"/><stop offset="0.45" stop-color="{FIRE}"/>
        <stop offset="1" stop-color="#ff3b1a"/></linearGradient></defs>
      <g filter="url(#gf{uid})">
      <path d="M50 6 C56 22 72 30 74 50 C76 66 66 88 50 92 C34 88 24 70 27 54 C29 42 36 36 38 26 C44 34 44 40 46 44 C48 32 46 18 50 6 Z" fill="url(#fg{uid})"/>
      <path d="M50 46 C55 56 62 62 61 72 C60 82 55 86 50 87 C44 86 39 80 40 71 C41 64 46 60 47 54 C49 58 49 61 50 63 C51 58 51 52 50 46 Z" fill="#fff3b0"/>
      </g></svg>'''


def cloud(uid):
    return f'''<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><defs>{glow('gg' + uid, GAS)}
      <linearGradient id="cg{uid}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#d8ff8a"/><stop offset="1" stop-color="#5fb323"/></linearGradient></defs>
      <g filter="url(#gg{uid})" fill="url(#cg{uid})">
        <circle cx="34" cy="50" r="17"/><circle cx="54" cy="40" r="22"/><circle cx="72" cy="54" r="15"/>
        <rect x="20" y="52" width="64" height="18" rx="9"/>
      </g>
      <g fill="none" stroke="{GAS}" stroke-width="5" stroke-linecap="round" filter="url(#gg{uid})">
        <path d="M18 80 q8 -6 16 0 t16 0 t16 0 t16 0"/><path d="M28 92 q8 -6 16 0 t16 0 t16 0" stroke-opacity="0.7"/>
      </g></svg>'''


def bolt(uid):
    return f'''<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><defs>{glow('ga' + uid, ARC)}
      <linearGradient id="ag{uid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e8fbff"/><stop offset="1" stop-color="{ARC}"/></linearGradient></defs>
      <g filter="url(#ga{uid})"><path d="M58 4 L22 56 L46 56 L38 96 L78 40 L53 40 L66 4 Z" fill="url(#ag{uid})"/></g>
      <g fill="none" stroke="{ARC}" stroke-width="3" stroke-linecap="round" stroke-opacity="0.8">
        <path d="M16 30 l8 4 l-4 6 l9 3"/><path d="M86 62 l-8 -3 l4 -7 l-9 -2"/></g></svg>'''


def shield(uid, color=YELLOW):
    return f'''<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><defs>{glow('gs' + uid, color, 2.5)}</defs>
      <g filter="url(#gs{uid})"><path d="M50 6 L86 18 L84 52 C82 72 68 86 50 94 C32 86 18 72 16 52 L14 18 Z" fill="none" stroke="{color}" stroke-width="8" stroke-linejoin="round"/>
      <path d="M50 22 L72 30 L70 52 C69 64 61 73 50 78 C39 73 31 64 30 52 L28 30 Z" fill="{color}" fill-opacity="0.9"/></g></svg>'''


ICONS = {'fire': (flame, FIRE), 'gas': (cloud, GAS), 'arc': (bolt, ARC)}
CARDS = [  # kind, big number, line 1, line 2 (the mod's real values)
    ('fire', '2s', 'TO CATCH FIRE', 'INFLAMMABLE &middot; MEDIUM ARMOR'),
    ('gas', '5&times;', 'SLOWER GAS', 'ADV. FILTRATION &middot; MEDIUM ARMOR'),
    ('arc', '4&times;', 'ARC RESISTANCE', 'CONDUIT 95% &rarr; 98.75%'),
]


def cards_html(u, compact=False):
    out = []
    for i, (kind, big, l1, l2) in enumerate(CARDS):
        f, color = ICONS[kind]
        if compact:
            out.append(f'<div class="card c"><div class="ic">{f(kind + str(i))}</div><div class="lbl" style="color:{color}">{kind.upper()}</div></div>')
        else:
            out.append(f'''<div class="card" style="--c:{color}"><div class="ic">{f(kind + str(i))}</div>
              <div class="big" style="color:{color}">{big}</div><div class="l1">{l1}</div><div class="l2">{l2}</div></div>''')
    return ''.join(out)


def page(w, h, L):
    u = L['u']
    compact = L.get('compact', False)
    return f'''<!doctype html><html><head><meta charset="utf-8"><style>{FONTS}
      html,body {{ margin:0; width:{w}px; height:{h}px; overflow:hidden; background:#08090b; }}
      .bg {{ position:absolute; inset:0;
        background: radial-gradient(ellipse at {L['glow1']}, rgba(255,122,26,0.16), rgba(0,0,0,0) 45%),
                    radial-gradient(ellipse at {L['glow2']}, rgba(90,216,255,0.16), rgba(0,0,0,0) 45%),
                    radial-gradient(ellipse at {L['glow3']}, rgba(155,226,60,0.10), rgba(0,0,0,0) 40%),
                    repeating-linear-gradient(0deg, rgba(255,255,255,0.025) 0 1px, transparent 1px {28*u:.0f}px),
                    repeating-linear-gradient(90deg, rgba(255,255,255,0.025) 0 1px, transparent 1px {28*u:.0f}px); }}
      .stripe {{ position:absolute; left:0; right:0; bottom:0; height:{L['stripe']}px;
        background: repeating-linear-gradient(-45deg, {YELLOW} 0 {18*u:.0f}px, #111 {18*u:.0f}px {36*u:.0f}px); }}
      .badge {{ position:absolute; {L['badge']}; background:{YELLOW}; color:#0e0e10; font:{L['badge_size']}px Anton;
        padding:0 {L['badge_size']*0.28:.0f}px; line-height:1.25; letter-spacing:0.02em; }}
      .tag {{ position:absolute; {L['tag']}; text-align:right; font-family:Barlow; font-weight:700; letter-spacing:0.04em; line-height:1.05; }}
      .tag .a {{ color:#fff; font-size:{L['tag_size']}px; font-weight:600; }}
      .tag .b {{ color:{YELLOW}; font-size:{L['tag_size']*1.2:.0f}px; }}
      .title {{ position:absolute; {L['title']}; font-family:Anton; line-height:0.95; text-shadow:0 {4*u:.0f}px {18*u:.0f}px rgba(0,0,0,0.8); }}
      .title .a {{ color:#fff; font-size:{L['t1']}px; letter-spacing:0.02em; }}
      .title .b {{ color:{YELLOW}; font-size:{L['t2']}px; letter-spacing:0.01em; }}
      .foot {{ position:absolute; {L['foot']}; color:#d8d8d8; font-family:Barlow; font-weight:500; font-size:{L['foot_size']}px; letter-spacing:0.06em; }}
      .cards {{ position:absolute; {L['cards']}; display:flex; gap:{L['gap']}px; }}
      .card {{ flex:1; position:relative; background:linear-gradient(180deg, rgba(255,255,255,0.06), rgba(255,255,255,0.015));
        border:{max(2, 3*u):.0f}px solid rgba(255,255,255,0.10); border-top:{8*u:.0f}px solid var(--c);
        padding:{L['pad']}px {L['pad']*0.8:.0f}px; display:flex; flex-direction:column; align-items:center; text-align:center;
        box-shadow: 0 0 {40*u:.0f}px rgba(0,0,0,0.6) inset; }}
      .card .ic {{ width:{L['icon']}px; height:{L['icon']}px; }}
      .card .ic svg {{ width:100%; height:100%; overflow:visible; }}
      .card .big {{ font-family:Anton; font-size:{L['big']}px; line-height:1; margin-top:{L['pad']*0.5:.0f}px; text-shadow:0 0 {22*u:.0f}px currentColor; }}
      .card .l1 {{ font-family:Barlow; font-weight:700; color:#fff; font-size:{L['l1']}px; letter-spacing:0.04em; margin-top:{L['pad']*0.3:.0f}px; line-height:1.05; }}
      .card .l2 {{ font-family:Barlow; font-weight:500; color:#a9a9a9; font-size:{L['l2']}px; letter-spacing:0.02em; white-space:nowrap; margin-top:{L['pad']*0.25:.0f}px; }}
      .card.c {{ border-top-width:{5*u:.0f}px; border-top-color:rgba(255,231,16,0.8); padding:{L['pad']}px; justify-content:center; }}
      .card.c .lbl {{ font-family:Anton; font-size:{L['l1']}px; margin-top:{L['pad']*0.4:.0f}px; letter-spacing:0.06em; }}
    </style></head><body><div class="bg"></div><div class="stripe"></div>
      <div class="cards">{cards_html(u, compact)}</div>
      <div class="badge">{BADGE}</div>
      {'' if not L.get('tag') else '<div class="tag"><div class="a">ARMOR THAT</div><div class="b">ACTUALLY RESISTS</div></div>'}
      <div class="title"><div class="a">REALISTIC</div><div class="b">RESISTANCES</div></div>
      <div class="foot">{L.get('foot_text', 'FIRE &nbsp;&bull;&nbsp; GAS &nbsp;&bull;&nbsp; ARC &nbsp;&nbsp;|&nbsp;&nbsp; BUILT ON YOUR ARMOR PASSIVE')}</div>
    </body></html>'''


LAYOUTS = {
    'thumbnail_1254.png': (1254, 1254, dict(u=1.254, glow1='20% 45%', glow2='82% 45%', glow3='50% 40%', stripe=22,
        badge='left:70px; top:70px', badge_size=86, tag='right:70px; top:74px', tag_size=46,
        cards='left:70px; right:70px; top:250px; height:520px', gap=30, pad=34, icon=190, big=120, l1=36, l2=24,
        title='left:66px; top:820px', t1=150, t2=150, foot='left:72px; bottom:58px', foot_size=32)),
    'gallery_1920x1080.png': (1920, 1080, dict(u=1.6, glow1='48% 40%', glow2='88% 40%', glow3='68% 38%', stripe=18,
        badge='left:64px; top:60px', badge_size=86, tag='right:70px; top:64px', tag_size=46,
        cards='left:800px; right:70px; top:220px; height:500px', gap=30, pad=32, icon=180, big=116, l1=34, l2=20,
        title='left:60px; top:560px', t1=170, t2=170, foot='left:66px; bottom:52px', foot_size=34)),
    'GitHub-Social-1280x640.png': (1280, 640, dict(u=1.0, glow1='50% 40%', glow2='90% 40%', glow3='70% 38%', stripe=12,
        badge='left:40px; top:40px', badge_size=52, tag='right:40px; top:40px', tag_size=28,
        cards='left:560px; right:40px; top:130px; height:320px', gap=18, pad=20, icon=110, big=72, l1=21, l2=14,
        title='left:38px; top:330px', t1=110, t2=110, foot='left:42px; bottom:36px', foot_size=22)),
    'header_1300x372.png': (1300, 372, dict(u=0.8, glow1='62% 50%', glow2='92% 50%', glow3='77% 50%', stripe=10,
        badge='left:40px; top:30px', badge_size=36, tag=None, tag_size=1, compact=True,
        cards='left:680px; right:40px; top:40px; height:270px', gap=16, pad=14, icon=120, big=1, l1=34, l2=1,
        title='left:38px; top:96px', t1=96, t2=96, foot='left:42px; bottom:26px', foot_size=20,
        foot_text='FIRE &nbsp;&bull;&nbsp; GAS &nbsp;&bull;&nbsp; ARC')),
}


# ---------------------------------------------------------------- values sheet (the mod's tables)
def values_page():
    w, h = 1920, 1080
    def table(kind, title, head, rows, note):
        f, color = ICONS[kind]
        tr = ''.join('<tr>' + ''.join(f'<td>{c}</td>' for c in r) + '</tr>' for r in rows)
        th = ''.join(f'<th>{c}</th>' for c in head)
        return f'''<div class="t" style="--c:{color}"><div class="h"><div class="ic">{f('v' + kind)}</div><div class="tt" style="color:{color}">{title}</div></div>
          <table><tr>{th}</tr>{tr}</table><div class="n">{note}</div></div>'''
    fire = table('fire', 'FIRE', ['PASSIVE', 'CATCHES FIRE', 'BURN AFTER'],
                 [['Inflammable 75%', '1.5 / 2 / 2.5 s', '0.75 s'], ['Acclimated, KDM 50%', '0.75 / 1 / 1.25 s', '1.5 s'],
                  ['Desert Stormer 40%', '0.65 / 0.85 / 1.05 s', '1.8 s']],
                 'Vanilla: catches in about 0.25 s and burns 3 s after you step out.')
    gas = table('gas', 'GAS', ['PASSIVE', 'BUILD-UP SLOWED', 'STUMBLING AFTER'],
                [['Adv. Filtration 80%', '3.75 / 5 / 6.25&times;', 'never'], ['Acclimated 50%', '1.5 / 2 / 2.5&times;', '2.5 s'],
                 ['Desert Stormer 40%', '1.25 / 1.67 / 2.08&times;', '3 s'], ['Hazmat, Padding 25%', '1 / 1.33 / 1.67&times;', '3.75 s']],
                'Vanilla stumbling: 5 s. A full-strength hit (strike blast, grenade at your feet) stays vanilla.')
    arc = table('arc', 'ARC', ['PASSIVE', 'DAMAGE RES.', 'ARC STUN'],
                [['Electrical Conduit 95%', '98.75%', '0.075 s'], ['Adreno-Defib. 50%', '87.5%', '0.75 s'], ['Acclimated 50%', '87.5%', '0.75 s'],
                 ['Desert Stormer 40%', '85%', '0.9 s']],
                'Vanilla stun: 1.5 s. Electrical Conduit also grounds arcs: they end at you instead of chaining on.')
    return f'''<!doctype html><html><head><meta charset="utf-8"><style>{FONTS}
      html,body {{ margin:0; width:{w}px; height:{h}px; overflow:hidden; background:#08090b; }}
      .bg {{ position:absolute; inset:0; background:
          repeating-linear-gradient(0deg, rgba(255,255,255,0.025) 0 1px, transparent 1px 45px),
          repeating-linear-gradient(90deg, rgba(255,255,255,0.025) 0 1px, transparent 1px 45px); }}
      .stripe {{ position:absolute; left:0; right:0; bottom:0; height:18px; background: repeating-linear-gradient(-45deg, {YELLOW} 0 29px, #111 29px 58px); }}
      .head {{ position:absolute; left:64px; top:46px; font-family:Anton; font-size:84px; color:#fff; letter-spacing:0.02em; }}
      .head span {{ color:{YELLOW}; }}
      .sub {{ position:absolute; left:68px; top:150px; font-family:Barlow; font-weight:600; font-size:30px; color:#cfcfcf; letter-spacing:0.05em; }}
      .grid {{ position:absolute; left:64px; right:64px; top:220px; bottom:60px; display:grid; grid-template-columns:1fr 1fr 1fr; gap:28px; }}
      .t {{ background:linear-gradient(180deg, rgba(255,255,255,0.06), rgba(255,255,255,0.015)); border:3px solid rgba(255,255,255,0.10);
        border-top:10px solid var(--c); padding:24px 22px; display:flex; flex-direction:column; }}
      .h {{ display:flex; align-items:center; gap:16px; }}
      .ic {{ width:96px; height:96px; }} .ic svg {{ width:100%; height:100%; overflow:visible; }}
      .tt {{ font-family:Anton; font-size:66px; letter-spacing:0.05em; }}
      table {{ border-collapse:collapse; margin-top:28px; width:100%; font-family:Barlow; }}
      th {{ text-align:left; color:#9a9a9a; font-weight:600; font-size:21px; letter-spacing:0.05em; padding:0 10px 10px 0; vertical-align:bottom; white-space:nowrap; }}
      td {{ color:#fff; font-weight:600; font-size:30px; padding:22px 10px 22px 0; border-top:2px solid rgba(255,255,255,0.08); }}
      td:first-child {{ color:#e8e8e8; font-weight:500; font-size:26px; white-space:nowrap; }}
      td:not(:first-child) {{ color:var(--c); white-space:nowrap; }}
      .n {{ margin-top:auto; font-family:Barlow; font-weight:500; font-size:26px; color:#b5b5b5; line-height:1.25; letter-spacing:0.02em; }}
    </style></head><body><div class="bg"></div><div class="stripe"></div>
      <div class="head">REALISTIC <span>RESISTANCES</span></div>
      <div class="sub">YOUR ARMOR PASSIVE'S RESISTANCE NOW ALSO RESISTS THE EFFECT &nbsp;&bull;&nbsp; TIMES: LIGHT / MEDIUM / HEAVY ARMOR</div>
      <div class="grid">{fire}{gas}{arc}</div></body></html>'''


# ---------------------------------------------------------------- option icons (256 x 256)
OPTION_ICONS = {   # file: (icon kind, label under it or None)
    'core': ('shield', 'CORE'),
    'fire': ('fire', None), 'fire_both': ('fire', 'BOTH'), 'fire_ignite': ('fire', 'HARDER TO IGNITE'), 'fire_extinguish': ('fire', 'SELF-EXTINGUISH'),
    'gas': ('gas', None), 'gas_both': ('gas', 'BOTH'), 'gas_buffer': ('gas', 'FILTRATION BUFFER'), 'gas_noslow': ('gas', 'NO GAS SLOW'),
    'arc': ('arc', None), 'arc_both': ('arc', 'BOTH'), 'arc_resist': ('arc', 'RESISTANCE'), 'arc_grounded': ('arc', 'GROUNDED'),
}


def icon_page(kind, label):
    f, color = (shield, YELLOW) if kind == 'shield' else ICONS[kind]
    size = 150 if label else 190
    lbl = f'<div class="l" style="color:{color}">{label}</div>' if label else ''
    fs = 30 if label and len(label) <= 10 else 24
    return f'''<!doctype html><html><head><meta charset="utf-8"><style>{FONTS}
      html,body {{ margin:0; width:256px; height:256px; overflow:hidden; background:#0b0c0f; }}
      .f {{ position:absolute; inset:0; border:10px solid {YELLOW}; box-sizing:border-box;
        background: radial-gradient(circle at 50% 42%, rgba(255,255,255,0.10), rgba(0,0,0,0) 60%); display:flex; flex-direction:column;
        align-items:center; justify-content:center; }}
      .i {{ width:{size}px; height:{size}px; }} .i svg {{ width:100%; height:100%; overflow:visible; }}
      .l {{ font-family:Anton; font-size:{fs}px; letter-spacing:0.04em; margin-top:4px; text-align:center; line-height:1; }}
    </style></head><body><div class="f"><div class="i">{f('o')}</div>{lbl}</div></body></html>'''


if __name__ == '__main__':
    os.makedirs(os.path.join(ART, 'options'), exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        def shot(html, w, h, path):
            pg = browser.new_page(viewport={'width': w, 'height': h})
            pg.set_content(html)
            pg.wait_for_timeout(300)
            pg.screenshot(path=path)
            pg.close()
        for name, (w, h, layout) in LAYOUTS.items():
            shot(page(w, h, layout), w, h, os.path.join(ART, name))
        shot(values_page(), 1920, 1080, os.path.join(ART, 'values_1920x1080.png'))
        for name, (kind, label) in OPTION_ICONS.items():
            shot(icon_page(kind, label), 256, 256, os.path.join(ART, 'options', name + '.png'))
        browser.close()
    Image.open(os.path.join(ART, 'thumbnail_1254.png')).resize((512, 512), Image.LANCZOS).save(os.path.join(ART, 'thumbnail_512.png'))
    print('art done')

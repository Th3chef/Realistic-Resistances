-- HD2-Addon: mods/chef/realistic_resistances
-- Realistic Resistances (elemental: fire, gas and arc): armor passives that resist fire, gas or arc damage also resist the burning, gas and electric
-- effects themselves, the way real protective gear does. The resistance is the passive's own value:
--   Harder to Ignite: fire takes a flat time to set you alight. Medium armor is the baseline (75% resistance:
--   2 s; 50%: 1 s), light is 0.75x and heavy 1.25x of that.
--   Self-Extinguish: once you are out of the flames the burn runs out sooner, by the same resistance.
--   Gas Resistance: gas builds up slower, by the armor's gas resistance, and wears off
--   sooner once you are out. No Gas Slow: with 80% or more the gas's stumbling/slowing never takes hold.
--   Arc Resistance: the same for the electric effect, by the armor's arc resistance, and arc-resistant passives
--   take a quarter of the arc damage they did, and the stun from an arc hit is shorter by the same resistance. Grounded (Electrical Conduit): arcs end at you instead of chaining on.
-- In the mod manager each resistance is an option with sub-options (both parts / only one); with CowboyBingus's
-- Mod Options Menu installed the same three choices are in the game's MODS tab and change at once.
-- Only your own helldiver is changed. The damage itself is left to the game (the passive already reduces it).
-- Everything the mod needs is found in the game's code by pattern, so a game patch that moves things around does
-- not break it; if something can't be found it stays off and says so in its log.
-- Log: %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\RealisticResistances.log

local bit = require('bit')
local ffi = require('ffi')
local VERSION = '0.1.0 Test 13'
local TESTER = true       -- tester logging (extra detail in the log); off in the release
local TEST_LOGS = true    -- numbered test builds log to Logs\test; releases and the release Tester to Logs
local LOG_NAME = 'RealisticResistances.log'

-- ---------------------------------------------------------------- tuning (only needs retuning if the game
-- changes how burning, gas or arc work)
local OUT_GRACE = 0.25   -- seconds an effect must run down without being refreshed before you count as out of it
local MIN_TAIL = 0.25    -- shortest time an effect is left to run after you are out of it
local NO_CONFUSION = 0.2 -- gas resistance multiplier at or below which (80%+, Advanced Filtration) the gas's
                         -- movement effect (Gas_Confusion: the stumbling and slowing) never takes hold
local DECAY = 4.0 / 3.0  -- share of the take-hold value lost per second once a build-up stops rising
local CATCH_TIME = { [0] = 0.75, [1] = 1.0, [2] = 1.25 }  -- seconds in it before it takes hold for a
                         -- 75%-resistant armor: light / medium / heavy, however strong the source. Medium is the
                         -- baseline: other resistance scales the medium time (50% -> half, 80% -> 1.25x, 0% -> the
                         -- game's own ~0.2 s), it is rounded, and light / heavy are 0.75x / 1.25x of that
-- Gas is not timed flat like fire: its own build-up is slowed by the armor's gas resistance, so a thick cloud and a
-- thin one both take longer. Gas takes hold after its own time x (1 / damage multiplier) x the weight factor
-- (light 0.75, medium 1, heavy 1.25): Acclimated (50%) 2x in medium armor, Advanced Filtration (80%) 5x.
local FIRE_SCALE = 2.0   -- fire takes twice the times above (real fire-resistant gear doesn't catch that fast):
                         -- Inflammable 1.5 / 2 / 2.5 s, Acclimated and KDM 1 s, Desert Stormer 0.85 s in medium armor
local CATCH_REF = 0.25   -- the damage multiplier those times are for (75% resistance, e.g. Inflammable)
local ARC_BOOST = 4.0    -- arc damage resistance boost: an arc-resistant passive lets through 1/ARC_BOOST of the arc
                         -- damage it did before (Electrical Conduit 95% -> 98.75%, Adreno-Defibrillator 50% -> 87.5%; x4 so a
                         -- 50% passive survives one Tesla Tower hit: 600 damage -> 75)
local ARC_STAT = 0x4BDF39C4   -- the passives' arc damage modifier (boosted)
local ALL_STAT = 0xB5A50096   -- the all-elements modifier (Acclimated, Desert Stormer): the game multiplies it with
                              -- the arc one, so these passives get an arc modifier of 1/ARC_BOOST added (fire and
                              -- gas unchanged): Acclimated 50% -> 87.5% arc, Desert Stormer 40% -> 85%
local WEIGHT_NAMES = { [0] = 'light', [1] = 'medium', [2] = 'heavy' }

-- statuses (status table ids) and the stats (passive modifier hashes) that resist them. hold = the build-up value
-- at which the game makes the status take hold (fire 3, gas 0.5; others are learned the first time one takes hold)
local KINDS = {
  fire = { ids = { [5] = 'Fire' }, stats = { 0x4DF29271, 0xB5A50096 } },
  gas = { ids = { [42] = 'Gas', [43] = 'Gas', [44] = 'Gas_Confusion', [45] = 'Gas_Confusion' }, stats = { 0x6E99CCE5, 0xB5A50096 } },
  arc = { ids = { [35] = 'Electric' }, stats = { 0x4BDF39C4, 0xB5A50096 } },
}
local KIND_OF = {}
for kind, def in pairs(KINDS) do for id in pairs(def.ids) do KIND_OF[id] = kind end end
local HOLD = { [5] = 3.0, [42] = 0.5, [43] = 0.5, [44] = 0.5, [45] = 0.5 }
local CONFUSION_IDS = { [44] = true, [45] = true }   -- the gas's movement effect (stumbling, slowing)
-- arc hits stun you: each hit puts on a Stun Small (37) at once (no build-up), 1.5 s in tests. With arc
-- resistance the stun is cut to its length x the arc damage multiplier, not rounded, so it matches the passive's
-- percentage: Electrical Conduit (95%) 0.075 s, Adreno-Defibrillator / Acclimated (50%) 0.75 s, Desert Stormer 0.9 s. (The game doesn't say what caused a stun, so while you wear
-- arc resistance every Stun Small is shortened.)
local ARC_STUN_IDS = { [37] = true }
local LOCATE_EVERY = 0.25
local MAX_LINES = TESTER and 6000 or 300

if rawget(_G, 'RealisticResistances') then return end
local S = { status = 'starting', frame = 0, events = {}, dirty = true, stats = { writes = 0, write_failures = 0 } }
for kind in pairs(KINDS) do S.stats[kind] = { caught = 0, kept = 0, cut = 0, saved = 0, stumble = 0, stun = 0, stun_saved = 0, grounded = 0 } end
rawset(_G, 'RealisticResistances', S)
local BOOSTED
local GRAFTED = {}   -- passive table -> { orig_list, orig_n, list, n }: the mod's own copy of its modifiers + arc

local STATUS_NAMES = { [2] = 'Bleed', [5] = 'Fire', [6] = 'Fire_Panic', [7] = 'Lava', [8] = 'Slowed', [9] = 'Rooted', [12] = 'Thermite',
  [13] = 'Cyborg Fire', [18] = 'Submerged', [25] = 'Stim Fx', [26] = 'Stim Stamina', [27] = 'Stim Heal', [30] = 'Stim Cooldown',
  [31] = 'BurningLight', [32] = 'BurningHeavy', [35] = 'Electric', [37] = 'Stun Small', [38] = 'Stun Medium', [39] = 'Stun Large',
  [40] = 'Stun Massive', [41] = 'Stun Illuminate', [42] = 'Gas', [43] = 'Gas', [44] = 'Gas_Confusion', [45] = 'Gas_Confusion',
  [46] = 'Inverted_Aim_Assist', [67] = 'FlamerSlowed', [68] = 'Gloom', [70] = 'Poison', [71] = 'PoisonVulnerability' }

-- ---------------------------------------------------------------- where things are in the game
-- Each pattern is a piece of game.dll code ('??' = bytes that change between builds); the values the mod needs are
-- read out of the matched code. rva = where it sits in the Sept 2026 build (checked first, so a known build needs
-- no scan). A pattern may match more than once if every match gives the same values.
local PATTERNS = {
  { name = 'status', rva = 0xC22AC, p = '4c8b1d????????33d248896c2450458b8b????????418b9b????????0fafd8',
    f = { g = { 'rip', 3 }, cap = { 'u32', 17 }, mult = { 'u32', 24 } } },
  { name = 'blocks', rva = 0x699D14, p = '8bc24c69d0????????33c04c0391????????458b5a??4585db74??90488d0c404803c9453984ca????????75??45398cca????????',
    f = { stride = { 'u32', 5 }, blocks = { 'u32', 14 }, count = { 'u8', 21 }, ent4 = { 'u32', 39 }, ent = { 'u32', 49 } } },
  { name = 'passives', rva = 0x11D9EF5, p = '4c8b0d????????448bc7458b91????????418bb1????????0faff1',
    f = { g = { 'rip', 3 }, cap = { 'u32', 13 }, mult = { 'u32', 20 } } },
  { name = 'record', rva = 0x11D9F7D, p = '4c6bd8??438b840b????????85c074??41f6c40174??418b4c81??83f9ff74??498b41??',
    f = { stride = { 'u8', 3 }, slot_a = { 'u32', 8 }, tbl = { 'u8', 26 }, list = { 'u8', 35 } } },
  { name = 'record2', rva = 0x11D9FDA, p = '438b840b????????85c074??41f6c40274??418b4c81', f = { slot_b = { 'u32', 4 } } },
  { name = 'link', rva = 0x11D9E19, p = '4c8b1d????????448bc7458b8b????????418bb3????????0faff1',
    f = { g = { 'rip', 3 }, cap = { 'u32', 13 }, mult = { 'u32', 20 } } },
  { name = 'linkrec', rva = 0x11D9ECA, p = 'b8ffffffff8bc8486bc1??488d4c2450428b9418????????e8', f = { stride = { 'u8', 10 }, rec = { 'u32', 20 } } },
  { name = 'owners', rva = 0xFD9BA4, p = '4c8b1d????????448bc24c8bc981faff7f000075??8b05????????', f = { g = { 'rip', 3 } } },
  { name = 'ownidx', rva = 0xFD9BC9, p = '458b93????????33d248895c2410418b9b????????48896c2418410fafd8', f = { cap = { 'u32', 3 }, mult = { 'u32', 17 } } },
  { name = 'ownrows', rva = 0xFD9C44, p = '44390075??8b4004488d0440488d80????????498d04c38b00418901', f = { rows8 = { 'u32', 15 } } },
  { name = 'wtype', rva = 0x878216, p = '33db468b8417????????4533c933c9e8', f = { type = { 'u32', 6 } } },
  { name = 'witem', rva = 0x8781ED, p = '458b4a??33c9486bf844428b9417????????4585c974??4d8b1a', f = { item = { 'u32', 14 } } },
  { name = 'wentry', rva = 0x11D9247, p = '8b70??4533c033ff85f60f84????????4183f81e73??4d8b5e??', f = { count = { 'u8', 2 }, groups = { 'u8', 25 } } },
  { name = 'players', rva = 0x3A4BDE, p = '488b05????????488d542448488b88e8000000', f = { g = { 'rip', 3 } } },
  -- (optional) the arc manager: 256 arcs in flight (for Grounded). Code that fires an arc weapon:
  -- mov rcx, [arc manager]; call <fire arc>; cmp edi, [...]; je
  { name = 'arcmgr', rva = 0x80DC2E, optional = true, p = '488b0d????????e8????????3b3d????????0f84', f = { g = { 'rip', 3 } } },
}
local PLAYER_COUNTS, PLAYER_AVATAR = 132, 936     -- players table: player counts, your helldiver (as Smarter Guard Dogs)

-- ---------------------------------------------------------------- memory access
local api
local function build_api()
  for _, d in ipairs({
    'void *GetCurrentProcess(void);',
    'void *GetModuleHandleA(const char *name);',
    'int ReadProcessMemory(void *p, const void *a, void *b, size_t n, size_t *r);',
    'int WriteProcessMemory(void *p, void *a, const void *b, size_t n, size_t *w);',
    'size_t VirtualQuery(const void *a, void *info, size_t n);',
    'int QueryPerformanceCounter(int64_t *c);',
    'int QueryPerformanceFrequency(int64_t *f);',
    'void *VirtualAlloc(void *a, size_t n, uint32_t type, uint32_t prot);',
    'uint32_t GetEnvironmentVariableA(const char *name, char *b, uint32_t n);',
    'int SetEnvironmentVariableA(const char *name, const char *value);',
  }) do pcall(ffi.cdef, d) end
  pcall(ffi.cdef, [[typedef struct { void *base; void *allocation_base; uint32_t allocation_protection;
    uint16_t partition; uint16_t reserved; size_t size; uint32_t state; uint32_t protection; uint32_t type; } RRRegion;]])
  local k32 = ffi.load('kernel32')
  local proc = k32.GetCurrentProcess()
  local got = ffi.new('size_t[1]')
  local region = ffi.new('RRRegion[1]')
  local ticks, freq = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
  k32.QueryPerformanceFrequency(freq)
  local per_second = tonumber(freq[0])
  local buf = ffi.new('uint8_t[?]', 0x2000)
  local a = {}
  function a.read(address, n)
    if not address or address < 0x10000 or address > 0x7FFFFFFFFFFF then return nil end
    local b = n <= 0x2000 and buf or ffi.new('uint8_t[?]', n)
    if k32.ReadProcessMemory(proc, ffi.cast('const void *', address), b, n, got) == 0 or tonumber(got[0]) ~= n then return nil end
    return ffi.string(b, n)
  end
  -- the same read without making a Lua string: returns the shared buffer, valid until the next read
  function a.peek(address, n)
    if not address or address < 0x10000 or address > 0x7FFFFFFFFFFF or n > 0x2000 then return nil end
    if k32.ReadProcessMemory(proc, ffi.cast('const void *', address), buf, n, got) == 0 or tonumber(got[0]) ~= n then return nil end
    return buf
  end
  -- writes only into private read/write heap memory (never code)
  function a.write(address, bytes)
    if not address or address < 0x10000 or address > 0x7FFFFFFFFFFF then return false end
    if k32.VirtualQuery(ffi.cast('const void *', address), region, ffi.sizeof('RRRegion')) == 0 then return false end
    if region[0].state ~= 0x1000 or region[0].type ~= 0x20000 or region[0].protection ~= 0x04 then return false end
    return k32.WriteProcessMemory(proc, ffi.cast('void *', address), bytes, #bytes, got) ~= 0 and tonumber(got[0]) == #bytes
  end
  function a.now() k32.QueryPerformanceCounter(ticks); return tonumber(ticks[0]) / per_second end
  -- private read/write memory for the mod's own modifier lists (never freed, so the game can never be left
  -- pointing at freed memory)
  function a.alloc(n)
    local p = k32.VirtualAlloc(nil, n, 0x3000, 0x04)
    return p ~= nil and tonumber(ffi.cast('uintptr_t', p)) or nil
  end
  --@tester-begin
  -- tester only: F8 drops a numbered mark in the log (so a moment in game can be found in it)
  if TESTER then
    pcall(ffi.cdef, 'short GetAsyncKeyState(int key);')
    local okk, u32dll = pcall(ffi.load, 'user32')
    if okk then function a.key_down(vk) return bit.band(u32dll.GetAsyncKeyState(vk), 0x8000) ~= 0 end end
  end
  --@tester-end
  -- the process environment (kept across a reload of the mod, gone when the game closes)
  local envbuf = ffi.new('char[4096]')
  function a.env_get(name)
    local n = k32.GetEnvironmentVariableA(name, envbuf, 4096)
    if n == 0 or n >= 4096 then return nil end
    return ffi.string(envbuf, n)
  end
  function a.env_set(name, value) return k32.SetEnvironmentVariableA(name, value) ~= 0 end
  function a.base()
    local h = k32.GetModuleHandleA('game.dll')
    return h ~= nil and tonumber(ffi.cast('uintptr_t', h)) or nil
  end
  return a
end

local function u32(s, o)
  local a, b, c, d = s:byte(o + 1, o + 4)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end
local function i32(s, o) local v = u32(s, o); if v and v >= 2147483648 then v = v - 4294967296 end; return v end
local function u64(s, o) local lo, hi = u32(s, o), u32(s, o + 4); if not hi then return nil end; return lo + hi * 4294967296 end
local fbox = ffi.new('float[1]')
local function f32_at(s, o) ffi.copy(fbox, s:sub(o + 1, o + 4), 4); return tonumber(fbox[0]) end
local function f32_bytes(x) fbox[0] = x; return ffi.string(fbox, 4) end
local function u32_bytes(v)
  v = v % 4294967296
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
-- reads without Lua strings (hot paths): peek returns a byte buffer valid until the next read; values are taken out
-- of it at once. (The simulator's api has no peek: it falls back to read + a copy.)
local pbuf = ffi.new('uint8_t[?]', 0x2000)
local function peek(address, n)
  if api.peek then return api.peek(address, n) end
  local s = api.read(address, n)
  if not s then return nil end
  ffi.copy(pbuf, s, n)
  return pbuf
end
local function pu32(b, o) return tonumber(ffi.cast('uint32_t *', b + o)[0]) end
local function pf32(b, o) return tonumber(ffi.cast('float *', b + o)[0]) end
local function pu64(b, o) return tonumber(ffi.cast('uint64_t *', b + o)[0]) end

local function rptr(address)
  local b = peek(address, 8)
  local p = b and pu64(b, 0)
  if not p or p < 0x10000 or p > 0x7FFFFFFFFFFF then return nil end
  return p
end

local function map_lookup(base, key)   -- base: slots ptr at +0, cap +8, empty +12, mult +16
  local h = peek(base, 20)
  if not h then return nil end
  local slots, cap, empty, mult = pu64(h, 0), pu32(h, 8), pu32(h, 12), pu32(h, 16)
  if slots < 0x10000 or cap == 0 or cap > 1048576 or bit.band(cap, cap - 1) ~= 0 then return nil end
  local mlo = mult % 65536
  local hash = (key * mlo + (key * ((mult - mlo) / 65536) % 65536) * 65536) % 4294967296
  for i = 0, math.min(cap, 256) - 1 do
    local e = peek(slots + 8 * bit.band(hash + i, cap - 1), 8)
    if not e then return nil end
    local k = pu32(e, 0)
    if k == key then local v = pu32(e, 4); return v ~= 4294967295 and v or nil end
    if k == empty then return nil end
  end
  return nil
end

--@tester-begin
local function map_all(base, limit)    -- every (key, value) in a map (tester research)
  local h = api.read(base, 20)
  if not h then return {} end
  local slots, cap, empty = u64(h, 0), u32(h, 8), u32(h, 12)
  local out = {}
  if not slots or cap == 0 or cap > 65536 then return out end
  for start = 0, cap - 1, 512 do
    local n = math.min(512, cap - start)
    local s = api.read(slots + 8 * start, 8 * n)
    if not s then break end
    for i = 0, n - 1 do
      local k, v = u32(s, 8 * i), u32(s, 8 * i + 4)
      if k ~= empty and v ~= 4294967295 then out[#out + 1] = { k, v } end
      if #out >= limit then return out end
    end
  end
  return out
end
--@tester-end

-- ---------------------------------------------------------------- log
-- Release builds log to the Bingus loader's Logs folder; test builds to Logs\test (when it exists)
local LOGDIR
local function log_dir()
  local base = os.getenv('LOCALAPPDATA')
  if not base or base == '' then return nil end
  local dirs = { base .. '\\CowboyBingus\\Helldivers2\\Logs', base }
  if TEST_LOGS then table.insert(dirs, 1, base .. '\\CowboyBingus\\Helldivers2\\Logs\\test') end
  for _, d in ipairs(dirs) do
    local f = io.open(d .. '\\' .. LOG_NAME, 'ab')
    if f then f:close(); return d end
  end
  return nil
end

local function event(text)
  local ev = S.events
  ev[#ev + 1] = string.format('[%s +%.2f] %s', os.date('%H:%M:%S'), api and S.t0 and (api.now() - S.t0) or 0, text)
  if #ev > MAX_LINES + 50 then   -- (full: the oldest lines go, 50 at a time, so the newest are always kept)
    local n = #ev
    for i = 51, n do ev[i - 50] = ev[i] end
    for i = n, n - 49, -1 do ev[i] = nil end
    S.dropped = (S.dropped or 0) + 50
  end
  S.dirty = true
end
-- errors: each different one is kept (never dropped with old lines), with how many times it happened
local function log_error(e)
  e = tostring(e)
  S.errors = S.errors or {}
  local x = S.errors[e]
  if x then x.n = x.n + 1; return end
  if #S.errors >= 20 then return end
  S.errors[e] = { n = 1 }
  S.errors[#S.errors + 1] = e
  S.err_logged = true
  event('error: ' .. e)
end
local function write_log()
  S.dirty = false
  pcall(function()
    LOGDIR = LOGDIR or log_dir()
    if not LOGDIR then return end
    local st = S.stats
    local function on(x) return x and 'on' or 'off' end
    -- (the summary is built before the file is opened, and a summary error still leaves the events in the log)
    local okh, out = pcall(function() return { 'Realistic Resistances ' .. VERSION .. (TESTER and ' (tester)' or ''), 'started ' .. (S.started or '?'),
      'status: ' .. S.status,
      string.format('options: harder to ignite %s, self-extinguish %s, gas resistance %s, no gas slow %s, arc resistance %s, grounded %s',
        on(S.opt_ign), on(S.opt_ext), on(S.opt_gas), on(S.opt_slow), on(S.opt_arc), on(S.opt_ground)),
      'options menu: ' .. (S.options_menu or 'not installed (or not found yet)'),
      'armor: ' .. (S.armor or '?'),
      string.format('fire: caught %d time(s), kept from catching %d, cut short %d (%.1f s of burning saved)',
        st.fire.caught, st.fire.kept, st.fire.cut, st.fire.saved),
      string.format('gas: took hold %d time(s), kept off %d, cut short %d (%.1f s saved); stumbling/slowing blocked %d time(s)',
        st.gas.caught, st.gas.kept, st.gas.cut, st.gas.saved, st.gas.stumble),
      string.format('arc: took hold %d time(s), kept off %d, cut short %d (%.1f s saved); stuns shortened %d (%.1f s saved); arcs grounded %d',
        st.arc.caught, st.arc.kept, st.arc.cut, st.arc.saved, st.arc.stun, st.arc.stun_saved, st.arc.grounded),
      string.format('memory writes: %d, write failures %d', st.writes, st.write_failures),
      '', 'events:' } end)
    if not okh then out = { 'Realistic Resistances ' .. VERSION, 'log summary error: ' .. tostring(out), '', 'events:' } end
    if S.errors and #S.errors > 0 then
      table.insert(out, #out - 1, 'errors:')
      for _, e in ipairs(S.errors) do table.insert(out, #out - 1, string.format('  %s (%d time(s))', e, S.errors[e].n)) end
    end
    if S.dropped then out[#out + 1] = string.format('  (%d older line(s) left out)', S.dropped) end
    local f = io.open(LOGDIR .. '\\' .. LOG_NAME, 'wb')
    if not f then return end
    f:write(table.concat(out, '\r\n'), '\r\n')
    if #S.events > 0 then f:write('  ', table.concat(S.events, '\r\n  '), '\r\n') end
    f:close()
  end)
end

-- ---------------------------------------------------------------- finding the game's layout
local function compile(p)
  local segs, cur_off, cur = {}, nil, {}
  local n = #p / 2
  for k = 0, n - 1 do
    local h = p:sub(2 * k + 1, 2 * k + 2)
    if h == '??' then
      if cur_off then segs[#segs + 1] = { cur_off, table.concat(cur) }; cur_off, cur = nil, {} end
    else
      cur_off = cur_off or k
      cur[#cur + 1] = string.char(tonumber(h, 16))
    end
  end
  if cur_off then segs[#segs + 1] = { cur_off, table.concat(cur) } end
  local anchor = 1
  for j = 2, #segs do if #segs[j][2] > #segs[anchor][2] then anchor = j end end
  return segs, anchor, n
end

local function match_at(text, start, segs, n)
  if start < 0 or start + n > #text then return false end
  for _, seg in ipairs(segs) do
    if text:sub(start + seg[1] + 1, start + seg[1] + #seg[2]) ~= seg[2] then return false end
  end
  return true
end

local function find_all(text, p)
  local segs, anchor, n = compile(p)
  local a, out, init = segs[anchor], {}, 1
  while #out < 8 do
    local s = string.find(text, a[2], init, true)
    if not s then break end
    local start = s - 1 - a[1]
    if match_at(text, start, segs, n) then out[#out + 1] = start end
    init = s + 1
  end
  return out
end

local function extract(text, o, text_rva, fields)
  local v = {}
  for name, spec in pairs(fields) do
    if spec[1] == 'rip' then v[name] = text_rva + o + spec[2] + 4 + i32(text, o + spec[2])
    elseif spec[1] == 'u32' then v[name] = u32(text, o + spec[2])
    else v[name] = text:byte(o + spec[2] + 1) end
  end
  return v
end

local function same(a, b) for k, x in pairs(a) do if b[k] ~= x then return false end end return true end

local function code_section(base)
  local h = api.read(base, 0x400)
  if not h then return nil end
  local pe = u32(h, 0x3C)
  local count, optsize = h:byte(pe + 7) + 256 * h:byte(pe + 8), h:byte(pe + 21) + 256 * h:byte(pe + 22)
  for i = 0, count - 1 do
    local s = pe + 24 + optsize + 40 * i
    local vsize, rva, flags = u32(h, s + 8), u32(h, s + 12), u32(h, s + 36)
    if flags and bit.band(flags, 0x20000000) ~= 0 and vsize > 0x100000 then return rva, vsize end
  end
  return nil
end

local L   -- the layout: absolute addresses of the globals and the offsets read out of the code
local function resolve_layout()
  local base = api.base()
  if not base then return nil, 'game.dll not loaded' end
  local V, missing = {}, {}
  -- fast path: each piece of code where it sits in the build the mod was made for
  for _, P in ipairs(PATTERNS) do
    local segs, _, n = compile(P.p)
    local code = api.read(base + P.rva, n)
    if code and match_at(code, 0, segs, n) then V[P.name] = extract(code, 0, P.rva, P.f)
    else missing[#missing + 1] = P end
  end
  local how = 'known game version'
  if #missing > 0 then
    -- the game changed: look for the rest in its code
    local t0 = api.now()
    local rva, size = code_section(base)
    if not rva then return nil, 'cannot read the game code' end
    local text = api.read(base + rva, size)
    if not text then return nil, 'cannot read the game code' end
    for _, P in ipairs(missing) do
      local hits = find_all(text, P.p)
      if #hits == 0 and not P.optional then return nil, 'game changed: ' .. P.name .. ' not found' end
      if #hits > 0 then
        local v = extract(text, hits[1], rva, P.f)
        for i = 2, #hits do
          if not same(v, extract(text, hits[i], rva, P.f)) then return nil, 'game changed: ' .. P.name .. ' found in several places' end
        end
        V[P.name] = v
      end
    end
    text = nil
    how = string.format('new game version: %d piece(s) found again in %.1f s', #missing, api.now() - t0)
  end
  -- checks: the maps' fields must sit together the way the game's hash maps do
  local function chk(ok, what) if not ok then error('layout check failed: ' .. what, 0) end end
  chk(V.status.mult == V.status.cap + 8 and V.passives.mult == V.passives.cap + 8 and V.link.mult == V.link.cap + 8
    and V.ownidx.mult == V.ownidx.cap + 8, 'map fields')
  chk(V.blocks.ent4 == V.blocks.ent + 4 and V.blocks.stride > V.blocks.ent, 'status blocks')
  L = {
    status = base + V.status.g, smap = V.status.cap - 8,
    blocks = V.blocks.blocks, bstride = V.blocks.stride, bcount = V.blocks.count, entries = V.blocks.ent,
    passives = base + V.passives.g, pmap = V.passives.cap - 8,
    rstride = V.record.stride, slots = { V.record.slot_a, V.record2.slot_b }, ptable = V.record.tbl, plist = V.record.list,
    link = base + V.link.g, lmap = V.link.cap - 8, lstride = V.linkrec.stride, lrec = V.linkrec.rec,
    owners = base + V.owners.g, omap = V.ownidx.cap - 8, orows = V.ownrows.rows8 * 8 - 8,
    wtype = V.wtype.type, witem = V.witem.item, ecount = V.wentry.count, egroups = V.wentry.groups,
    players = base + V.players.g,
    arcmgr = V.arcmgr and (base + V.arcmgr.g) or nil,
  }
  return true, how
end

-- ---------------------------------------------------------------- your helldiver and its armor
local function owner_of(id)   -- owner row of an entity id: (owner id, unit, local?)
  local owners = rptr(L.owners)
  if not owners then return nil end
  local e = map_lookup(owners + L.omap, id)
  local row = e and api.read(owners + L.orows + e * 24, 24)
  if not row then return nil end
  return u32(row, 8), u32(row, 12), bit.band(row:byte(21), 3) == 1
end

local function find_player()
  local players = rptr(L.players)
  if not players then return nil, 'no players table' end
  local pp = api.read(players + PLAYER_COUNTS, 8)
  if not pp or u32(pp, 0) == 0 or u32(pp, 4) == 0 then return nil, 'no local player yet' end
  local avatar = u32(api.read(players + PLAYER_AVATAR, 4) or '\255\127\0\0', 0)
  if avatar == 32767 then return nil, 'no helldiver yet' end
  local owner, unit, is_local = owner_of(avatar)
  if not owner or not is_local then return nil, 'no helldiver yet' end   -- (only ever your own helldiver)
  return { avatar = avatar, owner = owner, unit = unit, is_local = is_local }
end

-- arc damage modifiers the mod has boosted: address -> { orig = the game's value, new = the boosted value }
BOOSTED = {}

-- the passive table(s) an entity's armor uses: entity -> passive map -> record -> slot -> passive table
local function passive_of(key)
  local g = rptr(L.passives)
  if not g then return nil end
  local idx = map_lookup(g + L.pmap, key)
  if not idx then return nil end
  local found, seen, list = {}, {}, nil
  for _, off in ipairs(L.slots) do
    local r = api.read(g + idx * L.rstride + off, 4)
    local a = r and u32(r, 0)
    if a and a ~= 0 and a < 100000 then
      local kr = api.read(g + a * 4 + L.ptable, 4)
      local k = kr and u32(kr, 0)
      list = list or rptr(g + L.plist)
      local pp = (k and k ~= 4294967295 and list) and rptr(list + k * 8)
      local head = pp and not seen[pp] and api.read(pp, 32)   -- (the same table in both slots counts once)
      if head then
        seen[pp] = true
        local stats, n, ml = {}, u32(head, 24), u64(head, 16)
        local gr = GRAFTED[pp]
        if gr and ml == gr.list then n, ml = gr.orig_n, gr.orig_list end   -- (the game's own modifiers)
        local at = {}
        n = math.min(n or 0, 8)
        local mods = n > 0 and ml and ml >= 0x10000 and api.read(ml, 16 * n)   -- (all modifiers in one read)
        for i = 0, (mods and n or 0) - 1 do
          if u32(mods, 16 * i + 4) == 2 then   -- (op 2 = multiplies the damage)
            local addr, stat = ml + 16 * i + 8, u32(mods, 16 * i)
            if not stats[stat] then   -- (the game uses the first modifier of each stat)
              stats[stat] = BOOSTED[addr] and BOOSTED[addr].orig or f32_at(mods, 16 * i + 8)   -- (the game's own value)
              at[stat] = addr
            end
          end
        end
        found[#found + 1] = { id = u32(head, 0), name = u32(head, 4), stats = stats, at = at, pp = pp, ml = ml, n = n }
      end
    end
  end
  return found, g, idx
end

-- weight of the body armor (0 light, 1 medium, 2 heavy), the way the game works out its armor rating: the armor
-- item's pieces of the worn type each carry a level; the rating is their average
local weight_cache = {}   -- 'kind:item' -> { weight, description }: armor item data doesn't change in a session
local function armor_weight(g, idx)
  local kr, ir = idx and api.read(g + idx * L.rstride + L.wtype, 4), idx and api.read(g + idx * L.rstride + L.witem, 4)
  if not kr or not ir then return nil end
  local kind, item = u32(kr, 0), u32(ir, 0)
  local ck = kind .. ':' .. item
  local c = weight_cache[ck]
  if c then return c[1], c[2] end
  local h = api.read(g, 16)
  local list, n = h and u64(h, 0), h and u32(h, 8)
  if not list or not n or n == 0 or n > 4096 then return nil end
  local entry
  for start = 0, n - 1, 512 do
    local m = math.min(512, n - start)
    local s = api.read(list + 8 * start, 8 * m)
    if not s then return nil end
    for i = 0, m - 1 do
      local p = u64(s, 8 * i)
      local id = p and api.read(p, 4)
      if id and u32(id, 0) == item then entry = p break end
    end
    if entry then break end
  end
  if not entry then return nil end
  local gp, gc = api.read(entry + L.egroups, 8), api.read(entry + L.ecount, 4)
  local groups, ng = gp and u64(gp, 0), gc and u32(gc, 0)
  if not groups or not ng or ng > 64 then return nil end
  local sum, count = 0, 0
  for gi = 0, ng - 1 do
    local gr = api.read(groups + 24 * gi, 24)
    if gr and (u32(gr, 0) == kind or u32(gr, 0) == 3) then
      local pieces, np = u64(gr, 8), u32(gr, 16)
      for pi = 0, math.min(np or 0, 30) - 1 do
        local pc = api.read(pieces + 96 * pi, 20)
        local slot = pc and u32(pc, 8)
        if pc and u32(pc, 12) == 0 and slot >= 2 and slot <= 10 and slot ~= 3 then
          local lvl = u32(pc, 16)
          if lvl <= 2 then sum, count = sum + lvl, count + 1 end
        end
      end
    end
  end
  if count == 0 then return nil end
  c = { math.floor(sum / count + 0.5), string.format('item %08X type %d, %d piece(s), average level %.2f', item, kind, count, sum / count) }
  weight_cache[ck] = c
  return c[1], c[2]
end

-- the key the passive map uses: the game asks with your helldiver's owner id, which the link map redirects
local function link_key(owner)
  local g1 = rptr(L.link)
  local li = g1 and map_lookup(g1 + L.lmap, owner)
  if not li then return nil end
  local r = api.read(g1 + L.lrec + li * L.lstride, 4)
  local target = r and u32(r, 0)
  if not target or target == 32767 then return nil end
  return (owner_of(target))
end

--@tester-begin
-- tester research: every entity the passive map knows
local function passive_map_dump()
  local g = rptr(L.passives)
  if not g then return 'no passive table' end
  local parts = {}
  for _, kv in ipairs(map_all(g + L.pmap, 24)) do
    local t = {}
    for _, x in ipairs(passive_of(kv[1]) or {}) do t[#t + 1] = tostring(x.id) end
    parts[#parts + 1] = string.format('%d->[%s]', kv[1], table.concat(t, ','))
  end
  return table.concat(parts, ' ')
end

-- tester research (private passive copy): how the passive tables are reached. Logs the pointer list at
-- [g + plist] (how many valid entries, their passive ids), the header words around it, and for each helldiver in
-- the passive map its record's slot values a, the k = [g + a*4 + ptable] they map to and the table at list[k]
local function passive_layout_dump()
  local g = rptr(L.passives)
  if not g then return end
  local h = api.read(g, 0x30)
  if h then
    local w = {}
    for o = 0, 0x2C, 4 do w[#w + 1] = string.format('%X', u32(h, o)) end
    event('  passives header: ' .. table.concat(w, ' '))
  end
  local list = rptr(g + L.plist)
  if list then
    local ids, n, last, miss = {}, 0, -1, 0
    for k = 0, 511 do
      local t = rptr(list + k * 8)
      local hd = t and api.read(t, 4)
      if hd then n, last, miss = n + 1, k, 0; ids[#ids + 1] = string.format('%d:%d', k, u32(hd, 0))
      else miss = miss + 1; if miss >= 16 then break end end
    end
    local after = api.read(list + (last + 1) * 8, 16)
    event(string.format('  passive list at %X: %d valid entries, last index %d (%s); after it: %s', list, n, last, table.concat(ids, ' '),
      after and string.format('%X %X %X %X', u32(after, 0), u32(after, 4), u32(after, 8), u32(after, 12)) or '?'))
  end
  local slots = api.read(g + L.ptable, 0x100)
  if slots then
    local w = {}
    for i = 0, 63 do local v = u32(slots, i * 4); w[#w + 1] = v == 4294967295 and '-' or tostring(v) end
    event('  slot array (first 64): ' .. table.concat(w, ' '))
  end
  for _, kv in ipairs(map_all(g + L.pmap, 24)) do
    local idx = kv[2]
    local parts = {}
    for _, off in ipairs(L.slots) do
      local r = api.read(g + idx * L.rstride + off, 4)
      local a = r and u32(r, 0)
      local kr = a and a < 100000 and api.read(g + a * 4 + L.ptable, 4)
      parts[#parts + 1] = string.format('+%X a=%s k=%s', off, tostring(a), kr and tostring(u32(kr, 0)) or '?')
    end
    event(string.format('  key %d idx %s: %s', kv[1], tostring(idx), table.concat(parts, ', ')))
  end
end
--@tester-end

-- ---------------------------------------------------------------- status entries
-- times are rounded to the nearest 0.05 s, so they stay easy to read but keep following the resistance
local function nice(t) return math.floor(t * 20 + 0.5) / 20 end
local me = { owner = nil, mult = { fire = 1, gas = 1, arc = 1 }, weight = 1, catch = {}, slow = {} }
-- the take-hold time (fire, arc) and the build-up slowing (gas) for your armor, worked out when it changes: medium armor
-- is the baseline (rounded); light and heavy are worked out from that rounded time
local function set_timings()
  local wf = (CATCH_TIME[me.weight] or CATCH_TIME[1]) / CATCH_TIME[1]
  for kind in pairs(KINDS) do
    local m = math.max(me.mult[kind], 0.01)
    local base = nice(CATCH_TIME[1] * CATCH_REF / m * (kind == 'fire' and FIRE_SCALE or 1))
    me.catch[kind] = nice(base * wf)
    me.slow[kind] = kind == 'gas' and (1 / m) * wf or nil
  end
end
-- the statuses the mod works on (the rest are skipped unless a tester build logs them)
local HANDLED = {}
for id in pairs(KIND_OF) do HANDLED[id] = true end
for id in pairs(ARC_STUN_IDS) do HANDLED[id] = true end
local entries_out, entry_pool = {}, {}   -- (reused every frame: no new tables)
local function status_entries(owner)
  local m = rptr(L.status)
  if not m then return nil end
  local idx = map_lookup(m + L.smap, owner)
  if not idx then return nil end
  local b1 = rptr(m + L.blocks)
  if not b1 then return nil end
  local block = b1 + idx * L.bstride
  local h = peek(block + L.bcount, 4)
  local n = h and pu32(h, 0)
  if not n or n > math.floor((L.bstride - L.entries) / 48) then return nil end
  local count = 0
  if n > 0 then
    local e = peek(block + L.entries, 48 * n)   -- (all entries in one read)
    if not e then return nil end
    for i = 0, n - 1 do
      -- entry: +0 status id, +8 build-up (before it takes hold) / fire: time left, gas: concentration (after),
      -- +12 its clock, +16 ends at (in that clock), +20 taken hold
      local o = 48 * i
      local id = pu32(e, o)
      if TESTER or HANDLED[id] then
        count = count + 1
        local x = entry_pool[count]
        if not x then x = {}; entry_pool[count] = x end
        x.at, x.id, x.v, x.t, x.ends, x.on = block + L.entries + o, id, pf32(e, o + 8), pf32(e, o + 12), pf32(e, o + 16), pu32(e, o + 20) ~= 0
        entries_out[count] = x
      end
    end
  end
  for i = count + 1, #entries_out do entries_out[i] = nil end
  return entries_out
end

local function write_f32(at, x)
  local b = f32_bytes(x)
  if api.write(at, b) then S.stats.writes = S.stats.writes + 1; return true end   -- (the write reports every byte written)
  S.stats.write_failures = S.stats.write_failures + 1
  if S.stats.write_failures <= 5 then event(string.format('write failed at +%X', at % 4096)) end
  return false
end


-- one tracker per status id: follows its entry from build-up to the end. (Entries move in the list when another
-- one ends, so a tracker follows the status id, not the address; it is dropped when the status is gone.)
local track = {}
local shorten_stun
local function shape(kind, x, mult, now, dt, opt_catch, opt_tail, catch_time, slow)
  local st = S.stats[kind]
  local hold = HOLD[x.id]
  local k = track[x.id]
  if k and k.phase == 'blocked' then k = nil end   -- (a stumbling effect that was blocked: start a full tracker)
  if not k then
    -- (a new build-up counts from zero, so its first rise counts as contact)
    k = { last = x.on and x.v or 0, top = x.v, since = now, phase = nil, kept = false, rate = 1 }
    track[x.id] = k
  end
  k.at = x.at
  k.seen = now
  if not x.on then
    -- building up: takes hold after a flat time in it; the build-up fades once it stops rising
    k.phase = 'buildup'
    if opt_catch and mult < 1 then
      local rise, want = x.v - k.last, nil
      if rise > 0.0005 and k.counted and k.last <= 0.001 then k.counted, k.peak, k.kept = false, 0, false end   -- (a new build-up)
      if rise > 0.0005 then
        k.since = now
        k.rises = (k.rises or 0) + 1
        if slow and hold then
          -- gas: its own rise, slowed; kept just under the line until the slowed build-up gets there (the game adds
          -- one more rise before it checks)
          k.scaled = math.max(k.scaled or 0, k.last) + rise / math.max(slow, 1)
          if k.scaled < hold then want = math.max(0, math.min(x.v, k.scaled, hold - rise - 0.001)) end
        elseif hold then
          -- (the game adds about one more rise before it checks, so stay that much below the line)
          k.contact = (k.contact or 0) + dt
          if k.contact < catch_time then want = math.max(0, math.min(x.v, hold * k.contact / catch_time - rise)) end
        else want = k.last + rise * mult end      -- (take-hold value not known yet: keep the unresisted share)
      elseif now - k.since > 0.15 then
        want = math.max(0, x.v - DECAY * (hold or 1) * dt)
        if hold then k.contact = want / hold * catch_time end
        k.scaled = want
      end
      if want and math.abs(want - x.v) > 0.0005 and write_f32(x.at + 8, want) then x.v = want; k.kept = true end
      if x.v > (k.peak or 0) then k.peak = x.v end
      -- (counted once a real build-up has faded away without taking hold)
      if k.kept and rise <= 0.0005 and (k.peak or 0) > 0.2 * (hold or 1) and x.v <= 0.001 and not k.counted then
        k.counted = true
        st.kept = st.kept + 1
        if TESTER then event(kind .. ': kept from taking hold (' .. (STATUS_NAMES[x.id] or x.id) .. ')') end
      end
    end
    k.last = x.v
    return
  end
  if k.phase ~= 'on' then
    if k.phase == 'buildup' and not hold and k.last > 0.05 and k.last < 100 and (k.rises or 0) >= 3 then
      HOLD[x.id] = k.last   -- (learned only from a build-up seen rising over several frames)
      event(string.format('%s takes hold at a build-up of %.2f (learned)', STATUS_NAMES[x.id] or x.id, k.last))
    end
    k.phase, k.last, k.top, k.since, k.clock, k.full = 'on', x.v, x.v, now, x.t, 0
    st.caught = st.caught + 1
    if TESTER then event(string.format('%s took hold (%s)%s', kind, STATUS_NAMES[x.id] or x.id, k.kept and ' after the mod held it back' or ' (not held back)')) end
  end
  -- its clock: fire runs in real time, gas statuses can run faster (Gas ran ~10x in tests)
  if dt > 0 and x.t > k.clock then k.rate = k.rate * 0.7 + 0.3 * math.max(0.2, math.min(30, (x.t - k.clock) / dt)) end
  k.clock = x.t
  local left = (x.ends - x.t) / k.rate          -- seconds left, real time
  -- in it, the game keeps topping +8 up; out of it, +8 only falls (after a cut the effect is only cut again once
  -- you have been back in it: +8 jumped up)
  if k.cut and x.v > k.last + 0.05 then k.cut, k.top = false, x.v end
  if x.v > k.top then k.top = x.v end
  if x.v > k.last + 0.005 or x.v >= k.top - 0.08 then k.since = now; if left > k.full then k.full = left end end
  k.last = x.v
  if opt_tail and mult < 1 and not k.cut and now - k.since >= OUT_GRACE then
    local tail = math.max(MIN_TAIL, nice(math.floor(k.full * 2 + 0.5) / 2 * mult))   -- (full: 3 s fire, 5 s stumbling)
    if left > tail + 0.02 and write_f32(x.at + 16, x.t + tail * k.rate) then
      if kind == 'fire' then write_f32(x.at + 8, tail) end
      st.cut = st.cut + 1
      st.saved = st.saved + (left - tail)
      if TESTER then event(string.format('%s: out of it, %s cut from %.2f s to %.2f s left', kind, STATUS_NAMES[x.id] or x.id, left, tail)) end
      k.cut = true
      if kind == 'fire' then k.last, k.top = tail, tail end
    end
  end
end

--@tester-begin
-- tester research: every status entry as it changes, at most 10 lines a second
local research = { last = {}, next_t = 0 }
-- tester research: the whole 48-byte entry of every new status (and of a restarted one: its clock went back), read
-- every frame before the mod changes anything, to find what tells an arc stun from other stuns
local raw_last = {}
local function raw_log(list)
  local seen = {}
  for _, x in ipairs(list) do
    seen[x.id] = true
    local p = raw_last[x.id]
    if (x.id < 25 or x.id > 30) and (not p or x.t < p - 0.01) then
      local r = api.read(x.at, 48)
      if r then
        local w = {}
        for o = 0, 44, 4 do w[#w + 1] = string.format('%08X', u32(r, o)) end
        event(string.format('  raw new %s(%d): %s', STATUS_NAMES[x.id] or '?', x.id, table.concat(w, ' ')))
      end
    end
    raw_last[x.id] = x.t
  end
  for id in pairs(raw_last) do if not seen[id] then raw_last[id] = nil end end
end
-- tester research (Grounded): every arc in flight, each frame, as raw 32-bit words of its 0x118-byte record
-- (arc manager +0x130 + i * 0x118; active flags at +0x30, arc settings id at +0x15130 + i * 4), to find which
-- fields hold the entity it is at / jumping from and its jump count
local arc_lines, arc_seen = 0, {}
local ARC_MAX_LINES = 1500
local function arc_research()
  if arc_lines >= ARC_MAX_LINES then return end
  local m = rptr(L.arcmgr)
  if not m then return end
  local flags = api.read(m + 0x30, 256)
  if not flags then return end
  local now_seen = {}
  for i = 0, 255 do
    if flags:byte(i + 1) ~= 0 then
      local r = api.read(m + 0x130 + i * 0x118, 0x118)
      local sid = api.read(m + 0x15130 + i * 4, 4)
      if r and sid then
        local w = {}
        for o = 0, 0x114, 4 do w[#w + 1] = string.format('%X', u32(r, o)) end
        local line = table.concat(w, ' ')
        now_seen[i] = true
        if arc_seen[i] ~= line then
          arc_seen[i] = line
          arc_lines = arc_lines + 1
          event(string.format('  arc %d (settings %d, frame %d): %s', i, u32(sid, 0), S.frame, line))
        end
      end
    end
  end
  for i in pairs(arc_seen) do if not now_seen[i] then arc_seen[i] = nil; event(string.format('  arc %d gone (frame %d)', i, S.frame)) end end
end
--@tester-end

-- Grounded: with Electrical Conduit, an arc that reaches your helldiver goes no further. Each arc in flight is a record
-- in the arc manager (0x118 bytes at +0x130 + i * 0x118, active flags at +0x30). Its +0x40 is the entity it jumped
-- from, +0x44 / +0x48 the entity it hit, +0x2C its jump count, +0x31 set once it has hit and looks for the next
-- target, +0xF0 its scale. The game sizes both the search for the next target and a jump's reach by that scale
-- (arc settings range x share of jumps left x scale), and a jump with no reach ends without hitting anything. So:
-- an arc that hit you gets scale 0 before its search (the search comes a frame after the hit), and, as a backup, a
-- jump that has already left you gets scale 0 before its raycast. The game then ends the arc itself.
-- Only Electrical Conduit grounds you: it is found by what it is, the passive with its own arc modifier at
-- 95% or more (game value 0.05; Adreno-Defibrillator's is 0.5), not by its id.
local CONDUIT_MAX = 0.1
local GROUND = { from = 0x40, hit1 = 0x44, hit2 = 0x48, jumps = 0x2C, chaining = 0x31, scale = 0xF0 }
local grounded_done = {}   -- arc index -> the record's id (+0xEC) already stopped
local arc_flags = ffi.new('uint8_t[256]')
local function ground_arcs()
  local unit = me.unit
  if not unit or unit == 0 then return end
  local m = rptr(L.arcmgr)
  local fb = m and peek(m + 0x30, 256)
  if not fb then return end
  ffi.copy(arc_flags, fb, 256)   -- (the shared read buffer is reused for each arc below)
  local words = ffi.cast('uint64_t *', arc_flags)
  for w = 0, 31 do
    if words[w] ~= 0 then   -- (8 arcs at a time: most are not in flight)
      for i = w * 8, w * 8 + 7 do
        if arc_flags[i] ~= 0 then
          local at = m + 0x130 + i * 0x118
          local r = peek(at, 0xF4)   -- (one read: the arc's ends and jumps, its id +0xEC and scale +0xF0)
          if r then
            local id, hit1 = pu32(r, 0xEC), pu32(r, GROUND.hit1)
            local hit = hit1 == unit or pu32(r, GROUND.hit2) == unit
            local stop = (hit and r[GROUND.chaining] ~= 0)
              or (pu32(r, GROUND.from) == unit and pu32(r, GROUND.jumps) >= 1 and hit1 == 0)
            if stop and grounded_done[i] ~= id and pf32(r, GROUND.scale) ~= 0 then
              if write_f32(at + GROUND.scale, 0) then
                grounded_done[i] = id
                S.stats.arc.grounded = S.stats.arc.grounded + 1
                if TESTER then event(string.format('grounded: arc %d stopped at you (%s)', i, hit and 'hit you' or 'had jumped off you')) end
              end
            end
          end
        end
      end
    end
  end
end

--@tester-begin
-- tester research (catching other players' damage): the game's queue of damage events (a manager inside the game
-- world: [game+0x3326340] + 0x1024220 + 0x1266078; entries of 0x70 bytes at +0x1120, count at +0x201120; worked
-- through 16 a frame by 0x12A6EF0). Every entry seen is logged as words, to learn whether a hit is queued before or
-- after it comes off your health. Only on the known game build (the code bytes are checked first).
local DQ = { checked = false, lines = 0, seen = {} }
local function damage_queue_research()
  if DQ.lines >= 1500 then return end
  if not DQ.checked then
    DQ.checked = true
    local b = api.base()
    local c1, c2, c3, c4 = api.read(b + 0xAB5025, 10), api.read(b + 0xAB5FF7, 8), api.read(b + 0x13F7D4B, 8), api.read(b + 0x12A6F17, 6)
    if not (c1 and c2 and c3 and c4) or c1:sub(1, 3) ~= '\76\139\53' or c2:sub(1, 3) ~= '\73\141\142'
      or c3:sub(1, 3) ~= '\72\141\143' or c4:sub(1, 2) ~= '\139\129' then
      event('damage queue research: game code differs, skipped')
      return
    end
    DQ.world = b + 0xAB5025 + 7 + i32(c1, 3)
    DQ.off = u32(c2, 3) + u32(c3, 3)
    DQ.count = u32(c4, 2)
    DQ.entries = DQ.count - 0x200000
    event(string.format('damage queue research: world global game.dll+%X, queue at world+%X, count +%X, entries +%X',
      DQ.world - b, DQ.off, DQ.count, DQ.entries))
  end
  if not DQ.world then return end
  local w = rptr(DQ.world)
  if not w then return end
  local q = w + DQ.off
  local cr = api.read(q + DQ.count, 4)
  local n = cr and u32(cr, 0)
  if not n or n == 0 or n > 100000 then return end
  local now_seen = {}
  for i = 0, math.min(n, 16) - 1 do
    local r = api.read(q + DQ.entries + i * 0x70, 0x70)
    if r then
      local words, mine = {}, false
      for o = 0, 0x6C, 4 do
        local v = u32(r, o)
        if v ~= 0 and (v == me.unit or v == me.owner or v == me.avatar) then mine = true end
        words[#words + 1] = string.format('%X', v)
      end
      local line = table.concat(words, ' ')
      now_seen[line] = true
      if mine and not DQ.seen[line] then
        DQ.lines = DQ.lines + 1
        event(string.format('  dmgq %d/%d (frame %d): %s', i + 1, n, S.frame, line))
      end
    end
  end
  DQ.seen = now_seen
end

local function research_log(now, list)
  raw_log(list)
  if now < research.next_t then return end
  research.next_t = now + 0.1
  local seen = {}
  for _, x in ipairs(list) do
    if x.id < 25 or x.id > 30 then   -- (stims are known)
      local t = string.format('%s(%d) v %.3f t %.3f end %.3f on %d', STATUS_NAMES[x.id] or '?', x.id, x.v, x.t, x.ends, x.on and 1 or 0)
      seen[x.id] = true
      if research.last[x.id] ~= t then research.last[x.id] = t; event('  ' .. t) end
    end
  end
  for id in pairs(research.last) do if not seen[id] then research.last[id] = nil; event('  ' .. (STATUS_NAMES[id] or id) .. ' gone') end end
end
--@tester-end

-- an arc stun: cut once per stun (a new hit restarts its clock) to its length x the arc multiplier. Its +8 counts
-- down alongside the clock, so it is lowered by the same amount and ends where the game's own stun ends.
local stun_track = {}
shorten_stun = function(x, mult, now)
  if not mult or mult >= 1 then return end
  local k = stun_track[x.id]
  if not k or x.t < k.t - 0.01 then k = { t = x.t, full = x.ends, e = x.ends }; stun_track[x.id] = k end
  if x.ends > k.e + 0.05 then k.done, k.full = false, x.ends - x.t end     -- (another hit made it longer)
  k.t, k.e = x.t, x.ends
  if k.done or not x.on then return end
  local tail = math.max(0.02, k.full * mult)
  local cut = x.ends - (x.t + tail)
  if x.ends - x.t > tail + 0.02 and write_f32(x.at + 16, x.t + tail) then
    if x.v > cut then write_f32(x.at + 8, x.v - cut) end
    k.done = true
    local st = S.stats.arc
    st.stun, st.stun_saved = st.stun + 1, st.stun_saved + cut
    if TESTER then event(string.format('arc: %s cut from %.2f s to %.3f s', STATUS_NAMES[x.id] or x.id, x.ends - x.t, tail)) end
  end
end

local OPTS = { fire = { 'opt_ign', 'opt_ext' }, gas = { 'opt_gas', 'opt_gas' }, arc = { 'opt_arc', 'opt_arc' } }
local present = {}   -- (reused every frame)
local function handle(now, dt)
  local list = status_entries(me.owner)
  if not list then return end
  --@tester-begin
  if TESTER then research_log(now, list) end
  --@tester-end
  for id in pairs(present) do present[id] = nil end
  for _, x in ipairs(list) do
    present[x.id] = true
    local kind = KIND_OF[x.id]
    if ARC_STUN_IDS[x.id] then
      if S.opt_arc then shorten_stun(x, me.mult.arc, now) end
    elseif kind then
      local mult = me.mult[kind]
      if CONFUSION_IDS[x.id] and S.opt_slow and mult <= NO_CONFUSION + 0.001 then
        -- strong filtration: the gas's stumbling/slowing never takes hold
        local k = track[x.id]
        if not k then k = { phase = 'blocked' }; track[x.id] = k end
        k.at, k.seen = x.at, now
        local blocked = false
        if x.on then
          if x.ends > x.t + 0.001 then write_f32(x.at + 16, x.t); write_f32(x.at + 8, 0); blocked = true end
        elseif x.v > 0 then write_f32(x.at + 8, 0); blocked = true end
        if blocked and not k.counted then k.counted = true; S.stats.gas.stumble = S.stats.gas.stumble + 1 end
      else
        shape(kind, x, mult, now, dt, S[OPTS[kind][1]], S[OPTS[kind][2]], me.catch[kind], me.slow[kind])
      end
    end
  end
  for id in pairs(stun_track) do if not present[id] then stun_track[id] = nil end end
  for id, k in pairs(track) do
    if not present[id] then
      local kind = KIND_OF[id]
      if k.phase == 'buildup' and k.kept and not k.counted and (k.peak or 0) > 0.2 * (HOLD[id] or 1) then
        S.stats[kind].kept = S.stats[kind].kept + 1
        if TESTER then event(kind .. ': kept from taking hold (' .. (STATUS_NAMES[id] or id) .. ')') end
      end
      track[id] = nil
    end
  end
end

-- arc damage: the passives you wear let through 1/ARC_BOOST of the arc damage they did. The game reads the value
-- from the passive's own table, so anyone wearing the same passive gets it too; the game's value is put back when
-- you stop wearing it (or the option is off).
local function write_bytes(at, b)
  if api.write(at, b) then S.stats.writes = S.stats.writes + 1; return true end
  S.stats.write_failures = S.stats.write_failures + 1
  return false
end
local function u64_bytes(v) return u32_bytes(v % 4294967296) .. u32_bytes(math.floor(v / 4294967296)) end

-- What the mod changed is also kept in a process environment variable (with game.dll's address), so a mod that
-- is redeployed or reloaded with the game open puts the game's values back first instead of taking the boosted
-- value for the game's own and boosting it again. The game's values are also put back when the loader shuts down.
local KEEP_VAR = 'REALISTIC_RESISTANCES_KEEP'
local function save_kept()
  if not api.env_set then return end
  local out = {}
  for addr, b in pairs(BOOSTED) do out[#out + 1] = string.format('b %.0f %.17g %.17g', addr, b.orig, b.new) end
  for pp, g in pairs(GRAFTED) do out[#out + 1] = string.format('g %.0f %.0f %d %.0f %d', pp, g.orig_list, g.orig_n, g.list, g.n) end
  if #out == 0 then api.env_set(KEEP_VAR, nil) return end
  api.env_set(KEEP_VAR, string.format('%.0f;', api.base() or 0) .. table.concat(out, ';'))
end

local function restore_kept()
  local v = api.env_get and api.env_get(KEEP_VAR)
  if not v or v == '' then return end
  local base, rest = v:match('^(%d+);(.*)$')
  if base and tonumber(base) == api.base() then
    local n = 0
    for item in rest:gmatch('[^;]+') do
      local f = {}
      for w in item:gmatch('%S+') do f[#f + 1] = w end
      if f[1] == 'b' and #f == 4 then
        local addr, orig, new = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
        local r = api.read(addr, 4)
        if r and f32_at(r, 0) == new and write_f32(addr, orig) then n = n + 1 end
      elseif f[1] == 'g' and #f == 6 then
        local pp, orig_list, orig_n, list, gn = tonumber(f[2]), tonumber(f[3]), tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
        local c = api.read(pp + 24, 4)
        if rptr(pp + 16) == list and c and u32(c, 0) == gn
          and write_bytes(pp + 24, u32_bytes(orig_n)) and write_bytes(pp + 16, u64_bytes(orig_list)) then n = n + 1 end
      end
    end
    if n > 0 then event(string.format('arc damage boost from an earlier load put back (%d value(s))', n)) end
  end
  api.env_set(KEEP_VAR, nil)
end

-- all-elements passives (no arc modifier of their own): the game looks up the passive's arc modifier, then
-- multiplies by the all-elements one, taking the first modifier of each stat from the passive's list (+16, count
-- +24, read every time). So the list is pointed at the mod's own copy with an arc modifier of 1/ARC_BOOST added;
-- fire and gas still only see the all-elements value. Put back the same way when not worn / option off.
local POOL, pool_at = nil, 0
local SLOT = {}       -- passive table -> { at, size }: its copy (kept, so wearing it again reuses the same memory)
local GRAFT_VALUE = tonumber(ffi.new('float', 1 / ARC_BOOST))
local function graft_arc(ps)
  local want = {}
  if S.opt_arc then
    for _, x in ipairs(ps or {}) do
      local all = x.stats[ALL_STAT]
      if all and all > 0 and all < 1 and x.pp and x.ml and x.n and not GRAFTED[x.pp] and x.stats[ARC_STAT] == GRAFT_VALUE and x.n >= 2 then
        -- (a copy left by an earlier load that could not be put back: its last modifier is the added arc one, so
        -- the count is put back to the game's; the copy itself is never freed)
        local last = api.read(x.ml + 16 * (x.n - 1), 16)
        if last and u32(last, 0) == ARC_STAT and f32_at(last, 8) == GRAFT_VALUE and write_bytes(x.pp + 24, u32_bytes(x.n - 1)) then
          event('arc damage boost from an earlier load put back (all-elements passive)')
        end
      elseif not x.stats[ARC_STAT] and all and all > 0 and all < 1 and x.pp and x.ml and x.n and x.n < 8 then
        want[x.pp] = x
      end
    end
  end
  local changed = false
  for pp, g in pairs(GRAFTED) do
    local cur = rptr(pp + 16)
    if cur ~= g.list then
      -- (the game pointed the passive at a list of its own: nothing of the mod's is in use any more)
      GRAFTED[pp], changed = nil, true
    elseif not want[pp] then
      -- count first, then the pointer; forgotten only once both are back (else tried again next time)
      if write_bytes(pp + 24, u32_bytes(g.orig_n)) and write_bytes(pp + 16, u64_bytes(g.orig_list)) then
        GRAFTED[pp], changed = nil, true
        event('arc damage boost removed (all-elements passive back to the game\'s own modifiers)')
      end
    end
  end
  for pp, x in pairs(want) do
    if not GRAFTED[pp] then
      local size = 16 * (x.n + 1)
      local slot = SLOT[pp]
      if not slot or slot.size < size then
        if not POOL or pool_at + size > 4096 then POOL, pool_at = api.alloc and api.alloc(4096), 0 end
        slot = nil
        if POOL then slot = { at = POOL + pool_at, size = size }; pool_at = pool_at + size; SLOT[pp] = slot end
      end
      local at = slot and slot.at
      local mods = at and api.read(x.ml, 16 * x.n)
      local rest = api.read(pp + 24, 4)
      if mods and rest and u32(rest, 0) == x.n and rptr(pp + 16) == x.ml
        and write_bytes(at, mods .. u32_bytes(ARC_STAT) .. u32_bytes(2) .. f32_bytes(1 / ARC_BOOST) .. u32_bytes(0))
        and write_bytes(pp + 16, u64_bytes(at)) then
        -- (pointer first, then the count: the game never reads past the end of either list)
        if write_bytes(pp + 24, u32_bytes(x.n + 1)) then
          GRAFTED[pp], changed = { orig_list = x.ml, orig_n = x.n, list = at, n = x.n + 1 }, true
          local all = x.stats[ALL_STAT]
          event(string.format('arc damage boost: all-elements passive lets through %.1f%% of arc damage (was %.1f%%)',
            all / ARC_BOOST * 100, all * 100))
        else
          write_bytes(pp + 16, u64_bytes(x.ml))
        end
      end
    end
  end
  return changed
end

local function boost_arc(ps)
  local changed = graft_arc(ps)
  local want = {}
  if S.opt_arc then
    for _, x in ipairs(ps or {}) do
      local addr, v = x.at[ARC_STAT], x.stats[ARC_STAT]
      -- (not on all-elements passives: they have no arc modifier of their own)
      if addr and v and v > 0 and v < 1 and not x.stats[ALL_STAT] then want[addr] = v end
    end
  end
  for addr, b in pairs(BOOSTED) do
    if not want[addr] then
      local r = api.read(addr, 4)
      local cur = r and f32_at(r, 0)
      if cur ~= b.new then
        BOOSTED[addr], changed = nil, true   -- (the game put something else there: not the mod's any more)
      elseif write_f32(addr, b.orig) then
        BOOSTED[addr], changed = nil, true   -- (forgotten only once the game's value is really back)
        event(string.format('arc damage boost removed (game value %.3f put back)', b.orig))
      end
    end
  end
  for addr, orig in pairs(want) do
    local b = BOOSTED[addr]
    if not b then
      b = { orig = orig, new = tonumber(ffi.new('float', orig / ARC_BOOST)) }
      BOOSTED[addr], changed = b, true
      event(string.format('arc damage boost: passive lets through %.1f%% of arc damage (was %.1f%%)', b.new * 100, orig * 100))
    end
    local r = api.read(addr, 4)
    local cur = r and f32_at(r, 0)
    if cur ~= b.new then
      if cur == b.orig then write_f32(addr, b.new)
      else BOOSTED[addr], changed = nil, true end   -- (the game put something else there: leave it, look again next time)
    end
  end
  if changed then save_kept() end
end

-- ---------------------------------------------------------------- locate (4x a second)
local function resist(ps, kind)
  -- the passive's own multiplier for this kind of damage (several modifiers multiply)
  local m = 1
  for _, x in ipairs(ps) do
    for _, stat in ipairs(KINDS[kind].stats) do
      local v = x.stats[stat]
      if v and v >= 0 and v < 1 then m = m * v end
    end
  end
  return m
end

local function locate()
  local p, why = find_player()
  if not p then
    me.owner, me.unit, me.conduit, track, stun_track = nil, nil, false, {}, {}
    S.armor = why
    boost_arc(nil)
    return
  end
  if p.owner ~= me.owner then track, stun_track = {}, {} end
  me.owner, me.unit = p.owner, p.unit
  --@tester-begin
  me.avatar = p.avatar
  --@tester-end
  -- (your owner id first; the link map's redirect only when that finds nothing)
  local via = 'owner'
  local ps, g, idx = passive_of(p.owner)
  if not ps or #ps == 0 then
    local lk = link_key(p.owner)
    if lk then via = 'link'; ps, g, idx = passive_of(lk) end
    if ps and #ps == 0 then ps = nil end
  end
  local weight, wdesc = nil, nil
  if ps then weight, wdesc = armor_weight(g, idx) end
  me.weight = weight or 1
  local text
  boost_arc(ps)
  me.conduit = false
  if ps then
    for kind in pairs(KINDS) do me.mult[kind] = resist(ps, kind) end
    set_timings()
    for _, x in ipairs(ps) do
      local a = x.stats[ARC_STAT]
      if a and a > 0 and a <= CONDUIT_MAX then me.conduit = true end
    end
    local ids = {}
    for _, x in ipairs(ps) do ids[#ids + 1] = tostring(x.id) end
    text = string.format('passive %s, %s armor: fire resistance %.0f%%, gas %.0f%%, arc %.0f%%', table.concat(ids, ','),
      weight and WEIGHT_NAMES[weight] or 'unknown weight (counted as medium)',
      (1 - me.mult.fire) * 100, (1 - me.mult.gas) * 100, (1 - me.mult.arc) * 100)
    if me.conduit then text = text .. '; grounded' end
    --@tester-begin
    if TESTER then text = text .. string.format(' (via %s%s)', via, wdesc and ('; ' .. wdesc) or '') end
    --@tester-end
  else
    for kind in pairs(KINDS) do me.mult[kind] = 1 end
    set_timings()
    text = 'passive not found (nothing changed)'
  end
  if text ~= S.armor then
    S.armor = text
    event('helldiver: ' .. text)
    --@tester-begin
    if TESTER then
      event(string.format('  avatar %d owner %d unit %d; passive map: %s', p.avatar, p.owner, p.unit or -1, passive_map_dump()))
      pcall(passive_layout_dump)
    end
    --@tester-end
  end
end

-- ---------------------------------------------------------------- main
local ok, err = pcall(function()
  api = rawget(_G, 'RealisticResistancesTestApi') or build_api()
  S.t0, S.started = api.now(), os.date('%Y-%m-%d %H:%M:%S')
end)
if not ok then print('[Realistic Resistances] ' .. tostring(err)) return end

-- ---------------------------------------------------------------- Mod Options Menu
-- With CowboyBingus's Mod Options Menu installed, the mod manager's three options show in the game's MODS tab under
-- REALISTIC RESISTANCES as choices (Off + the same sub-options, in the same order) and the menu keeps their
-- values; without it nothing changes. All the code is in this core (the option addons only set flags), so every
-- row is there even for an option not picked in the mod manager (it starts at Off). Each row starts at the mod
-- manager's pick and its id carries that pick, so another pick there starts fresh instead of from an old value.
-- A value sets the same flags the option addons set (read every frame), so a change applies at once.
-- (Its API, from the menu's own source: register_option(id, spec), get(id), on_change(id, fn), api = 1.)
local MENU = {
  { key = 'fire', label = 'Fire Resistance', flags = { 'RealisticResistancesIgnite', 'RealisticResistancesExtinguish' },
    choices = { 'Harder to Ignite and Self-Extinguish', 'Only Harder to Ignite', 'Only Self-Extinguish' },
    description = 'Fire-resistant armor takes a flat time to catch fire (Inflammable: 2 s in medium armor, 1.5 s light, 2.5 s heavy; other armors by their fire resistance) and the burn runs out sooner once you leave the flames.' },
  { key = 'gas', label = 'Gas Resistance', flags = { 'RealisticResistancesGas', 'RealisticResistancesNoGasSlow' },
    choices = { 'Filtration Buffer and No Gas Slow', 'Only Filtration Buffer', 'Only No Gas Slow' },
    description = 'Filtration Buffer: gas-resistant armor holds out against gas longer, by the passive gas resistance (50%: twice as long in medium armor) and the gas wears off sooner. No Gas Slow: with 80% gas resistance or more (Advanced Filtration) the gas stumbling and slowing never takes hold.' },
  { key = 'arc', label = 'Arc Resistance', flags = { 'RealisticResistancesArc', 'RealisticResistancesGrounded' },
    choices = { 'Resistance and Grounded', 'Only Resistance', 'Only Grounded' },
    description = 'Resistance: arc-resistant armor holds out against the electric effect, it wears off sooner, and arc-resistant passives take a quarter of the arc damage they did. Grounded (Electrical Conduit only): arcs end at you instead of chaining on to others.' },
}
-- pick: 0 = Off, 1 = both, 2 = only the first part, 3 = only the second
local PICK_FLAGS = { [0] = { false, false }, [1] = { true, true }, [2] = { true, false }, [3] = { false, true } }
local function installed_pick(m)
  local a, b = rawget(_G, m.flags[1]) == true, rawget(_G, m.flags[2]) == true
  return (a and b) and 1 or a and 2 or b and 3 or 0
end
local function menu_apply(m, value)
  local f = PICK_FLAGS[(tonumber(value) or 1) - 1]
  if not f then return end
  rawset(_G, m.flags[1], f[1]); rawset(_G, m.flags[2], f[2])
end
local menu_at, menu_done = 0, false
local function menu_step(frame)
  if menu_done or frame < menu_at then return end
  menu_at = frame + 60
  local M = rawget(_G, 'ModOptionsMenu')
  if type(M) ~= 'table' or M.api ~= 1 or type(M.register_option) ~= 'function' then return end
  menu_done = true
  local added, failed_id = 0, nil
  for _, m in ipairs(MENU) do
    local pick = installed_pick(m)
    local id = 'realistic_resistances.' .. m.key .. '.' .. pick
    local choices = { 'Off' }
    for _, c in ipairs(m.choices) do choices[#choices + 1] = c end
    local spec = { type = 'choice', label = m.label, mod = 'REALISTIC RESISTANCES', choices = choices,
      default = pick + 1, description = m.description:sub(1, 400) }
    local ok, done, why = pcall(M.register_option, id, spec)
    if ok and done then
      added = added + 1
      local okg, v = pcall(M.get, id)
      if okg and v ~= nil then menu_apply(m, v) end
      pcall(M.on_change, id, function(value) pcall(menu_apply, m, value) end)
    else
      failed_id = id .. ': ' .. tostring(ok and why or done)
    end
  end
  S.options_menu = added .. ' setting(s) in the MODS tab' .. (failed_id and ('; not added: ' .. failed_id) or '')
  event('options menu: ' .. S.options_menu)
end

local grounded_noted = false
local next_locate, next_flush, ready, failed, last_t = 0, 0, false, false, nil
local function tick()
  S.frame = S.frame + 1
  if S.frame < 60 then return end
  menu_step(S.frame)
  if failed then return end
  local now = api.now()
  local dt = last_t and math.min(now - last_t, 0.1) or 0
  last_t = now
  S.opt_ext = rawget(_G, 'RealisticResistancesExtinguish') == true
  S.opt_ign = rawget(_G, 'RealisticResistancesIgnite') == true
  S.opt_gas = rawget(_G, 'RealisticResistancesGas') == true
  S.opt_arc = rawget(_G, 'RealisticResistancesArc') == true
  S.opt_slow = rawget(_G, 'RealisticResistancesNoGasSlow') == true
  S.opt_ground = rawget(_G, 'RealisticResistancesGrounded') == true
  local mask = (S.opt_ign and 1 or 0) + (S.opt_ext and 2 or 0) + (S.opt_gas and 4 or 0) + (S.opt_slow and 8 or 0)
    + (S.opt_arc and 16 or 0) + (S.opt_ground and 32 or 0)
  if mask ~= S.last_mask then   -- (the text only when an option changed)
    if S.last_mask then
      local function on(x) return x and 'on' or 'off' end
      event(string.format('options changed: harder to ignite %s, self-extinguish %s, gas resistance %s, no gas slow %s, arc resistance %s, grounded %s',
        on(S.opt_ign), on(S.opt_ext), on(S.opt_gas), on(S.opt_slow), on(S.opt_arc), on(S.opt_ground)))
    end
    S.last_mask = mask
  end
  if not ready then
    local fine, okv, how = pcall(resolve_layout)
    if fine and okv then
      ready = true
      S.status = 'active'
      event('started; game layout: ' .. how)
      pcall(restore_kept)
      if TESTER then event(L.arcmgr and string.format('arc manager at game.dll+%X', L.arcmgr - api.base()) or 'arc manager not found') end
    else
      local why = fine and tostring(how) or tostring(okv)
      if why == 'game.dll not loaded' then S.frame = 0; return end   -- (try again a second later)
      failed = true
      S.status = 'off: ' .. why
      event(S.status)
      write_log()
      return
    end
  end
  if S.opt_ground and not grounded_noted then
    grounded_noted = true
    if not L.arcmgr then event('grounded: off (the game\'s arc code was not found)') end
  end
  if now >= next_locate then next_locate = now + LOCATE_EVERY; locate() end
  if me.owner then handle(now, dt) end
  if L.arcmgr and S.opt_ground and me.conduit then ground_arcs() end
  --@tester-begin
  if TESTER and L.arcmgr then arc_research() end
  if TESTER then pcall(damage_queue_research) end
  if TESTER and api.key_down then
    local down = api.key_down(0x77)   -- F8
    if down and not S.f8 then
      S.marks = (S.marks or 0) + 1
      event(string.format('==== F8 MARK %d ====', S.marks))
      write_log()
    end
    S.f8 = down
  end
  --@tester-end
  if S.dirty and now >= next_flush then next_flush = now + 1; write_log() end
  if now >= (S.next_status or 0) then   -- (the summary's counters: rewritten every 10 s, only when they changed)
    S.next_status = now + 10
    local st, sig = S.stats, nil
    sig = string.format('%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d', st.writes, st.write_failures, st.fire.caught, st.fire.kept,
      st.fire.cut, st.gas.caught, st.gas.kept, st.gas.cut, st.gas.stumble, st.arc.caught, st.arc.kept, st.arc.cut,
      st.arc.stun, st.arc.grounded, S.errors and #S.errors or 0)
    if sig ~= S.last_sig then S.last_sig = sig; S.dirty = true end
  end
end

local original = rawget(_G, 'update')
if type(original) == 'function' then
  rawset(_G, 'update', function(...)
    local fine, e = pcall(tick)
    if not fine then
      local first = not (S.errors and S.errors[tostring(e)])
      log_error(e)
      if first then write_log() end
    end
    return original(...)
  end)
  -- the loader shutting down (game closing, mods redeployed): the game's own arc values go back
  local previous = rawget(_G, 'shutdown')
  rawset(_G, 'shutdown', function(...)
    pcall(function()
      if ready then boost_arc(nil); event('shut down: the game\'s own values put back'); write_log() end
    end)
    if type(previous) == 'function' then return previous(...) end
  end)
else
  S.status = 'off: the game update hook is unavailable'
end
write_log()

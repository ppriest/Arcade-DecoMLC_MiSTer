-- Dump what the MLC sprite engine reads, every frame, for scripts/sprite_load.py.
--
--   CORE_CPU, CORE_SPACE  the CPU and address space (regions.json)
--   SD_OUT     output file: FRAMES records, each
--                0x1800 bytes  sprite list, 0xC00 16-bit words (the low half of each
--                              32-bit slot at 0x204000-0x206FFF), big-endian
--                0x0080 bytes  IRQ block 0x200000-0x20007F, big-endian longs
--                0x0080 bytes  clip RAM 0x200080-0x2000FF, big-endian longs
--                0x2400 bytes  VRAM 0x29DC00-0x29FFFF, the region the game's DMAC
--                              rewrites every frame, big-endian longs
--   SD_VRAM    file for the whole VRAM (0x280000-0x29FFFF) at the last frame
--   SD_SKIP    frames to run before dumping (boot)
--   SD_FRAMES  frames to dump
--   SD_COIN    frame to insert a coin and press Start (0 = attract only); from
--              Start, HOLD is held and PULSE pulsed, so play goes on
--   SD_IN_COIN/START/HOLD/PULSE  input field names (regions.json "inputs")
--
-- frame_done runs at vblank start, where deco_mlc_v.cpp's screen_vblank_mlc copies
-- the list (line 545); the game writes it in the visible lines before that and the
-- DMAC lands at lines 9-11 after (docs/write_timing_mame.txt), so what is read here
-- is what the next frame is drawn from.

local OUT    = os.getenv("SD_OUT")
local VRAM   = os.getenv("SD_VRAM")
local SKIP   = tonumber(os.getenv("SD_SKIP") or "600")
local FRAMES = tonumber(os.getenv("SD_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("SD_COIN") or "0")

local mach = manager.machine
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin, f_start = field(os.getenv("SD_IN_COIN") or "Coin 1"), field(os.getenv("SD_IN_START") or "1 Player Start")
local f_right, f_b1 = field(os.getenv("SD_IN_HOLD") or "P1 Right"), field(os.getenv("SD_IN_PULSE") or "P1 Button 1")

local function longs(lo, hi)
    local parts = {}
    for a = lo, hi, 4 do
        parts[#parts + 1] = string.pack(">I4", prog:read_u32(a))
    end
    return table.concat(parts)
end

local function words16(lo, hi)
    local parts = {}
    for a = lo, hi, 4 do
        parts[#parts + 1] = string.pack(">I2", prog:read_u32(a) & 0xffff)
    end
    return table.concat(parts)
end

local out = assert(io.open(OUT, "wb"))
local n = 0
emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 and f_coin and f_start then
        f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        if n >= COIN + 96 then
            if f_right then f_right:set_value(1) end
            if f_b1 then f_b1:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if n > SKIP and n <= SKIP + FRAMES then
        out:write(words16(0x204000, 0x206ffc))
        out:write(longs(0x200000, 0x20007c))
        out:write(longs(0x200080, 0x2000fc))
        out:write(longs(0x29dc00, 0x29fffc))
    end
    if n == SKIP + FRAMES then
        out:close()
        if VRAM then
            local v = assert(io.open(VRAM, "wb"))
            v:write(longs(0x280000, 0x29fffc))
            v:close()
        end
        mach.video:snapshot()
        mach:exit()
    end
end)

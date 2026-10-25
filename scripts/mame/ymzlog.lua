-- Every write to the YMZ280B (0x600000 address, 0x600004 data, byte lane 3) and to the volume
-- byte (0x500000, bits 7:0), with MAME's machine time in seconds, for sim/ymz_tb to replay; MAME
-- writes its audio with -wavwrite in the same run. The SH-2 reaches the chip through chip-select
-- area 1 (0x026xxxxx, docs/write_timing_mame.txt), so that alias is tapped as well.
--   CORE_OUT    output directory (writes.txt)
--   CORE_LAST   frame to stop at
--   CORE_COIN   frame to insert a coin and press Start (0 = attract only)
-- Through run.lua.
local OUT  = os.getenv("CORE_OUT") or "debug/ymz"
local LAST = tonumber(os.getenv("CORE_LAST") or "3600")
local COIN = tonumber(os.getenv("CORE_COIN") or "0")
local m    = manager.machine
local prog = m.devices[":maincpu"].spaces["program"]
local scr  = m.screens[":screen"]
local f    = assert(io.open(OUT .. "/writes.txt", "w"))
f:write("# seconds address data mask\n")

local function tap(lo, hi, name)
    return prog:install_write_tap(lo, hi, name, function(offset, data, mask)
        f:write(string.format("%.12f %08x %08x %08x\n", m.time:as_double(), offset, data, mask))
        return data
    end)
end
_G.__ymz_taps = { tap(0x00600000, 0x00600007, "ymz0"), tap(0x02600000, 0x02600007, "ymz2"),
                  tap(0x00500000, 0x00500003, "vol0"), tap(0x02500000, 0x02500003, "vol2") }

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        if port.fields[name] then return port.fields[name] end
    end
end
local coin, start, b1 = field("Coin 1"), field("1 Player Start"), field("P1 Button 1")

core_subs = core_subs or {}
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    local n = scr:frame_number()
    if COIN > 0 then
        coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        -- confirm the mode and the character selects, then let the fight run
        local k = n - (COIN + 300)
        b1:set_value((k >= 0 and k < 1200 and k % 200 < 6) and 1 or 0)
    end
    if n >= LAST then
        f:close()
        print("YMZLOG_DONE " .. tostring(m.time:as_double()))
        m:exit()
    end
end)

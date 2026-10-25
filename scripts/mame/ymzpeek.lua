-- The bytes the YMZ280B reads at a few chip addresses, from its own region after the driver's
-- descramble, written to CORE_OUT/ymzpeek.txt. Through run.lua.
local OUT = os.getenv("CORE_OUT") or "debug/ymz"
local r = manager.machine.memory.regions[":ymz"]
local f = assert(io.open(OUT .. "/ymzpeek.txt", "w"))
for _, a in ipairs({0x31e579, 0x31e57a, 0x31e57b, 0x000000, 0x000001, 0x100000, 0x123456, 0x2abcde}) do
    local s = {}
    for k = 0, 7 do s[#s + 1] = string.format("%02x", r:read_u8(a + k)) end
    f:write(string.format("%06x %s\n", a, table.concat(s, " ")))
end
f:close()
manager.machine:exit()

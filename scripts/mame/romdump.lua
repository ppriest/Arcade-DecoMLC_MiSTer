-- Write a ROM region as MAME holds it after the driver's init (for the DE156 sets: the program
-- after deco156_decrypt), then exit.
--   mame <set> -video none -sound none -nodebug -autoboot_script scripts/mame/romdump.lua
-- Environment: ROMDUMP_REGION (default ":maincpu"), ROMDUMP_OUT (default debug/<set>_<region>_dec.bin)
local region_tag = os.getenv("ROMDUMP_REGION") or ":maincpu"
local set = emu.romname()
local out = os.getenv("ROMDUMP_OUT") or ("debug/" .. set .. "_" .. region_tag:gsub(":", "") .. "_dec.bin")
local done = false
emu.register_frame_done(function()
	if done then return end
	done = true
	local r = manager.machine.memory.regions[region_tag]
	if r == nil then
		print("romdump: no region " .. region_tag)
	else
		local f = assert(io.open(out, "wb"))
		-- read_u8 indexes the region in its own byte order, as MAME's memregion()->base() does
		local chunk = {}
		for a = 0, r.size - 1 do
			chunk[#chunk + 1] = string.char(r:read_u8(a))
			if #chunk == 65536 then f:write(table.concat(chunk)); chunk = {} end
		end
		f:write(table.concat(chunk))
		f:close()
		print(string.format("romdump: %s %s, %d bytes -> %s", set, region_tag, r.size, out))
	end
	manager.machine:exit()
end)

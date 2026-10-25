-- Snapshot every STEP-th frame from FIRST to LAST into CORE_OUT/fNNNNN.png, then exit: the
-- reference set scripts/match_frame.py searches for a board screenshot. Through run.lua.
local OUT   = os.getenv("CORE_OUT") or "debug/mame_frames"
local FIRST = tonumber(os.getenv("CORE_FIRST") or "0")
local LAST  = tonumber(os.getenv("CORE_LAST") or "3600")
local STEP  = tonumber(os.getenv("CORE_STEP") or "1")
local scr = manager.machine.screens[":screen"]
core_subs = core_subs or {}
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    local n = scr:frame_number()
    if n >= FIRST and n <= LAST and (n - FIRST) % STEP == 0 then
        scr:snapshot(string.format("%s/f%05d.png", OUT, n))
    end
    if n > LAST then print("SNAP_RANGE_DONE"); manager.machine:exit() end
end)

-- What each button does, for naming them in the .mra: coin up, start, pick a character, then
-- press each P1 button alone in play and take snapshots a few frames later. Driven through
-- run.lua (CORE_SCRIPT) with CORE_OUT the snapshot directory.
local OUT = os.getenv("CORE_OUT") or "debug/buttons"
local m = manager.machine
local function field(name)
    for _, port in pairs(m.ioport.ports) do
        if port.fields[name] then return port.fields[name] end
    end
    error("no input field " .. name)
end
local coin, start = field("Coin 1"), field("1 Player Start")
local btn = { field("P1 Button 1"), field("P1 Button 2"), field("P1 Button 3"), field("P1 Button 4") }
local right = field("P1 Right")
local scr = m.screens[":screen"]
-- frame -> {field, value}; the snapshot frames
local plan, snaps = {}, {}
local function press(f, at, len) plan[at] = plan[at] or {}; plan[at][#plan[at] + 1] = {f, 1}
    plan[at + len] = plan[at + len] or {}; plan[at + len][#plan[at + len] + 1] = {f, 0} end
press(coin, 600, 6)
press(start, 700, 6)
-- the character select and its partner select each run a timer; confirm both, then wait
press(btn[1], 900, 6)
press(btn[1], 1100, 6)
press(btn[1], 1300, 6)
press(btn[1], 1500, 6)
for b = 1, 4 do
    local at = 3200 + (b - 1) * 240
    press(btn[b], at, 10)
    snaps[at + 6]  = string.format("%s/b%d_a.png", OUT, b)
    snaps[at + 14] = string.format("%s/b%d_b.png", OUT, b)
    snaps[at + 30] = string.format("%s/b%d_c.png", OUT, b)
end
snaps[2000] = OUT .. "/at2000.png"
snaps[2600] = OUT .. "/at2600.png"
snaps[3150] = OUT .. "/before.png"
local last = 3200 + 3 * 240 + 40
core_subs = core_subs or {}
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    local n = scr:frame_number()
    if plan[n] then for _, p in ipairs(plan[n]) do p[1]:set_value(p[2]) end end
    if snaps[n] then scr:snapshot(snaps[n]) end
    if n >= last then print("BUTTONS_DONE"); m:exit() end
end)

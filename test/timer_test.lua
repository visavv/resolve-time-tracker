-- Verifies the exact UITimer event-binding pattern used by Time Tracker.lua:
--   local t = ui:Timer{ID=..., Interval=...}  +  disp.On.<ID>.Timeout
-- Run: fuscript -l lua "test\timer_test.lua"
local resolve = resolve or (bmd and bmd.scriptapp and bmd.scriptapp("Resolve"))
if not resolve then print("TIMER TEST: no Resolve") return end
local fusion = fu or fusion or resolve:Fusion()
local ui = fusion.UIManager
local disp = bmd.UIDispatcher(ui)

local ticks = 0
local ticker = ui:Timer({ ID = "TestTicker", Interval = 250, SingleShot = false })

function disp.On.Timeout(ev)
    ticks = ticks + 1
    print("tick " .. ticks .. " who=" .. tostring(ev and ev.who))
    io.stdout:flush()
    if ticks >= 3 then
        ticker:Stop()
        disp:ExitLoop()
    end
end

ticker:Start()
disp:RunLoop()
print(ticks >= 3 and "TIMER OK" or "TIMER FAILED")

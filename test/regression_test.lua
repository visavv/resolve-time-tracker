-- Runs the complete script with a fake Resolve UI, clock, idle API and disk.
-- No Resolve instance is needed; no real tracker data is read or written.
-- fuscript -l lua test/regression_test.lua
local sourcePath = debug.getinfo(1, "S").source:sub(2)
local testDir = sourcePath:match("^(.*)[/\\]") or "."
local f = assert(io.open(testDir .. "/../Time Tracker.lua", "rb"))
local source = f:read("*a"); f:close()
local compile = loadstring or load
local realTime, realDate = os.time, os.date
local sep = package.config:sub(1, 1)
local dir = "test-data"
local function path(name) return dir .. sep .. name end
local function check(value, message) assert(value, message or "check failed") end
local function eq(actual, expected, message)
    assert(actual == expected, (message or "mismatch") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function decode(text)
    if not text then return nil end
    local chunk = assert(compile(text)); setfenv(chunk, {}); return chunk()
end
local function saved(c, name) return decode(c.disk[path(name)]) end

local function boot(disk, scenario, options)
    options = options or {}
    local c = {disk=disk or {}, now=options.now or realTime({year=2026,month=9,day=28,hour=12}),
        project="A", page="edit", idle=0, faults=options.faults or {}, items={}, exits=0}
    local env = setmetatable({}, {__index=_G})
    env.os = {
        getenv=function(key)
            if key == "TT_DATA_DIR" then return dir end
            if key == "USERPROFILE" or key == "HOME" then return "fake-home" end
        end,
        time=function(t) return t and realTime(t) or c.now end,
        date=function(format, ts) return realDate(format, ts or c.now) end,
        remove=function(p)
            if c.faults.remove == p then return nil, "injected remove failure" end
            c.disk[p]=nil; return true
        end,
        rename=function(a,b)
            if c.faults.rename == b then return nil, "injected rename failure" end
            if not c.disk[a] then return nil, "missing source" end
            if c.disk[b] then return nil, "destination exists (Windows semantics)" end
            c.disk[b]=c.disk[a]; c.disk[a]=nil; return true
        end,
    }
    env.io = {stdout={flush=function() end}, open=function(p,mode)
        if c.faults.open == p then return nil, "injected open failure" end
        if mode:sub(1,1) == "r" then
            if not c.disk[p] then return nil, "missing" end
            return {close=function() return true end}
        end
        c.disk[p]=""
        return {
            write=function(_,text)
                if c.faults.write == p then c.disk[p]=text:sub(1,5); return nil,"disk full" end
                c.disk[p]=c.disk[p]..text; return true
            end,
            close=function()
                if c.faults.close == p then return nil,"flush failed" end
                return true
            end,
        }
    end}
    env.loadfile=function(p)
        if not c.disk[p] then return nil,"missing" end
        return compile(c.disk[p], "@"..p)
    end
    env.require=function(name)
        assert(name == "ffi")
        if not options.idle then error("ffi unavailable for this test") end
        return {os="Windows", cdef=function() end, new=function() return {} end,
            sizeof=function() return 8 end, load=function(lib)
                if lib == "user32" then return {GetLastInputInfo=function(lii)
                    lii.dwTime=((c.now-c.idle)*1000)%4294967296; return 1
                end} end
                return {GetTickCount=function() return (c.now*1000)%4294967296 end}
            end}
    end
    c.styleWrites=0
    local ui = setmetatable({}, {__index=function(_,kind)
        return function(_,props)
            props=props or {}
            if kind == "LineEdit" then props.Text=props.Text or "" end
            if kind == "CheckBox" then props.Checked=props.Checked or false end
            if kind == "ComboBox" then
                props.CurrentIndex=0; props.AddItems=function() end
            elseif kind == "Tree" then
                props.rows={}; props.ColumnWidth={}
                props.NewItem=function() return {Text={}, data={},
                    SetData=function(self,_,role,v) self.data[role]=v end,
                    GetData=function(self,_,role) return self.data[role] end} end
                props.SetHeaderItem=function() end
                props.Clear=function(self) self.rows={}; self.selected=nil; c.treeClears=(c.treeClears or 0)+1 end
                props.AddTopLevelItem=function(self,row) self.rows[#self.rows+1]=row end
                props.CurrentItem=function(self) return self.selected end
            elseif kind == "Timer" then props.Start=function() end; props.Stop=function() end end
            -- Count stylesheet writes: Qt restyles a widget on every assignment.
            local widget=setmetatable({}, {__index=props, __newindex=function(_,k,v)
                if k == "StyleSheet" then c.styleWrites=c.styleWrites+1 end
                props[k]=v
            end})
            if props.ID then c.items[props.ID]=widget end
            return widget
        end
    end})
    local win={On=setmetatable({}, {__index=function(t,k) local v={}; rawset(t,k,v); return v end}),
        GetItems=function() return c.items end, Show=function() end,
        Hide=function() c.hides=(c.hides or 0)+1 end,
        Raise=function() c.raised=(c.raised or 0)+1 end, ActivateWindow=function() end}
    local disp={On={},AddWindow=function() return win end,ExitLoop=function() c.exits=c.exits+1 end}
    c.click=function(id) win.On[id].Clicked({}) end
    c.closeWindow=function() win.On.ttwin.Close({}) end
    c.tick=function() disp.On.Timeout({who="Ticker"}) end
    c.history=function() return c.items.HistTree.rows end
    disp.RunLoop=function() scenario(c) end
    env.bmd={UIDispatcher=function() return disp end,createdir=function() end,fileexists=function() return true end,
        openfileexternal=function(mode,p) c.opened={mode=mode,path=p} end}
    env.fu={UIManager=ui}
    env.resolve={GetProjectManager=function() return {GetCurrentProject=function()
        return {GetName=function() return c.project end}
    end} end,GetCurrentPage=function() return c.page end}
    local script = assert(compile(source, "@Time Tracker.lua"))
    setfenv(script,env)
    script()
    return c
end

local passed, failed = 0,0
local function test(name, fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1; print("PASS "..name)
    else failed=failed+1; print("FAIL "..name..": "..tostring(err)) end
end
local function runFor(c,seconds)
    c.click("StartBtn"); c.now=c.now+seconds; c.tick(); c.click("StartBtn")
end

test("delayed callbacks and stopping between ticks count elapsed time",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+60; c.tick()
        eq(c.items.TimeLbl.Text,"0:01:00")
        c.now=c.now+3; c.click("StartBtn")
        local s=saved(c,"sessions.lua")[1]
        eq(s.seconds,63); eq(s.pages.edit,63); eq(s.endTs-s.startTs,63)
    end)
end)
test("failed history writes preserve live data and freeze time until retry",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+60; c.tick()
        c.faults.write=path("sessions.lua.tmp"); c.click("StartBtn")
        check(c.disk[path("live.lua")]); eq(c.items.StartBtn.Text,"Retry save")
        c.click("CloseBtn"); eq(c.exits,0,"failed close must keep UI open")
        c.now=c.now+120; c.faults.write=nil; c.tick()
        eq(saved(c,"sessions.lua")[1].seconds,60)
        check(not c.disk[path("live.lua")]); check(not c.disk[path("live.lua.bak")])
        eq(#c.history(),1)
    end)
end)
test("write and close failures preserve the last committed history",function()
    for _,op in ipairs({"open","write","close"}) do
        boot(nil,function(c)
            runFor(c,10); local original=c.disk[path("sessions.lua")]
            c.click("StartBtn"); c.now=c.now+20
            c.faults[op]=path("sessions.lua.tmp"); c.click("StartBtn")
            eq(c.disk[path("sessions.lua")],original,op)
            check(c.disk[path("live.lua")])
        end)
    end
end)
test("restart recovers the backup during the Windows rename gap",function()
    local disk={}
    boot(disk,function(c)
        runFor(c,10); c.click("StartBtn"); c.now=c.now+20
        c.faults.rename=path("sessions.lua"); c.click("StartBtn")
        check(not c.disk[path("sessions.lua")]); check(c.disk[path("sessions.lua.bak")])
    end)
    boot(disk,function(c)
        local history=saved(c,"sessions.lua")
        eq(#history,2); eq(history[1].seconds,10); eq(history[2].seconds,20)
    end)
end)
test("recovery does not duplicate already committed sessions",function()
    local disk={}
    boot(disk,function(c)
        c.click("StartBtn"); c.now=c.now+10
        c.faults.remove=path("live.lua.bak"); c.click("StartBtn")
        check(c.disk[path("live.lua")]); eq(#saved(c,"sessions.lua"),1)
    end)
    boot(disk,function(c) eq(#c.history(),1); check(not c.disk[path("live.lua")]) end)
    boot(disk,function(c) eq(#c.history(),1) end)
end)
test("unreadable history is not silently overwritten",function()
    local disk={[path("sessions.lua")]="return { broken"}
    local ok=pcall(function() boot(disk,function() error("must not reach UI") end) end)
    check(not ok); eq(disk[path("sessions.lua")],"return { broken")
end)
test("corrupt primary loads backup and preserves it on a failed replacement",function()
    local disk={}
    boot(disk,function(c) runFor(c,10) end)
    local original=disk[path("sessions.lua")]
    disk[path("sessions.lua.bak")]=original; disk[path("sessions.lua")]="corrupt"
    boot(disk,function(c)
        eq(#c.history(),1)
        c.faults.rename=path("sessions.lua"); runFor(c,20)
        eq(c.disk[path("sessions.lua.bak")],original)
    end)
    boot(disk,function(c) eq(#c.history(),2) end)
end)
test("deleting a selected identical-looking row uses its unique ID",function()
    boot(nil,function(c)
        c.now=math.floor(c.now/60)*60
        runFor(c,5); runFor(c,5)
        local history=saved(c,"sessions.lua")
        local olderId,newerId=history[1].id,history[2].id
        check(olderId~=newerId)
        -- Match both visible timestamp and duration, then select the older row.
        eq(c.history()[1].Text[0],c.history()[2].Text[0])
        c.items.HistTree.selected=c.history()[2]; c.click("DeleteBtn"); c.click("DeleteBtn")
        eq(#saved(c,"sessions.lua"),1); eq(saved(c,"sessions.lua")[1].id,newerId)
    end)
end)
test("failed deletion rolls history back",function()
    boot(nil,function(c)
        runFor(c,5); c.items.HistTree.selected=c.history()[1]
        c.faults.write=path("sessions.lua.tmp"); c.click("DeleteBtn"); c.click("DeleteBtn")
        eq(#c.history(),1); eq(#saved(c,"sessions.lua"),1)
        c.faults.write=nil; c.click("DeleteBtn"); c.click("DeleteBtn")
        eq(#saved(c,"sessions.lua"),0)
    end)
end)
test("deleting needs a second click on the same row within 5 seconds",function()
    boot(nil,function(c)
        runFor(c,5); runFor(c,5)
        local rows=c.history()
        c.items.HistTree.selected=rows[1]; c.click("DeleteBtn")
        eq(#saved(c,"sessions.lua"),2,"one click must not delete")
        check(c.items.StatusLbl.Text:find("again",1,true))
        -- Changing the selection cancels the pending confirmation.
        c.items.HistTree.selected=rows[2]; c.click("DeleteBtn")
        eq(#saved(c,"sessions.lua"),2,"confirmation must match the same row")
        -- A late second click only re-arms.
        c.now=c.now+6; c.click("DeleteBtn"); eq(#saved(c,"sessions.lua"),2)
        c.click("DeleteBtn"); eq(#saved(c,"sessions.lua"),1)
    end)
end)
test("a second tracker window defers to the running one",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+30; c.tick()
        local live=c.disk[path("live.lua")]
        boot(c.disk,function() error("second instance must not open a tracker") end,{now=c.now+2})
        eq(c.disk[path("live.lua")],live,"live session must not be 'recovered'")
        check(not c.disk[path("sessions.lua")],"no history may be committed")
        check(c.disk[path("raise.request")],"running window must be asked to come forward")
        c.now=c.now+1; c.tick()
        eq(c.raised,1); check(not c.disk[path("raise.request")])
        eq(c.items.TimeLbl.Text,"0:00:31")
    end)
end)
test("a stale or future heartbeat does not block opening",function()
    local now=realTime({year=2026,month=9,day=28,hour=12})
    for _,beat in ipairs({now-60, now+3600}) do
        local ran=false
        boot({[path("instance.lock")]="return {beat="..beat.."}"},function(c)
            ran=true; c.click("StartBtn"); eq(c.items.StartBtn.Text,"Stop")
        end)
        check(ran,"tracker must open when the old heartbeat is stale")
    end
end)
test("closing releases the single-instance lock",function()
    local disk={}
    boot(disk,function(c) check(c.disk[path("instance.lock")]); c.click("CloseBtn") end)
    check(not disk[path("instance.lock")])
end)
test("invalid settings fields never trap the window",function()
    local disk={}
    boot(disk,function(c)
        c.items.IdleEdit.Text="5"; c.items.RateEdit.Text="abc"; c.click("CloseBtn")
        eq(c.exits,1)
    end)
    local s=decode(disk[path("settings.lua")])
    eq(s.rate,100,"invalid rate keeps the last valid value"); eq(s.idleMin,5)
end)
test("auto-start setting persists and starts tracking on open",function()
    local disk={}
    boot(disk,function(c)
        eq(c.items.StartBtn.Text,"Start")
        c.items.AutoStartChk.Checked=true; c.click("AutoStartChk")
    end)
    eq(decode(disk[path("settings.lua")]).autoStart,true)
    boot(disk,function(c)
        eq(c.items.StartBtn.Text,"Stop"); check(c.disk[path("live.lua")])
        c.now=c.now+10; c.tick(); eq(c.items.TimeLbl.Text,"0:00:10")
    end)
end)
test("CSV starts with a UTF-8 BOM so Excel shows currency symbols",function()
    boot(nil,function(c)
        runFor(c,60); c.click("ExportBtn")
        local csv=c.disk[c.items.StatusLbl.Text:sub(#"Exported: "+1)]
        eq(csv:sub(1,3),"\239\187\191"); check(csv:find("€",1,true))
        check(not csv:find("\226\128\148",1,true),"no em dashes in exported text")
    end)
end)
test("history rows keep session IDs out of the visible columns",function()
    boot(nil,function(c)
        runFor(c,5)
        eq(c.items.HistTree.ColumnCount,4)
        local row,id=c.history()[1],saved(c,"sessions.lua")[1].id
        eq(row:GetData(0,"UserRole"),id)
        for col=0,3 do check(row.Text[col]~=id,"ID shown in column "..col) end
        check(row.Text[4]==nil)
    end)
end)
test("closing the window (X or Resolve quitting) never touches it again",function()
    -- Hiding or redrawing a window Resolve is tearing down makes Resolve
    -- abandon its quit and linger without a window (verified live).
    local c=boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+30; c.tick()
        c.hides=0; local clears=c.treeClears
        c.closeWindow()
        eq(c.exits,1); eq(c.hides,0,"no Hide during close"); eq(c.treeClears,clears,"no redraw during close")
        eq(saved(c,"sessions.lua")[1].seconds,30,"session still saved")
    end)
    eq(c.hides,0,"no Hide after the loop ends either")
end)
test("the Close button hides the window and saves",function()
    boot(nil,function(c)
        runFor(c,10); c.hides=0; c.click("CloseBtn")
        eq(c.exits,1); eq(c.hides,1); eq(#saved(c,"sessions.lua"),1)
    end)
end)
test("Open Folder opens the data folder",function()
    boot(nil,function(c) c.click("FolderBtn"); eq(c.opened.path,dir) end)
end)
test("unchanged widgets are not restyled on every tick",function()
    boot(nil,function(c)
        runFor(c,30); c.tick(); c.styleWrites=0
        c.now=c.now+1; c.tick(); c.now=c.now+1; c.tick()
        eq(c.styleWrites,0)
    end)
end)
test("stopped project switches refresh history",function()
    boot(nil,function(c)
        runFor(c,5); eq(#c.history(),1)
        c.project="B"; c.tick(); eq(#c.history(),0); eq(c.items.ProjectLbl.Text,"B")
        c.project="A"; c.tick(); eq(#c.history(),1)
    end)
end)
test("running project switches split elapsed time without an extra second",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+10; c.project="B"; c.tick()
        eq(c.items.TimeLbl.Text,"0:00:00")
        c.now=c.now+20; c.click("StartBtn")
        local ss=saved(c,"sessions.lua")
        eq(ss[1].project,"A"); eq(ss[1].seconds,10)
        eq(ss[2].project,"B"); eq(ss[2].seconds,20)
    end)
end)
test("earnings and CSV totals separate currencies",function()
    boot(nil,function(c)
        runFor(c,3600); c.items.CurCombo.CurrentIndex=1; runFor(c,3600)
        check(c.items.EarnLbl.Text:find("€ 100.00",1,true))
        check(c.items.EarnLbl.Text:find("$ 100.00",1,true))
        check(not c.items.EarnLbl.Text:find("200.00",1,true))
        c.click("ExportBtn")
        local csv=c.disk[c.items.StatusLbl.Text:sub(#"Exported: "+1)]
        check(csv:find("TOTAL (all projects),,,,,,,$,100.00",1,true))
        check(csv:find("TOTAL (all projects),,,,,,,€,100.00",1,true))
    end)
end)
test("midnight and Monday boundaries allocate only overlapping time",function()
    local monday=realTime({year=2026,month=9,day=28,hour=0})
    boot(nil,function(c)
        c.click("StartBtn"); c.now=monday+1800; c.tick()
        eq(c.items.AllLbl.Text,"All projects · Today 0:30:00 · This week 0:30:00")
        c.click("StartBtn")
        eq(c.items.AllLbl.Text,"All projects · Today 0:30:00 · This week 0:30:00")
    end,{now=monday-1800})
end)
test("legacy sessions receive IDs and proportional calendar allocation",function()
    local monday=realTime({year=2026,month=9,day=28,hour=0})
    local disk={[path("sessions.lua")]=string.format(
        'return {{project="A",startTs=%d,endTs=%d,seconds=1800,rate=100,currency="EUR",pages={edit=1800}}}',monday-1800,monday+1800)}
    boot(disk,function(c)
        eq(c.items.AllLbl.Text,"All projects · Today 0:15:00 · This week 0:15:00")
        check(c.history()[1]:GetData(0,"UserRole"):find("legacy-",1,true))
    end,{now=monday+1800})
end)
test("idle rewind removes exact elapsed intervals from the correct pages",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+60; c.page="color"; c.tick()
        c.now=c.now+600; c.idle=600; c.tick()
        local s=saved(c,"sessions.lua")[1]
        eq(s.seconds,60); eq(s.pages.edit,60); eq(s.pages.color,0)
        eq(s.endTs-s.startTs,60)
        -- Return was 3 seconds ago: no need to hit the old <2-second window.
        c.now=c.now+100; c.idle=3; c.tick(); eq(c.items.StatusLbl.Text,"")
        c.now=c.now+10; c.idle=0; c.click("StartBtn")
        eq(#saved(c,"sessions.lua"),2)
    end,{idle=true})
end)
test("idle calculation handles the Windows tick-counter wrap",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+660; c.idle=600; c.tick()
        eq(saved(c,"sessions.lua")[1].seconds,60)
    end,{idle=true,now=math.floor(4294967296/1000)-650})
end)
test("clock rounding does not resume an idle session without new input",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+660; c.idle=600.9; c.tick()
        c.now=c.now+1; c.idle=601.1; c.tick()
        check(c.items.StatusLbl.Text:find("Auto-paused",1,true))
        check(not c.disk[path("live.lua")])
    end,{idle=true})
end)
test("notes survive crash recovery",function()
    local disk={}
    boot(disk,function(c)
        c.click("StartBtn"); c.items.NoteEdit.Text="Keep this note"
        c.now=c.now+20; c.tick()
    end)
    boot(disk,function(c)
        local session=saved(c,"sessions.lua")[1]
        eq(session.seconds,20); check(session.note:find("Keep this note",1,true))
        -- Quitting Resolve mid-session is normal with auto-launch: no "crash" claim.
        check(session.note:find("(recovered: Resolve closed while tracking)",1,true))
        check(not session.note:find("crash",1,true))
    end)
end)
test("export includes running session and does not overwrite same-second exports",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+10; c.click("ExportBtn")
        local first=c.items.StatusLbl.Text:sub(#"Exported: "+1)
        check(c.disk[first]:find("(in progress)",1,true)); check(c.disk[first]:find("0:00:10",1,true))
        c.click("ExportBtn"); local second=c.items.StatusLbl.Text:sub(#"Exported: "+1)
        check(first~=second); check(c.disk[first]); check(c.disk[second])
        eq(c.items.StartBtn.Text,"Stop")
    end)
end)
test("invalid numeric settings are rejected and comma decimals are accepted",function()
    boot(nil,function(c)
        c.items.RateEdit.Text="-1"; c.click("StartBtn"); check(not c.disk[path("live.lua")])
        c.items.RateEdit.Text="1e999"; c.click("StartBtn"); check(not c.disk[path("live.lua")])
        c.items.RateEdit.Text="100,5"; c.items.IdleEdit.Text="0"; runFor(c,10)
        eq(saved(c,"sessions.lua")[1].rate,100.5)
    end)
end)

test("settings save errors are visible before starting a session",function()
    boot(nil,function(c)
        c.faults.write=path("settings.lua.tmp"); c.click("StartBtn")
        check(c.items.StatusLbl.Text:find("Could not save",1,true))
        check(not c.disk[path("live.lua")])
        c.faults.write=nil; c.click("StartBtn"); eq(c.items.StartBtn.Text,"Stop")
    end)
end)
test("transient live-save errors clear after a successful retry",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.faults.close=path("live.lua.tmp")
        c.now=c.now+10; c.tick(); check(c.items.StatusLbl.Text:find("Could not save",1,true))
        c.faults.close=nil; c.now=c.now+10; c.tick()
        eq(c.items.StatusLbl.Text,""); eq(saved(c,"live.lua").seconds,20)
    end)
end)
test("failed startup recovery retains a frozen session for retry",function()
    local disk={}
    boot(disk,function(c) c.click("StartBtn"); c.now=c.now+10; c.tick() end)
    boot(disk,function(c)
        eq(c.items.StartBtn.Text,"Retry save"); check(c.disk[path("live.lua")])
        c.now=c.now+100; c.faults.write=nil; c.tick()
        eq(saved(c,"sessions.lua")[1].seconds,10); eq(#c.history(),1)
    end,{faults={write=path("sessions.lua.tmp")}})
end)
test("idle before the session starts cannot produce a negative duration",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+5; c.idle=1000; c.tick()
        check(not c.disk[path("sessions.lua")]); eq(c.items.TimeLbl.Text,"0:00:00")
        check(c.items.StatusLbl.Text:find("Auto-paused",1,true))
    end,{idle=true})
end)
test("failed CSV writes report failure",function()
    boot(nil,function(c)
        runFor(c,10)
        c.faults.write=path(realDate("Time_Tracker_%Y%m%d_%H%M%S",c.now)..".csv")
        c.click("ExportBtn"); eq(c.items.StatusLbl.Text,"Export failed.")
    end)
end)

print(string.format("Regression tests: %d passed, %d failed",passed,failed))
assert(failed==0,"Regression test failures")

-- Runs the complete script with a fake Resolve UI, clock, idle API and disk.
-- No Resolve instance is needed; no real tracker data is read or written.
-- fuscript -l lua test/regression_test.lua
local sourcePath = debug.getinfo(1, "S").source:sub(2)
local testDir = sourcePath:match("^(.*)[/\\]") or "."
local f = assert(io.open(testDir .. "/../Time Tracker.lua", "rb"))
local source = f:read("*a"); f:close()
local compile = loadstring or load
local realTime, realDate = os.time, os.date
-- The whole suite runs once per platform the script supports. The platform
-- decides the path separator, the home variable and which native idle /
-- focus APIs the fake ffi offers (see boot).
local platform = "Windows"
local function sepFor(p) return p == "Windows" and "\\" or "/" end
local dir = "test-data"
local function path(name) return dir .. sepFor(platform) .. name end
local function check(value, message) assert(value, message or "check failed") end
local function eq(actual, expected, message)
    assert(actual == expected, (message or "mismatch") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function decode(text)
    if not text then return nil end
    local chunk = assert(compile(text)); setfenv(chunk, {}); return chunk()
end
local function saved(c, name) return decode(c.disk[path(name)]) end
-- The status names the exported file; it lives in the data folder.
local function exported(c)
    local name = c.items.StatusLbl.Text:match("(Time_Tracker_[%w_]+%.csv)")
    return name and path(name)
end

local function boot(disk, scenario, options)
    options = options or {}
    local c = {disk=disk or {}, now=options.now or realTime({year=2026,month=9,day=28,hour=12}),
        project="A", page="edit", idle=0, faults=options.faults or {}, items={}, exits=0,
        fgPid=100, fgPath="C:\\Program Files\\Blackmagic Design\\DaVinci Resolve\\Resolve.exe"}
    local env = setmetatable({}, {__index=_G})
    env.package = setmetatable({config=sepFor(platform).."\n;\n?\n!\n-\n"}, {__index=package})
    env.os = {
        getenv=function(key)
            if key == "TT_DATA_DIR" then return dir end
            if (platform == "Windows" and key == "USERPROFILE")
                or (platform ~= "Windows" and key == "HOME") then return "fake-home" end
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
        local ffi = {os=platform, cdef=function() end, new=function() return {} end,
            sizeof=function() return 8 end, string=function(buf) return buf.path end}
        ffi.load=function(lib)
            if platform == "Windows" and lib == "user32" then return {
                GetLastInputInfo=function(lii) lii.dwTime=((c.now-c.idle)*1000)%4294967296; return 1 end,
                GetForegroundWindow=function() return c.fgPid and {} or nil end,
                GetWindowThreadProcessId=function(_, pid) pid[0]=c.fgPid; return 1 end,
            } end
            if platform == "Windows" and lib == "kernel32" then return {
                GetTickCount=function() return (c.now*1000)%4294967296 end,
                OpenProcess=function(_, _, id) return {id=id} end,
                QueryFullProcessImageNameA=function(_, _, name, size)
                    name.path=c.fgPath; size[0]=#c.fgPath; return 1
                end,
                CloseHandle=function() return 1 end,
            } end
            if platform == "OSX" and lib:find("CoreGraphics", 1, true) then return {
                CGEventSourceSecondsSinceLastEventType=function() return c.idle end,
            } end
            error("no such library on " .. platform .. ": " .. lib)
        end
        return ffi
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
    c.fire=function(id, event) win.On[id][event]({}) end
    c.closeWindow=function() win.On.ttwin.Close({}) end
    c.tick=function() disp.On.Timeout({who="Ticker"}) end
    c.history=function() return c.items.HistTree.rows end
    disp.RunLoop=function() scenario(c) end
    env.bmd={UIDispatcher=function() return disp end,createdir=function() end,fileexists=function() return true end,
        openfileexternal=function(mode,p) c.opened={mode=mode,path=p} end}
    env.fu={UIManager=ui}
    env.resolve={GetProjectManager=function() return {GetCurrentProject=function()
        return {GetName=function() return c.project end,
                IsRenderingInProgress=function() return c.rendering == true end}
    end} end,GetCurrentPage=function() return c.page end}
    local script = assert(compile(source, "@Time Tracker.lua"))
    setfenv(script,env)
    script()
    return c
end

local tests = {}
local function test(name, fn) tests[#tests+1] = {name=name, fn=fn} end
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
        local csv=c.disk[exported(c)]
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
test("a failed save while Resolve quits still closes untouched; next open recovers",function()
    local disk={}
    boot(disk,function(c)
        c.click("StartBtn"); c.now=c.now+30; c.tick()
        c.faults.write=path("sessions.lua.tmp")
        local status,btn=c.items.StatusLbl.Text,c.items.StartBtn.Text
        c.hides=0; c.closeWindow()
        eq(c.exits,1,"must not keep a window Resolve is closing")
        eq(c.hides,0); eq(c.items.StatusLbl.Text,status,"no redraw"); eq(c.items.StartBtn.Text,btn,"no redraw")
        check(c.disk[path("live.lua")],"session kept for recovery")
        c.faults.write=nil
    end)
    boot(disk,function(c)
        local s=saved(c,"sessions.lua")[1]
        eq(s.seconds,30); check(s.note:find("(recovered",1,true))
    end)
end)
test("a failed settings save while Resolve quits does not redraw",function()
    boot(nil,function(c)
        c.faults.write=path("settings.lua.tmp")
        local status=c.items.StatusLbl.Text
        c.closeWindow(); eq(c.exits,1); eq(c.items.StatusLbl.Text,status)
    end)
end)
test("recovered sessions do not claim a cause that did not happen",function()
    local disk={}
    boot(disk,function(c) c.click("StartBtn"); c.now=c.now+20; c.tick() end) -- process dies here
    boot(disk,function(c)
        local note=saved(c,"sessions.lua")[1].note
        eq(note,"(recovered after an unexpected stop)")
    end)
end)
test("export status names the file instead of a long clipped path",function()
    boot(nil,function(c)
        runFor(c,60); c.click("ExportBtn")
        local text=c.items.StatusLbl.Text
        check(text:find("^Exported Time_Tracker_[%w_]+%.csv"),text)
        check(not text:find(dir,1,true),"no folder path in the status")
        check(c.disk[exported(c)],"named file exists")
    end)
end)
test("the Close button hides the window and saves",function()
    boot(nil,function(c)
        runFor(c,10); c.hides=0; c.click("CloseBtn")
        eq(c.exits,1); eq(c.hides,1); eq(#saved(c,"sessions.lua"),1)
    end)
end)
test("CSV text cells cannot run as spreadsheet formulas",function()
    boot(nil,function(c)
        c.project='=HYPERLINK("http://x","click")'
        c.click("StartBtn"); c.items.NoteEdit.Text="+cmd|' /C calc'!A0"; c.now=c.now+60; c.click("StartBtn")
        c.project="@SUM(1)"; runFor(c,60)
        c.click("ExportBtn")
        local csv=c.disk[exported(c)]
        for line in csv:gmatch("[^\r\n]+") do
            for cell in (line..","):gmatch('("?[^,]*"?),') do
                check(not cell:find('^"?[=+@]'),"formula-like cell: "..cell)
            end
        end
        check(csv:find([["'=HYPERLINK(""http://x"",""click"")"]],1,true),"kept as text, readable")
        check(csv:find("'@SUM(1)",1,true))
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
test("running project switches split at the first sighting, confirmed a tick later",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+10; c.project="B"; c.tick()
        eq(c.items.TimeLbl.Text,"0:00:10","one sighting is not a switch yet")
        c.now=c.now+1; c.tick()
        eq(c.items.TimeLbl.Text,"0:00:01","B started when it was first seen")
        c.now=c.now+19; c.click("StartBtn")
        local ss=saved(c,"sessions.lua")
        eq(ss[1].project,"A"); eq(ss[1].seconds,10); eq(ss[1].pages.edit,10)
        check(ss[1].note:find("(project switched)",1,true))
        eq(ss[2].project,"B"); eq(ss[2].seconds,20); eq(ss[2].startTs,ss[1].endTs)
    end)
end)
test("Resolve unloading the project just before quitting is not a switch",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+30; c.tick()
        c.project="Untitled Project"; c.now=c.now+1; c.tick()
        c.closeWindow()
        local ss=saved(c,"sessions.lua")
        eq(#ss,1,"no stray Untitled Project row"); eq(ss[1].project,"A"); eq(ss[1].seconds,31)
        check(not ss[1].note:find("switched",1,true),"no misleading note")
    end)
end)
test("a one-tick project flicker does not split the session",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+10; c.tick()
        c.project="B"; c.now=c.now+1; c.tick()
        c.project="A"; c.now=c.now+1; c.tick()
        c.now=c.now+1; c.click("StartBtn")
        local ss=saved(c,"sessions.lua"); eq(#ss,1); eq(ss[1].seconds,13)
    end)
end)
test("each project remembers its own rate and currency",function()
    local disk={}
    boot(disk,function(c)
        c.items.RateEdit.Text="100"; runFor(c,60)                       -- A at € 100
        c.project="B"; c.tick()
        eq(c.items.RateEdit.Text,"100","unknown project keeps the field as typed")
        c.items.RateEdit.Text="70"; c.items.CurCombo.CurrentIndex=1; runFor(c,60) -- B at $ 70
        c.project="A"; c.tick(); eq(c.items.RateEdit.Text,"100.00"); eq(c.items.CurCombo.CurrentIndex,0)
        c.project="B"; c.tick(); eq(c.items.RateEdit.Text,"70.00"); eq(c.items.CurCombo.CurrentIndex,1)
    end)
    boot(disk,function(c) -- remembered across restarts (opens on project A)
        eq(c.items.RateEdit.Text,"100.00")
    end)
end)
test("a session split by a project switch bills at the new project's rate",function()
    boot(nil,function(c)
        c.project="B"; c.tick(); c.items.RateEdit.Text="70"; runFor(c,10)
        c.project="A"; c.tick(); c.items.RateEdit.Text="100"
        c.click("StartBtn"); c.now=c.now+10; c.project="B"; c.tick(); c.now=c.now+1; c.tick()
        eq(c.items.RateEdit.Text,"70.00","greyed field shows the rate being billed")
        c.now=c.now+9; c.click("StartBtn")
        local ss=saved(c,"sessions.lua")
        eq(ss[2].project,"A"); eq(ss[2].rate,100); eq(ss[3].project,"B"); eq(ss[3].rate,70)
    end)
end)
test("malformed remembered rates are ignored",function()
    local disk={[path("settings.lua")]='return {rate=50, currency="€", projectRates={A={rate=-5,currency="€"}, B="x", [1]={rate=9,currency="$"}}}'}
    boot(disk,function(c)
        eq(c.items.RateEdit.Text,"50.00"); runFor(c,10)
        eq(saved(c,"sessions.lua")[1].rate,50)
    end)
end)
test("rate and currency are locked while tracking",function()
    boot(nil,function(c)
        eq(c.items.RateEdit.Enabled,true); eq(c.items.CurCombo.Enabled,true)
        c.click("StartBtn"); eq(c.items.RateEdit.Enabled,false); eq(c.items.CurCombo.Enabled,false)
        c.now=c.now+5; c.click("StartBtn"); eq(c.items.RateEdit.Enabled,true)
    end)
end)
test("earnings and CSV totals separate currencies",function()
    boot(nil,function(c)
        runFor(c,3600); c.items.CurCombo.CurrentIndex=1; runFor(c,3600)
        check(c.items.EarnLbl.Text:find("€ 100.00",1,true))
        check(c.items.EarnLbl.Text:find("$ 100.00",1,true))
        check(not c.items.EarnLbl.Text:find("200.00",1,true))
        c.click("ExportBtn")
        local csv=c.disk[exported(c)]
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
        check(session.note:find("(recovered after an unexpected stop)",1,true))
    end)
end)
test("export includes running session and does not overwrite same-second exports",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+10; c.click("ExportBtn")
        local first=exported(c)
        check(c.disk[first]:find("(in progress)",1,true)); check(c.disk[first]:find("0:00:10",1,true))
        c.click("ExportBtn"); local second=exported(c)
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
        c.click("ExportBtn"); check(c.items.StatusLbl.Text:find("^Export failed%."),c.items.StatusLbl.Text)
    end)
end)

-- ---------------------------------------------------------------- v1.1 features
local function setFee(c, text) c.items.FeeEdit.Text=text; c.fire("FeeEdit","TextChanged"); c.tick() end

test("a flat fee turns earnings into a time budget and an effective rate",function()
    local disk={}
    boot(disk,function(c)
        eq(c.items.BudgetLbl.Text,"set a flat fee to get one","hourly project")
        c.items.RateEdit.Text="100"; setFee(c,"1500")
        eq(decode(disk[path("settings.lua")]).projects.A.fee,1500)
        eq(c.items.EarnLbl.Text,"€ 1500.00 flat fee")
        eq(c.items.BudgetLbl.Text,"15:00:00 left of 15:00:00")
        runFor(c,3600)
        eq(c.items.BudgetLbl.Text,"14:00:00 left of 15:00:00")
        eq(c.items.EarnLbl.Text,"€ 1500.00 flat fee · € 1500.00 / hr","effective rate")
        check(c.items.BudgetLbl.StyleSheet:find("63,185,80",1,true),"green under 80%")
        runFor(c,11*3600)                                 -- 12 h = 80%
        check(c.items.BudgetLbl.StyleSheet:find("230,170,40",1,true),"amber from 80%")
        runFor(c,4*3600)                                  -- 16 h
        eq(c.items.BudgetLbl.Text,"1:00:00 over the 15:00:00 budget")
        check(c.items.BudgetLbl.StyleSheet:find("230,82,82",1,true),"red when over")
        check(c.items.EarnLbl.Text:find("€ 93.75 / hr",1,true))
        eq(c.history()[1].Text[2],"","no per-session earnings on a flat fee")
        c.project="B"; c.tick()
        eq(c.items.FeeEdit.Text,""); eq(c.items.BudgetLbl.Text,"set a flat fee to get one","fee is per project")
        c.project="A"; c.tick(); eq(c.items.FeeEdit.Text,"1500.00")
        setFee(c,""); eq(c.items.BudgetLbl.Text,"set a flat fee to get one","clearing the fee goes back to hourly")
        eq(c.items.EarnLbl.Text,"€ 1600.00","hourly again: 16 h at € 100")
    end)
end)
test("setting or clearing a fee redraws the history earnings at once",function()
    boot(nil,function(c)
        runFor(c,3600); check(c.history()[1].Text[2]:find("100.00",1,true))
        setFee(c,"500"); eq(c.history()[1].Text[2],"","flat fee: no per-session earnings")
        setFee(c,""); check(c.history()[1].Text[2]:find("100.00",1,true),"hourly again")
    end)
end)
test("an invalid flat fee is rejected with a message",function()
    boot(nil,function(c)
        setFee(c,"lots"); check(c.items.StatusLbl.Text:find("flat fee",1,true))
        check(not (c.disk[path("settings.lua")] or ""):find("fee",1,true))
    end)
end)
test("CSV bills a flat-fee project at its fee next to hourly projects",function()
    boot(nil,function(c)
        c.items.RateEdit.Text="100"; setFee(c,"1000"); runFor(c,7200)          -- A: flat 1000, 2 h
        c.project="B"; c.tick(); setFee(c,""); c.items.RateEdit.Text="50"; runFor(c,3600) -- B: 1 h at 50
        c.click("ExportBtn")
        local csv=c.disk[exported(c)]
        check(csv:find("\nA,2026%-09%-28,[^\n]*,100%.00,€,,"),"flat session row has no earnings")
        check(csv:find("A (subtotal),,,,2:00:00,2.0000,,€,1000.00,Flat fee. Effective rate € 500.00 / hr",1,true))
        check(csv:find("B (subtotal),,,,1:00:00,1.0000,,€,50.00",1,true))
        check(csv:find("TOTAL (all projects),,,,3:00:00,3.0000,,€,1050.00",1,true))
    end)
end)
test("counting renders keeps the session through an idle stretch",function()
    boot(nil,function(c)
        c.items.RenderChk.Checked=true; c.click("RenderChk")
        eq(decode(c.disk[path("settings.lua")]).countRenders,true)
        c.click("StartBtn")
        c.rendering=true; c.now=c.now+1800; c.idle=1800; c.tick()       -- 30 min render, nobody there
        eq(c.items.StartBtn.Text,"Stop","render keeps it running")
        c.rendering=false; c.now=c.now+700; c.idle=2500; c.tick()       -- render ended 11 min ago
        local s=saved(c,"sessions.lua")[1]
        eq(s.seconds,1800,"stopped at the end of the render, not at the last input")
        check(c.items.StatusLbl.Text:find("Auto-paused",1,true))
    end,{idle=true})
end)
test("without the render option an unattended render is idle time",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.rendering=true; c.now=c.now+1800; c.idle=1800; c.tick()
        check(not c.disk[path("sessions.lua")],"rewound to the last input: nothing billed")
        check(c.items.StatusLbl.Text:find("Auto-paused",1,true))
    end,{idle=true})
end)
test("the background pause skips time while Resolve is not the active app",function()
    boot(nil,function(c)
        c.items.FocusChk.Checked=true; c.click("FocusChk")
        c.click("StartBtn"); c.now=c.now+10; c.tick()
        c.fgPid=200; c.fgPath="C:\\Program Files\\Browser\\browser.exe"
        c.now=c.now+20; c.tick(); c.now=c.now+20; c.tick()
        eq(c.items.TimeLbl.Text,"0:00:10","browser time not counted")
        eq(c.items.StatusLbl.Text,"Paused while Resolve is in the background.")
        c.fgPid=100; c.fgPath="C:\\Program Files\\Blackmagic Design\\DaVinci Resolve\\Resolve.exe"
        c.now=c.now+5; c.tick()
        eq(c.items.TimeLbl.Text,"0:00:15"); eq(c.items.StatusLbl.Text,"")
        c.click("StartBtn")
        local ss=saved(c,"sessions.lua"); eq(#ss,1,"one session, not split"); eq(ss[1].seconds,15)
    end,{idle=true})
end)
test("stopping while paused in the background adds no time",function()
    boot(nil,function(c)
        c.items.FocusChk.Checked=true; c.click("FocusChk")
        c.fgPid=200; c.fgPath="C:\\Apps\\browser.exe"
        c.click("StartBtn"); c.now=c.now+10; c.tick(); c.now=c.now+1; c.click("StartBtn")
        check(not c.disk[path("sessions.lua")],"a fully paused session saves no row")
    end,{idle=true})
end)
test("the background pause is offered only where it works",function()
    boot(nil,function(c)
        if platform == "Windows" then check(c.items.FocusChk.Enabled ~= false)
        else eq(c.items.FocusChk.Enabled,false); eq(c.items.FocusChk.Checked,false) end
    end,{idle=true})
end)
test("client timesheet: hours and notes only, printable, tags removed",function()
    boot(nil,function(c)
        c.project='Brand <Film> / "Q4"'; c.tick(); c.items.RateEdit.Text="120"
        c.click("StartBtn"); c.items.NoteEdit.Text="Rough cut & titles"; c.now=c.now+5400; c.tick(); c.click("StartBtn")
        c.click("StartBtn"); c.now=c.now+600; c.tick(); c.click("StartBtn")
        c.click("ClientBtn")
        local html=c.opened and c.opened.path
        check(html and html:find("Timesheet_Brand _Film_ _ _Q4_2026",1,true) and html:find("%.html$"),tostring(html))
        local page=c.disk[html]
        check(page:find("Timesheet: Brand &lt;Film&gt; / &quot;Q4&quot;",1,true),"escaped title")
        check(page:find("Rough cut &amp; titles",1,true))
        check(not page:find("€",1,true) and not page:find("120",1,true),"no rates or money")
        check(page:find("1:40:00",1,true) and page:find("1.67 hours",1,true),"total")
        local csv=c.disk[(html:gsub("%.html$",".csv"))]
        check(csv:find("Date,Start,End,Duration,Hours,Notes",1,true))
        check(c.items.StatusLbl.Text:find("Print the page",1,true))
    end)
end)
test("client timesheet strips the tracker's own tags from notes",function()
    local disk={[path("sessions.lua")]='return {{id="x",project="A",startTs=1790000000,endTs=1790000600,seconds=600,rate=1,currency="€",note="Grade (auto-stopped: idle) (recovered after an unexpected stop)",pages={color=600}}}'}
    boot(disk,function(c)
        c.click("ClientBtn")
        local page=c.disk[c.opened.path]
        check(page:find("<td>Grade</td>",1,true),"clean note"); check(not page:find("auto-stopped",1,true))
        check(page:find("Color",1,true),"time by stage")
    end)
end)
test("client timesheet with nothing tracked says so",function()
    boot(nil,function(c)
        c.click("ClientBtn"); eq(c.items.StatusLbl.Text,"No time tracked on this project yet.")
    end)
end)
test("adding time worked outside Resolve",function()
    boot(nil,function(c)
        c.click("AddBtn")
        eq(c.items.EdDur.Text,"1:00"); check(c.items.EdTitle.Text:find("Add time",1,true))
        c.items.EdDate.Text="2026-09-27"; c.items.EdStart.Text="09:30"
        c.items.EdDur.Text="1:30"; c.items.EdNote.Text="Client call"
        c.click("EdSave")
        local s=saved(c,"sessions.lua")[1]
        eq(s.seconds,5400); eq(s.pages.manual,5400); eq(s.manual,true); eq(s.note,"Client call")
        eq(realDate("%Y-%m-%d %H:%M",s.startTs),"2026-09-27 09:30"); eq(s.endTs-s.startTs,5400)
        eq(#c.history(),1)
        c.click("ExportBtn"); check(c.disk[exported(c)]:find("Client call (manual entry)",1,true))
    end)
end)
test("the entry editor rejects impossible input and saves nothing",function()
    boot(nil,function(c)
        c.click("AddBtn")
        for _, case in ipairs({ {"EdDate","2026-02-31","does not exist"}, {"EdDate","31.1.2026","YYYY-MM-DD"},
                                {"EdStart","25:00","HH:MM"}, {"EdDur","0","duration"}, {"EdDur","1:75","duration"},
                                {"EdDur","30","24 hours"}, {"EdRate","-5","rate"} }) do
            c.click("AddBtn"); c.items[case[1]].Text=case[2]; c.click("EdSave")
            check(c.items.EdStatus.Text:find(case[3],1,true),case[1].."="..case[2].." -> "..c.items.EdStatus.Text)
        end
        check(not c.disk[path("sessions.lua")],"nothing saved")
        c.click("AddBtn"); c.items.EdDur.Text="1,5"; c.click("EdSave")
        eq(saved(c,"sessions.lua")[1].seconds,5400,"decimal comma hours")
    end)
end)
test("editing a session rescales its pages and marks it edited",function()
    boot(nil,function(c)
        c.click("StartBtn"); c.now=c.now+3000; c.page="color"; c.tick(); c.now=c.now+600; c.click("StartBtn")
        c.items.HistTree.selected=c.history()[1]; c.click("EditBtn")
        eq(c.items.EdDur.Text,"1:00:00"); check(c.items.EdTitle.Text:find("Edit",1,true))
        c.items.EdDur.Text="0:30"; c.items.EdNote.Text="Trimmed: lunch"
        c.click("EdSave")
        local s=saved(c,"sessions.lua")[1]
        eq(s.seconds,1800); eq(s.pages.edit+s.pages.color,1800); eq(s.pages.edit,1500)
        eq(s.edited,true); eq(s.segments,nil); eq(s.endTs-s.startTs,1800); eq(s.note,"Trimmed: lunch")
        eq(c.items.StatusLbl.Text,"Session updated.")
        c.click("ExportBtn"); check(c.disk[exported(c)]:find("Trimmed: lunch (edited)",1,true))
    end)
end)
test("a failed save while editing leaves the session unchanged",function()
    boot(nil,function(c)
        runFor(c,600); c.items.HistTree.selected=c.history()[1]; c.click("EditBtn")
        c.items.EdDur.Text="2:00"; c.faults.write=path("sessions.lua.tmp"); c.click("EdSave")
        check(c.items.EdStatus.Text:find("Could not save",1,true))
        eq(saved(c,"sessions.lua")[1].seconds,600); c.faults.write=nil
        c.click("EdSave"); eq(saved(c,"sessions.lua")[1].seconds,7200)
    end)
end)
test("Edit without a selection explains what to do",function()
    boot(nil,function(c) c.click("EditBtn"); check(c.items.StatusLbl.Text:find("Select a session",1,true)) end)
end)
test("rates saved by development builds are migrated",function()
    local disk={[path("settings.lua")]='return {rate=50, currency="€", projectRates={A={rate=80,currency="$"}}}'}
    boot(disk,function(c)
        eq(c.items.RateEdit.Text,"80.00"); runFor(c,10)
        local s=decode(c.disk[path("settings.lua")])
        eq(s.projects.A.rate,80); eq(s.projectRates,nil)
    end)
end)

-- What a test needs from the platform. Linux has no idle detection (the
-- tracker runs without auto-stop there); the tick-counter wrap and the
-- active-app pause are Windows APIs.
local REQUIRES = {
    ["idle rewind removes exact elapsed intervals from the correct pages"] = "idle",
    ["clock rounding does not resume an idle session without new input"] = "idle",
    ["idle before the session starts cannot produce a negative duration"] = "idle",
    ["idle calculation handles the Windows tick-counter wrap"] = "Windows",
    ["the background pause skips time while Resolve is not the active app"] = "Windows",
    ["stopping while paused in the background adds no time"] = "Windows",
    ["counting renders keeps the session through an idle stretch"] = "idle",
    ["without the render option an unattended render is idle time"] = "idle",
}
local function supported(need, p)
    if not need then return true end
    if need == "idle" then return p ~= "Linux" end
    return need == p
end

local passed, failed, skipped = 0, 0, 0
for _, p in ipairs({ "Windows", "OSX", "Linux" }) do
    platform = p
    for _, t in ipairs(tests) do
        if not supported(REQUIRES[t.name], p) then
            skipped = skipped + 1
        else
            local ok, err = pcall(t.fn)
            if ok then passed = passed + 1; print("PASS [" .. p .. "] " .. t.name)
            else failed = failed + 1; print("FAIL [" .. p .. "] " .. t.name .. ": " .. tostring(err)) end
        end
    end
end
platform = "Windows"
print(string.format("Regression tests: %d passed, %d failed, %d skipped (%d tests x 3 platforms)",
    passed, failed, skipped, #tests))
assert(failed==0,"Regression test failures")

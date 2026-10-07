--[[----------------------------------------------------------------------------
Time Tracker for DaVinci Resolve, version 1.1.0
https://github.com/visavv/resolve-time-tracker (MIT licence)
--------------------------------------------------------------------------------
A single-file time tracker that lives in Workspace > Scripts.

Features:
  - Per-project session tracking with a 1-second tick
  - Per-page time breakdown (media / cut / edit / fusion / color / fairlight /
    deliver / photo)
  - System-wide idle detection (mouse + keyboard) via LuaJIT ffi:
      Windows: GetLastInputInfo (user32)
      macOS:   CGEventSourceSecondsSinceLastEventType (CoreGraphics)
    When idle passes the threshold the session is closed at the moment of the
    last real input ("rewind"), tagged "(auto-stopped: idle)", and tracking
    re-arms: it resumes automatically on the next input.
  - Crash recovery: live session state is written to disk every second
  - Hourly rate + currency remembered per project (rate changes are historical)
  - Flat-fee projects: time budget at your hourly rate and effective hourly rate
  - Optional: keep counting during renders; pause while Resolve is in the
    background (Windows)
  - Add time worked outside Resolve; edit or delete sessions
  - One-click CSV export of all projects (grouped, subtotalled, per-page columns)
    and a client timesheet (hours and notes only; printable page + CSV)
  - Single instance: opening the script again brings the running window forward

Install:
  Copy this file to:
    Windows: %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility
    macOS:   ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility
    Linux:   ~/.local/share/DaVinciResolve/Fusion/Scripts/Utility
  Restart Resolve, then: Workspace > Scripts > Time Tracker

Data is stored in <home>/.resolve_time_tracker/ (settings.lua, sessions.lua,
live.lua while a session runs, instance.lock while the window is open, and
exported CSVs).
------------------------------------------------------------------------------]]

-- ---------------------------------------------------------------------------
-- Host objects (works from the Workspace > Scripts menu and via fuscript)
-- ---------------------------------------------------------------------------
local resolve = resolve
if not resolve and bmd and bmd.scriptapp then
    resolve = bmd.scriptapp("Resolve")
end
if not resolve then
    print("Time Tracker: could not connect to DaVinci Resolve.")
    print("Run this script from Workspace > Scripts inside Resolve.")
    return
end

local fusion = fu or fusion or resolve:Fusion()
if not fusion then
    print("Time Tracker: could not get a Fusion object for the UI.")
    return
end

local ui   = fusion.UIManager
local disp = bmd.UIDispatcher(ui)

-- ---------------------------------------------------------------------------
-- Paths and storage
-- ---------------------------------------------------------------------------
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local SEP        = IS_WINDOWS and "\\" or "/"
local HOME       = os.getenv(IS_WINDOWS and "USERPROFILE" or "HOME") or "."
-- TT_DATA_DIR lets tests redirect storage away from the real data folder
local DATA_DIR   = os.getenv("TT_DATA_DIR") or (HOME .. SEP .. ".resolve_time_tracker")
if (os.getenv("TT_AUTOTEST") or os.getenv("TT_EXPORT_TEST")) and not os.getenv("TT_DATA_DIR") then
    error("Set TT_DATA_DIR to a disposable folder before running tracker self-tests.")
end

local SETTINGS_FILE = DATA_DIR .. SEP .. "settings.lua"
local SESSIONS_FILE = DATA_DIR .. SEP .. "sessions.lua"
local LIVE_FILE     = DATA_DIR .. SEP .. "live.lua"

local function ensureDataDir()
    if bmd.fileexists and bmd.fileexists(DATA_DIR) then return end
    if bmd.createdir then
        bmd.createdir(DATA_DIR)
    else
        os.execute((IS_WINDOWS and 'mkdir "' or 'mkdir -p "') .. DATA_DIR .. '"')
    end
end

-- Minimal Lua-table serializer (numbers, strings, booleans, nested tables)
local function serialize(v, ind)
    ind = ind or ""
    local t = type(v)
    if t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "table" then
        local parts = {}
        if #v > 0 then
            for _, x in ipairs(v) do
                parts[#parts + 1] = ind .. "  " .. serialize(x, ind .. "  ")
            end
        else
            for k, x in pairs(v) do
                parts[#parts + 1] = ind .. "  [" .. serialize(k) .. "] = "
                    .. serialize(x, ind .. "  ")
            end
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
    end
    return "nil"
end

-- Write and close a complete temporary file before replacing anything. On
-- Windows rename cannot overwrite: keep the previous complete file as .bak
-- across the rename gap, and recover from it on the next launch if necessary.
local storageErrors = {}
local function exists(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

local function readTable(path)
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    -- Our serializer writes data only; saved files do not need host APIs.
    if setfenv then setfenv(chunk, {}) end
    local ok, res = pcall(chunk)
    if ok and type(res) == "table" then return res end
    return nil, "Invalid data in " .. path
end

local function loadTable(path)
    local value = readTable(path)
    if value then return value end
    local backup = readTable(path .. ".bak")
    if backup then return backup end
    if exists(path) or exists(path .. ".bak") then
        error("Cannot read saved data: " .. path .. ". Files were left untouched.")
    end
    return nil
end

local function saveTable(path, tbl)
    local function failed(err)
        storageErrors[path] = "Could not save " .. path .. ": " .. tostring(err)
        return false
    end
    local tmp, bak = path .. ".tmp", path .. ".bak"
    local f, err = io.open(tmp, "wb")
    if not f then return failed(err) end
    local written, writeErr = f:write("return " .. serialize(tbl) .. "\n")
    local closed, closeErr = f:close()
    if not written or not closed then return failed(writeErr or closeErr) end
    if exists(path) then
        if readTable(path) then
            if exists(bak) then
                local ok, why = os.remove(bak)
                if not ok then return failed(why) end
            end
            local ok, why = os.rename(path, bak)
            if not ok then return failed(why) end
        else
            -- A valid backup may have been loaded after an interrupted write.
            -- Preserve that backup instead of replacing it with corrupt data.
            if not readTable(bak) then return failed("Existing data is unreadable") end
            local ok, why = os.remove(path)
            if not ok then return failed(why) end
        end
    end
    local ok, why = os.rename(tmp, path)
    if not ok then return failed(why) end
    storageErrors[path] = nil
    return true
end

local function writeFile(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    local written = f:write(text)
    local closed = f:close()
    return (written and closed) and true or false
end

ensureDataDir()

-- ---------------------------------------------------------------------------
-- Single instance. An open tracker refreshes instance.lock every tick. Running
-- the script again while that heartbeat is fresh asks the open window to come
-- forward instead of starting a second tracker, which would double-count time
-- and mistake the live session for a crash.
-- ---------------------------------------------------------------------------
local LOCK_FILE  = DATA_DIR .. SEP .. "instance.lock"
local RAISE_FILE = DATA_DIR .. SEP .. "raise.request"
local HEARTBEAT_STALE_S = 10 -- timer callbacks can lag while Resolve is busy

do
    local lock = readTable(LOCK_FILE)
    local age = lock and tonumber(lock.beat) and (os.time() - lock.beat)
    -- A heartbeat from the future means the clock moved back: treat as stale.
    if age and age >= 0 and age <= HEARTBEAT_STALE_S then
        writeFile(RAISE_FILE, "raise\n")
        print("Time Tracker is already open. Bringing its window to the front.")
        return
    end
end

local function heartbeat()
    writeFile(LOCK_FILE, "return {beat=" .. os.time() .. "}\n")
end

-- ---------------------------------------------------------------------------
-- Idle detection (system-wide, via LuaJIT ffi)
-- ---------------------------------------------------------------------------
local idle = { supported = false, why = "ffi unavailable" }
do
    local ok, ffi = pcall(require, "ffi")
    if ok and ffi then
        if ffi.os == "Windows" then
            local okDef = pcall(ffi.cdef, [[
                typedef struct { unsigned int cbSize; unsigned int dwTime; } TT_LASTINPUTINFO;
                int GetLastInputInfo(TT_LASTINPUTINFO *plii);
                unsigned int GetTickCount(void);
            ]])
            local okU, user32   = pcall(ffi.load, "user32")
            local okK, kernel32 = pcall(ffi.load, "kernel32")
            if okDef and okU and okK then
                idle.supported = true
                local lii = ffi.new("TT_LASTINPUTINFO") -- reused every tick
                lii.cbSize = ffi.sizeof("TT_LASTINPUTINFO")
                idle.seconds = function()
                    if user32.GetLastInputInfo(lii) ~= 0 then
                        local diff = (tonumber(kernel32.GetTickCount()) - tonumber(lii.dwTime)) % 4294967296
                        return diff / 1000
                    end
                    return 0
                end
            else
                idle.why = "ffi bindings failed"
            end
        elseif ffi.os == "OSX" then
            local okDef = pcall(ffi.cdef, [[
                double CGEventSourceSecondsSinceLastEventType(int stateID, unsigned int eventType);
            ]])
            local okL, cg = pcall(ffi.load,
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            if okDef and okL then
                idle.supported = true
                idle.seconds = function()
                    -- 1 = kCGEventSourceStateHIDSystemState, 0xFFFFFFFF = any event
                    return cg.CGEventSourceSecondsSinceLastEventType(1, 0xFFFFFFFF)
                end
            else
                idle.why = "CoreGraphics load failed"
            end
        else
            idle.why = "unsupported OS: " .. tostring(ffi.os)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Is Resolve the active app? (optional pause; Windows only for now)
-- The tracker window belongs to Resolve's process, so it counts as Resolve.
-- ---------------------------------------------------------------------------
local focus = { supported = false }
do
    local ok, ffi = pcall(require, "ffi")
    if ok and ffi and ffi.os == "Windows" then
        pcall(ffi.cdef, [[
            void* GetForegroundWindow(void);
            unsigned long GetWindowThreadProcessId(void* hWnd, unsigned long* pid);
            void* OpenProcess(unsigned long access, int inherit, unsigned long pid);
            int QueryFullProcessImageNameA(void* process, unsigned long flags, char* name, unsigned long* size);
            int CloseHandle(void* handle);
        ]])
        local okU, user32 = pcall(ffi.load, "user32")
        local okK, kernel32 = pcall(ffi.load, "kernel32")
        local okB, pid, name, size = pcall(function()
            return ffi.new("unsigned long[1]"), ffi.new("char[1024]"), ffi.new("unsigned long[1]")
        end)
        if okU and okK and okB then
            local isResolve, cached = {}, 0 -- process id -> bool
            local function lookup(id)
                local handle = kernel32.OpenProcess(0x1000, 0, id) -- QUERY_LIMITED_INFORMATION
                if handle == nil then return false end
                size[0] = 1024
                local found = kernel32.QueryFullProcessImageNameA(handle, 0, name, size) ~= 0
                    and ffi.string(name, size[0]):lower():find("[\\/]resolve%.exe$") ~= nil
                kernel32.CloseHandle(handle)
                return found
            end
            focus.supported = true
            focus.resolveActive = function()
                local hwnd = user32.GetForegroundWindow()
                if hwnd == nil then return true end -- no foreground window: don't guess
                user32.GetWindowThreadProcessId(hwnd, pid)
                local id = tonumber(pid[0])
                if isResolve[id] == nil then
                    if cached >= 64 then isResolve, cached = {}, 0 end -- ids get reused
                    isResolve[id] = lookup(id)
                    cached = cached + 1
                end
                return isResolve[id]
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- App state
-- ---------------------------------------------------------------------------
local PAGES = { "media", "cut", "edit", "fusion", "color", "fairlight", "deliver", "photo" }
local CURRENCIES = { "€", "$", "£", "¥", "kr", "CHF", "C$", "A$", "zł", "₹" }

local function nonnegative(value, fallback)
    local n = tonumber((tostring(value):gsub(",", ".")))
    if not n or n ~= n or n == math.huge or n < 0 then return fallback end
    return n
end

local settings = loadTable(SETTINGS_FILE) or {}
settings.rate     = nonnegative(settings.rate, 100.00)
settings.currency = settings.currency or "€"
settings.idleMin  = nonnegative(settings.idleMin, 10)
settings.autoStart = settings.autoStart == true
settings.countRenders = settings.countRenders == true
settings.pauseInBackground = settings.pauseInBackground == true
-- Per project: the rate and currency it was last tracked with (so switching
-- clients never bills one at another's rate) and an optional flat fee.
do
    local clean = {}
    local function take(source)
        if type(source) ~= "table" then return end
        for name, p in pairs(source) do
            if type(name) == "string" and type(p) == "table" then
                local entry = clean[name] or {}
                local rate = nonnegative(p.rate)
                if rate and type(p.currency) == "string" then
                    entry.rate, entry.currency = rate, p.currency
                end
                local fee = nonnegative(p.fee)
                if fee and fee > 0 then entry.fee = fee end
                if next(entry) then clean[name] = entry end
            end
        end
    end
    take(settings.projectRates) -- name used by pre-1.1 development builds
    take(settings.projects)
    settings.projects = clean
    settings.projectRates = nil
end

local function rateFor(projName)
    local p = settings.projects[projName]
    if p and p.rate then return p.rate, p.currency end
    return settings.rate, settings.currency
end

local function feeFor(projName)
    local p = settings.projects[projName]
    return p and p.fee
end

local sessions = loadTable(SESSIONS_FILE) or {}
-- Claim the instance only once saved data has loaded; a load error must not
-- leave a fresh heartbeat that blocks the next attempt to open the tracker.
heartbeat()
os.remove(RAISE_FILE) -- a request left over from before this window existed
-- Deterministic IDs for old history; persisted on the next successful save.
for i, session in ipairs(sessions) do
    session.id = session.id or ("legacy-" .. tostring(session.startTs) .. "-" .. i)
end
local idCounter = 0
local instanceId = tostring(os.time()) .. "-" .. tostring({}):gsub("[^%w]", "")
local function newId()
    idCounter = idCounter + 1
    return instanceId .. "-" .. idCounter
end

-- States: "idle", "running", "armed" (resumes on input), "saving" (retrying a failed close)
local state = "idle"
local sess  = nil        -- current session table while running
local recoveredNotice = nil

local pm = resolve:GetProjectManager()

local function currentProjectName()
    local ok, name = pcall(function()
        local proj = pm:GetCurrentProject()
        return proj and proj:GetName() or nil
    end)
    if ok and name and name ~= "" then return name end
    return "Untitled Project"
end

local function currentPage()
    local ok, page = pcall(function() return resolve:GetCurrentPage() end)
    if ok and page and page ~= "" then return page end
    return "unknown"
end

local function renderingNow()
    local ok, busy = pcall(function()
        local proj = pm:GetCurrentProject()
        return proj and proj:IsRenderingInProgress()
    end)
    return ok and busy == true
end

-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------
local function fmtHMS(s)
    s = math.max(0, math.floor(s or 0))
    return string.format("%d:%02d:%02d",
        math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

local function fmtMoney(n)
    return string.format("%.2f", n or 0)
end

local function sessionEarnings(s)
    return (s.seconds or 0) / 3600 * (s.rate or 0)
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------
local function saveSessions() return saveTable(SESSIONS_FILE, sessions) end
local function saveSettings() return saveTable(SETTINGS_FILE, settings) end

local function saveLive()
    if not sess then return true end
    sess.savedAt = sess.endTs or sess.lastTs or os.time()
    return saveTable(LIVE_FILE, sess)
end

local function removeLive()
    -- Delete both generations only after history has been committed. If cleanup
    -- fails, recovery deduplicates by ID before adding anything to history.
    for _, path in ipairs({LIVE_FILE .. ".bak", LIVE_FILE}) do
        if exists(path) then
            local ok, err = os.remove(path)
            if not ok then
                storageErrors[LIVE_FILE] = "Could not remove recovery file: " .. tostring(err)
                return false
            end
        end
    end
    storageErrors[LIVE_FILE] = nil
    return true
end

local pendingSwitch = nil -- {name=, at=}: project change seen once, not yet confirmed

-- startTs backdates the start (a confirmed project switch); default now.
local function startSession(projName, startTs)
    if sess then return false end
    local now = startTs or os.time()
    pendingSwitch = nil
    projName = projName or currentProjectName()
    local rate, currency = rateFor(projName)
    sess = {
        id = newId(), project = projName,
        startTs = now, lastTs = now, lastPage = currentPage(),
        seconds = 0, rate = rate, currency = currency,
        note = "", pages = {}, segments = {},
    }
    state = "running"
    saveLive()
    return true
end

-- Coalesce adjacent page intervals: elapsed time, page totals and calendar
-- reports all use the same timeline, even when a callback arrives late.
local function accountUntil(now)
    if not sess or sess.endTs then return end
    local from = sess.lastTs
    if now <= from then return end
    local page = sess.lastPage
    local segments = sess.segments
    local last = segments[#segments]
    if last and last.page == page and last.endTs == from then
        last.endTs = now
    else
        segments[#segments + 1] = {startTs = from, endTs = now, page = page}
    end
    local elapsed = now - from
    sess.seconds = sess.seconds + elapsed
    sess.pages[page] = (sess.pages[page] or 0) + elapsed
    sess.lastTs = now
end

local function trimAfter(cutoff)
    cutoff = math.max(sess.startTs, math.min(cutoff, sess.lastTs))
    for i = #sess.segments, 1, -1 do
        local seg = sess.segments[i]
        local removed = math.max(0, seg.endTs - math.max(seg.startTs, cutoff))
        sess.seconds = sess.seconds - removed
        sess.pages[seg.page] = sess.pages[seg.page] - removed
        if seg.startTs >= cutoff then table.remove(sess.segments, i)
        else seg.endTs = math.min(seg.endTs, cutoff); break end
    end
    sess.lastTs = cutoff
    return cutoff
end

local refreshHistory
local closingWindow = false -- set by shutdown(); see there

local function closeSession(extraNote, endTs)
    if not sess then return true end
    if not sess.endTs then
        local stopAt = endTs or os.time()
        if sess.paused then
            -- Paused in the background: the time since the last tick isn't work.
            sess.lastTs = math.max(sess.lastTs, stopAt)
        else
            accountUntil(stopAt)
        end
        sess.endTs = endTs or sess.lastTs
        if extraNote and extraNote ~= "" then
            sess.note = (sess.note ~= "" and (sess.note .. " ") or "") .. extraNote
        end
    end
    -- Freeze accounting while retrying. Never discard the only recoverable copy.
    state = "saving"
    saveLive()
    if sess.seconds > 0 then
        sessions[#sessions + 1] = sess
        if not saveSessions() then
            table.remove(sessions)
            return false
        end
    end
    sess = nil
    state = "idle"
    removeLive()
    if refreshHistory and not closingWindow then refreshHistory() end
    return true
end

-- A crash may happen after committing history but before deleting live.lua.
-- IDs make recovery idempotent; old-format live files use a legacy fingerprint.
do
    local live = loadTable(LIVE_FILE)
    local duplicate = false
    if live then
        for _, old in ipairs(sessions) do
            if (live.id and live.id == old.id) or
                (not live.id and live.startTs == old.startTs and
                 live.project == old.project and live.seconds == old.seconds and
                 live.rate == old.rate and live.currency == old.currency) then
                duplicate = true
                break
            end
        end
    end
    if live and (tonumber(live.seconds) or 0) > 0 and not duplicate then
        live.id = live.id or newId()
        live.endTs = live.endTs or live.savedAt or (live.startTs + live.seconds)
        -- A normal close (even Resolve quitting) saves the session itself, so
        -- this is a crash, a killed process, power loss, or a save that failed
        -- while Resolve closed the window. Don't name a cause on the invoice.
        local note = live.note or ""
        if not note:find("(recovered", 1, true) then
            live.note = (note ~= "" and (note .. " ") or "") .. "(recovered after an unexpected stop)"
        end
        sess = live
        if closeSession() then
            recoveredNotice = "Recovered a session that was still running when the tracker last stopped: "
                .. fmtHMS(live.seconds)
        end
    else
        removeLive()
    end
end

-- ---------------------------------------------------------------------------
-- Aggregates
-- ---------------------------------------------------------------------------
local function projectTotalSeconds(projName)
    local total = 0
    for _, s in ipairs(sessions) do
        if s.project == projName then total = total + (s.seconds or 0) end
    end
    if sess and sess.project == projName then total = total + sess.seconds end
    return total
end

local function addEarnings(totals, s)
    local currency = s.currency or "unspecified"
    totals[currency] = (totals[currency] or 0) + sessionEarnings(s)
end

local function currencyKeys(totals)
    local keys = {}
    for currency in pairs(totals) do keys[#keys + 1] = currency end
    table.sort(keys)
    return keys
end

local function projectEarnings(projName)
    local totals = {}
    for _, s in ipairs(sessions) do
        if s.project == projName then addEarnings(totals, s) end
    end
    if sess and sess.project == projName then addEarnings(totals, sess) end
    local parts = {}
    for _, currency in ipairs(currencyKeys(totals)) do
        parts[#parts + 1] = currency .. " " .. fmtMoney(totals[currency])
    end
    return #parts > 0 and table.concat(parts, " / ") or (settings.currency .. " 0.00")
end

local function secondsInRange(s, from, to)
    local a = s.startTs or 0
    local b = s.endTs or s.lastTs or s.savedAt or (a + (s.seconds or 0))
    -- Most history lies outside today/this week: skip it without walking segments.
    if b <= from or a >= to then return 0 end
    local function overlap(x, y)
        return math.max(0, math.min(y, to) - math.max(x, from))
    end
    if s.segments then
        local total = 0
        for _, seg in ipairs(s.segments) do total = total + overlap(seg.startTs, seg.endTs) end
        return total
    end
    -- Old sessions have no interval history. Allocate their recorded seconds
    -- proportionally across the saved span instead of inventing extra time.
    if b <= a then return 0 end
    return (s.seconds or 0) * overlap(a, b) / (b - a)
end

local function rangeTotals()
    local timestamp = os.time()
    local now = os.date("*t", timestamp)
    local dayStart = os.time({year=now.year, month=now.month, day=now.day, hour=0})
    -- Let the calendar normalize Monday, including daylight-saving transitions.
    local weekStart = os.time({year=now.year, month=now.month,
        day=now.day - (now.wday + 5) % 7, hour=0})
    local today, week = 0, 0
    local function add(s)
        today = today + secondsInRange(s, dayStart, timestamp)
        week = week + secondsInRange(s, weekStart, timestamp)
    end
    for _, s in ipairs(sessions) do add(s) end
    if sess then add(sess) end
    return today, week
end

local function projectPageTotals(projName)
    local totals = {}
    local function add(s)
        if s.project == projName and s.pages then
            for page, secs in pairs(s.pages) do
                totals[page] = (totals[page] or 0) + secs
            end
        end
    end
    for _, s in ipairs(sessions) do add(s) end
    if sess then add(sess) end
    return totals
end

-- ---------------------------------------------------------------------------
-- CSV export
-- ---------------------------------------------------------------------------
-- Text cells only (project, note, currency). Spreadsheets run a cell that
-- starts with = + - @ (or tab/CR) as a formula, and exports go to clients, so
-- a leading apostrophe keeps such text as text (OWASP CSV injection advice).
local function csvField(v)
    v = tostring(v or "")
    if v:find("^[=+%-@\t\r]") then v = "'" .. v end
    if v:find('[",\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

-- Export every project's sessions, grouped by project and ordered by date.
-- Each session is a row; every project gets a subtotal row, then one grand
-- TOTAL. Same project's days "stack" together with a running subtotal.
local function exportCSV()
    local exportSessions = {}
    for _, session in ipairs(sessions) do exportSessions[#exportSessions + 1] = session end
    if sess and sess.seconds > 0 then
        local snapshot = {}
        for key, value in pairs(sess) do snapshot[key] = value end
        snapshot.endTs = sess.endTs or sess.lastTs
        snapshot.note = (sess.note or "") .. (sess.endTs and " (save pending)" or " (in progress)")
        exportSessions[#exportSessions + 1] = snapshot
    end
    -- Column order: canonical pages first, then any extra pages that appeared
    local pageCols, seen = {}, {}
    for _, p in ipairs(PAGES) do pageCols[#pageCols + 1] = p; seen[p] = true end
    for _, s in ipairs(exportSessions) do
        for page in pairs(s.pages or {}) do
            if not seen[page] then pageCols[#pageCols + 1] = page; seen[page] = true end
        end
    end

    local header = { "Project", "Date", "Start", "End", "Duration", "Hours",
                     "Rate", "Currency", "Earnings", "Note" }
    for _, p in ipairs(pageCols) do
        header[#header + 1] = p:sub(1, 1):upper() .. p:sub(2) .. " Time"
    end
    local NCOL = #header

    -- Group session indices by project, remembering first-seen order
    local groups, order = {}, {}
    for _, s in ipairs(exportSessions) do
        local proj = s.project or "Untitled Project"
        if not groups[proj] then groups[proj] = {}; order[#order + 1] = proj end
        table.insert(groups[proj], s)
    end
    table.sort(order)

    local function blankRow() local r = {}; for _ = 1, NCOL do r[#r + 1] = "" end; return r end
    local function pageCells(pagesOf)
        local cells = {}
        for _, p in ipairs(pageCols) do
            local secs = pagesOf[p] or 0
            cells[#cells + 1] = secs > 0 and fmtHMS(secs) or ""
        end
        return cells
    end

    local lines = { table.concat(header, ",") }
    local gTotSecs, gTotEarn, gTotPages = 0, {}, {}

    local function addSummary(row, earnings)
        local keys = currencyKeys(earnings)
        if #keys == 1 then
            row[8] = csvField(keys[1]); row[9] = fmtMoney(earnings[keys[1]])
        end
        lines[#lines + 1] = table.concat(row, ",")
        if #keys > 1 then
            for _, currency in ipairs(keys) do
                local money = blankRow()
                money[1] = row[1]; money[8] = csvField(currency)
                money[9] = fmtMoney(earnings[currency])
                lines[#lines + 1] = table.concat(money, ",")
            end
        end
    end

    for _, proj in ipairs(order) do
        local list = groups[proj]
        table.sort(list, function(a, b) return (a.startTs or 0) < (b.startTs or 0) end)

        -- A flat-fee project earns its fee: sessions show the target rate but no
        -- earnings of their own, and the subtotal carries the fee.
        local fee = feeFor(proj)
        local pSecs, pEarn, pPages = 0, {}, {}
        for _, s in ipairs(list) do
            pSecs = pSecs + (s.seconds or 0)
            if not fee then addEarnings(pEarn, s); addEarnings(gTotEarn, s) end
            local note = (s.note or "") .. (s.manual and " (manual entry)" or "")
                .. (s.edited and " (edited)" or "")
            local row = {
                csvField(s.project),
                os.date("%Y-%m-%d", s.startTs),
                os.date("%H:%M", s.startTs),
                os.date("%H:%M", s.endTs or s.startTs),
                fmtHMS(s.seconds),
                string.format("%.4f", (s.seconds or 0) / 3600),
                fmtMoney(s.rate),
                csvField(s.currency),
                fee and "" or fmtMoney(sessionEarnings(s)),
                csvField((note:gsub("^%s+", ""))),
            }
            for _, p in ipairs(pageCols) do
                local secs = s.pages and s.pages[p] or 0
                pPages[p] = (pPages[p] or 0) + secs
                gTotPages[p] = (gTotPages[p] or 0) + secs
                row[#row + 1] = secs > 0 and fmtHMS(secs) or ""
            end
            lines[#lines + 1] = table.concat(row, ",")
        end

        -- Per-project subtotal
        local sub = blankRow()
        sub[1] = csvField(proj .. " (subtotal)")
        sub[5] = fmtHMS(pSecs)
        sub[6] = string.format("%.4f", pSecs / 3600)
        local pc = pageCells(pPages)
        for i = 1, #pc do sub[10 + i] = pc[i] end
        if fee then
            local _, currency = rateFor(proj)
            pEarn = { [currency] = fee }
            gTotEarn[currency] = (gTotEarn[currency] or 0) + fee
            sub[10] = csvField("Flat fee. Effective rate " .. (pSecs > 0
                and (currency .. " " .. fmtMoney(fee / (pSecs / 3600)) .. " / hr")
                or "n/a"))
        end
        addSummary(sub, pEarn)
        lines[#lines + 1] = table.concat(blankRow(), ",") -- spacer between projects

        gTotSecs = gTotSecs + pSecs
    end

    local totalRow = blankRow()
    totalRow[1] = "TOTAL (all projects)"
    totalRow[5] = fmtHMS(gTotSecs)
    totalRow[6] = string.format("%.4f", gTotSecs / 3600)
    local gc = pageCells(gTotPages)
    for i = 1, #gc do totalRow[10 + i] = gc[i] end
    addSummary(totalRow, gTotEarn)

    local base = DATA_DIR .. SEP .. os.date("Time_Tracker_%Y%m%d_%H%M%S")
    local path, suffix = base .. ".csv", 1
    while exists(path) do
        path = base .. "_" .. suffix .. ".csv"; suffix = suffix + 1
    end
    local f = io.open(path, "wb")
    if not f then return nil end
    -- The UTF-8 BOM makes Excel read symbols such as € correctly; without it
    -- Excel on Windows assumes the legacy code page.
    local written = f:write("\239\187\191" .. table.concat(lines, "\r\n") .. "\r\n")
    local closed = f:close()
    if not written or not closed then os.remove(path); return nil end
    return path
end

-- ---------------------------------------------------------------------------
-- Client timesheet: one project's hours and notes, no rates or earnings.
-- A printable HTML page (print it to PDF) plus the same table as CSV.
-- ---------------------------------------------------------------------------
local TRACKER_TAGS = { "%(auto%-stopped: idle%)", "%(project switched%)", "%(recovered[^)]*%)",
                       "%(in progress%)", "%(save pending%)" }

-- Notes as the client should see them: without the tracker's own tags.
local function clientNote(note)
    note = note or ""
    for _, tag in ipairs(TRACKER_TAGS) do note = note:gsub("%s*" .. tag, "") end
    return (note:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function htmlEscape(text)
    return (tostring(text or ""):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

-- Lua opens files through the system code page on Windows, so keep file
-- names ASCII; the project name inside the files keeps its real spelling.
local function fileSafe(name)
    local safe = name:gsub("[^%w%-_ ]", "_"):gsub("%s+", " "):gsub("^[ _]+", ""):gsub("[ _]+$", "")
    if safe == "" then safe = "Project" end
    return safe:sub(1, 60)
end

local function pageLabel(page)
    if page == "unknown" then return "Other" end
    if page == "manual" then return "Added manually" end
    return page:sub(1, 1):upper() .. page:sub(2)
end

local function writeText(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    local written = f:write(text)
    local closed = f:close()
    if not written or not closed then os.remove(path); return false end
    return true
end

local function exportClientTimesheet(projName)
    local list = {}
    for _, s in ipairs(sessions) do
        if s.project == projName and (s.seconds or 0) > 0 then list[#list + 1] = s end
    end
    if sess and sess.project == projName and sess.seconds > 0 then
        list[#list + 1] = { startTs = sess.startTs, endTs = sess.endTs or sess.lastTs,
                            seconds = sess.seconds, note = sess.note, pages = sess.pages }
    end
    if #list == 0 then return nil, "No time tracked on this project yet." end
    table.sort(list, function(a, b) return (a.startTs or 0) < (b.startTs or 0) end)

    local total, stages = 0, {}
    local csv = { "Date,Start,End,Duration,Hours,Notes" }
    local rows = {}
    for _, s in ipairs(list) do
        total = total + s.seconds
        for page, secs in pairs(s.pages or {}) do stages[page] = (stages[page] or 0) + secs end
        local date, from = os.date("%Y-%m-%d", s.startTs), os.date("%H:%M", s.startTs)
        local to, note = os.date("%H:%M", s.endTs or s.startTs), clientNote(s.note)
        csv[#csv + 1] = table.concat({ date, from, to, fmtHMS(s.seconds),
            string.format("%.2f", s.seconds / 3600), csvField(note) }, ",")
        rows[#rows + 1] = string.format(
            "<tr><td>%s</td><td>%s to %s</td><td class=\"num\">%s</td><td>%s</td></tr>",
            date, from, to, fmtHMS(s.seconds), htmlEscape(note))
    end
    local hours = string.format("%.2f", total / 3600)
    csv[#csv + 1] = table.concat({ "Total", "", "", fmtHMS(total), hours, "" }, ",")

    local stageOrder, seen = {}, {}
    for _, p in ipairs(PAGES) do stageOrder[#stageOrder + 1] = p; seen[p] = true end
    for p in pairs(stages) do if not seen[p] then stageOrder[#stageOrder + 1] = p end end
    local stageRows = {}
    for _, p in ipairs(stageOrder) do
        local secs = stages[p] or 0
        if secs > 0 then
            stageRows[#stageRows + 1] = string.format(
                "<tr><td>%s</td><td class=\"num\">%s</td><td class=\"num\">%d%%</td></tr>",
                htmlEscape(pageLabel(p)), fmtHMS(secs), math.floor(secs / total * 100 + 0.5))
        end
    end

    local first, last = os.date("%Y-%m-%d", list[1].startTs), os.date("%Y-%m-%d", list[#list].startTs)
    local html = table.concat({
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
        "<title>Timesheet: ", htmlEscape(projName), "</title><style>",
        "body{font-family:-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;color:#222;",
        "margin:40px auto;max-width:820px;padding:0 24px}",
        "h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 0}",
        ".muted{color:#666;font-size:14px}",
        "table{width:100%;border-collapse:collapse;margin-top:12px;font-size:14px}",
        "th,td{text-align:left;padding:7px 8px;border-bottom:1px solid #ddd;vertical-align:top}",
        "th{background:#f4f4f4}.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}",
        "tfoot td{font-weight:700;border-top:2px solid #222;border-bottom:none}",
        "@media print{body{margin:0;padding:0}}</style></head><body>",
        "<h1>Timesheet: ", htmlEscape(projName), "</h1>",
        "<div class=\"muted\">", first, first ~= last and (" to " .. last) or "",
        " &middot; ", #list, #list == 1 and " session" or " sessions",
        " &middot; ", hours, " hours</div>",
        "<table><thead><tr><th>Date</th><th>Time</th><th class=\"num\">Duration</th>",
        "<th>Notes</th></tr></thead><tbody>", table.concat(rows),
        "</tbody><tfoot><tr><td colspan=\"2\">Total</td><td class=\"num\">", fmtHMS(total),
        "</td><td>", hours, " hours</td></tr></tfoot></table>",
        #stageRows > 0 and ("<h2>Time by stage</h2><table><tbody>" .. table.concat(stageRows)
            .. "</tbody></table>") or "",
        "<p class=\"muted\">Prepared ", os.date("%Y-%m-%d"), ".</p></body></html>\n",
    })

    local base = DATA_DIR .. SEP .. "Timesheet_" .. fileSafe(projName) .. os.date("_%Y%m%d_%H%M%S")
    local htmlPath, suffix = base .. ".html", 1
    while exists(htmlPath) do htmlPath = base .. "_" .. suffix .. ".html"; suffix = suffix + 1 end
    local csvPath = htmlPath:gsub("%.html$", ".csv")
    if not writeText(htmlPath, html)
        or not writeText(csvPath, "\239\187\191" .. table.concat(csv, "\r\n") .. "\r\n") then
        os.remove(htmlPath)
        return nil, "Could not write the timesheet. Check disk space and permissions."
    end
    return htmlPath
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local monoFont = ui:Font({ Family = IS_WINDOWS and "Consolas" or "Menlo", PixelSize = 12 })

-- Big action button: blue while stopped ("Start"), red while running ("Stop")
local START_STYLE = "QPushButton { background-color: rgb(43,120,224); color: white; "
    .. "border: none; border-radius: 6px; font-weight: bold; } "
    .. "QPushButton:hover { background-color: rgb(63,140,244); }"
local STOP_STYLE = "QPushButton { background-color: rgb(214,66,66); color: white; "
    .. "border: none; border-radius: 6px; font-weight: bold; } "
    .. "QPushButton:hover { background-color: rgb(230,82,82); }"

local GREEN_BAR = "background-color: rgb(63,185,80); border-radius: 2px;"
local EMPTY_BAR = "background-color: rgba(255,255,255,25); border-radius: 2px;"

-- One HGroup row per page for the "where your time goes" bar graph
local function pageRow(p)
    return ui:HGroup({
        Weight = 0,
        ui:Label({ ID = "Name_" .. p, Text = p, Weight = 0, MinimumSize = { 68, 16 } }),
        ui:Label({ ID = "Bar_" .. p, Text = "", Weight = 0,
                   MinimumSize = { 2, 11 }, MaximumSize = { 2, 11 },
                   StyleSheet = EMPTY_BAR }),
        ui:Label({ ID = "BarPad_" .. p, Text = "", Weight = 1 }),
        ui:Label({ ID = "Time_" .. p, Text = "", Weight = 0, MinimumSize = { 56, 16 },
                   Alignment = { AlignRight = true } }),
    })
end

-- Settings form building blocks (see the form in the window below)
local FORM_LABEL_W = 70
local function formLabel(text)
    return ui:Label({ Text = text, Weight = 0, MinimumSize = { FORM_LABEL_W, 0 },
                      MaximumSize = { FORM_LABEL_W, 32 } })
end
local function formCol(...)
    local col = { Weight = 1, Spacing = 4 }
    for i, item in ipairs({ ... }) do col[i] = item end
    return ui:HGroup(col)
end
local function formRow(left, right)
    return ui:HGroup({ Weight = 0, Spacing = 16, left, right })
end

local pagesBox = { ID = "PagesBox", Weight = 0, Spacing = 3 }
for _, p in ipairs(PAGES) do pagesBox[#pagesBox + 1] = pageRow(p) end

local win = disp:AddWindow({
    ID = "ttwin",
    WindowTitle = "Time Tracker",
    Geometry = { 300, 60, 480, 780 },

    ui:VGroup({
        ID = "root",
        Spacing = 6,

        ui:Label({ ID = "ProjectLbl", Text = "", Weight = 0,
                   Alignment = { AlignHCenter = true } }),
        ui:Label({ ID = "TimeLbl", Text = "0:00:00", Weight = 0,
                   Alignment = { AlignHCenter = true },
                   Font = ui:Font({ PixelSize = 38, Bold = true }) }),
        ui:Button({ ID = "StartBtn", Text = "Start", Weight = 0,
                    MinimumSize = { 120, 38 }, StyleSheet = START_STYLE }),
        ui:Label({ ID = "StatusLbl", Text = "", Weight = 0,
                   Alignment = { AlignHCenter = true }, WordWrap = true }),

        ui:LineEdit({ ID = "NoteEdit", Weight = 0,
                      PlaceholderText = "Session note (optional, saved when you stop)" }),

        -- Settings form: two equal columns; fixed-width labels and short
        -- fields keep every row aligned at any window width.
        formRow(
            formCol(
                formLabel("Rate / hr"),
                ui:ComboBox({ ID = "CurCombo", Weight = 0, MinimumSize = { 58, 24 },
                              MaximumSize = { 58, 32 },
                              ToolTip = "Currency for new sessions. Stop tracking to change it." }),
                ui:LineEdit({ ID = "RateEdit", Text = fmtMoney(settings.rate), Weight = 1,
                              ToolTip = "Hourly rate for new sessions. Stop tracking to change it." })),
            formCol(
                formLabel("Flat fee"),
                ui:LineEdit({ ID = "FeeEdit", Weight = 1, PlaceholderText = "none, billed hourly",
                              ToolTip = "A fixed price for this project. Your hourly rate then "
                                  .. "becomes the target: you see how much time is left before "
                                  .. "the fee stops paying that rate, and what you actually earn "
                                  .. "per hour. Leave empty to bill hourly." }))),
        formRow(
            formCol(
                formLabel("Idle stop"),
                ui:LineEdit({ ID = "IdleEdit", Text = tostring(settings.idleMin), Weight = 0,
                              MinimumSize = { 58, 24 }, MaximumSize = { 58, 32 },
                              ToolTip = "Minutes without mouse or keyboard input before the "
                                  .. "session stops at your last input. 0 turns it off." }),
                ui:Label({ Text = "min", Weight = 1 })),
            formCol(
                ui:CheckBox({ ID = "AutoStartChk", Weight = 1, Checked = settings.autoStart,
                              Text = "Start when opened",
                              ToolTip = "Start tracking automatically whenever this window opens." }))),
        formRow(
            formCol(
                ui:CheckBox({ ID = "RenderChk", Weight = 1, Checked = settings.countRenders,
                              Text = "Count renders",
                              ToolTip = "Keep counting while Resolve renders, even if you step "
                                  .. "away (idle stop waits until the render ends)." })),
            formCol(
                ui:CheckBox({ ID = "FocusChk", Weight = 1, Checked = settings.pauseInBackground,
                              Text = "Pause in background",
                              ToolTip = "Don't count time while another app is in front. The "
                                  .. "session continues when you switch back to Resolve." }))),

        ui:Label({ ID = "OverviewLbl", Text = "OVERVIEW", Weight = 0 }),
        ui:HGroup({
            Weight = 0,
            ui:Label({ ID = "TotalCap", Text = "Project total", Weight = 1 }),
            ui:Label({ ID = "TotalLbl", Text = "0:00:00", Weight = 0 }),
        }),
        ui:HGroup({
            Weight = 0,
            -- The value takes the free width: mixed-currency totals stay on one line.
            ui:Label({ ID = "EarnCap", Text = "Earnings", Weight = 0 }),
            ui:Label({ ID = "EarnLbl", Text = "0.00", Weight = 1,
                       Alignment = { AlignRight = true, AlignVCenter = true } }),
        }),
        -- Always shown: hidden widgets keep their space in Fusion layouts.
        ui:HGroup({
            Weight = 0,
            ui:Label({ ID = "BudgetCap", Text = "Time budget", Weight = 0 }),
            ui:Label({ ID = "BudgetLbl", Text = "", Weight = 1,
                       Alignment = { AlignRight = true, AlignVCenter = true } }),
        }),

        ui:Label({ ID = "PagesCap", Text = "WHERE YOUR TIME GOES", Weight = 0 }),
        ui:VGroup(pagesBox),

        ui:Label({ ID = "AllLbl", Text = "", Weight = 0,
                   Alignment = { AlignHCenter = true } }),

        ui:HGroup({
            Weight = 0,
            ui:Label({ ID = "HistCap", Text = "SESSION HISTORY", Weight = 1 }),
            ui:Button({ ID = "AddBtn", Text = "Add", Weight = 0,
                        ToolTip = "Add time worked outside Resolve to this project" }),
            ui:Button({ ID = "EditBtn", Text = "Edit", Weight = 0,
                        ToolTip = "Change the selected session" }),
            ui:Button({ ID = "DeleteBtn", Text = "Delete", Weight = 0,
                        ToolTip = "Delete the selected session (click twice)" }),
        }),
        ui:Tree({ ID = "HistTree", Weight = 1 }),

        ui:HGroup({
            Weight = 0,
            ui:Button({ ID = "ExportBtn", Text = "Export CSV",
                        ToolTip = "All projects, with rates and earnings, for your records" }),
            ui:Button({ ID = "ClientBtn", Text = "Client Timesheet",
                        ToolTip = "This project's hours and notes without rates, as a "
                            .. "printable page (print to PDF) and a CSV" }),
            ui:Button({ ID = "FolderBtn", Text = "Open Folder" }),
            ui:Button({ ID = "CloseBtn", Text = "Close" }),
        }),
    }),
})

local itm = win:GetItems()

-- Entry editor: add time worked outside Resolve, or correct a session.
-- A second window is safe when Resolve quits: it tears the window down once
-- the main loop has ended, without sending it a Close event (verified live).
local function editorRow(label, id, placeholder)
    return ui:HGroup({
        Weight = 0,
        ui:Label({ Text = label, Weight = 0, MinimumSize = { 78, 0 } }),
        ui:LineEdit({ ID = id, Weight = 1, PlaceholderText = placeholder }),
    })
end
local editWin = disp:AddWindow({
    ID = "EditWin",
    WindowTitle = "Time Tracker entry",
    Geometry = { 360, 220, 380, 270 },
    ui:VGroup({
        Spacing = 6,
        ui:Label({ ID = "EdTitle", Text = "", Weight = 0, WordWrap = true }),
        editorRow("Date", "EdDate", "YYYY-MM-DD"),
        editorRow("Start", "EdStart", "HH:MM"),
        editorRow("Duration", "EdDur", "H:MM, or hours such as 1.5"),
        editorRow("Rate / hr", "EdRate", "hourly rate"),
        editorRow("Note", "EdNote", "what was done"),
        ui:Label({ ID = "EdStatus", Text = "", Weight = 0, WordWrap = true }),
        ui:HGroup({
            Weight = 0,
            ui:Button({ ID = "EdSave", Text = "Save" }),
            ui:Button({ ID = "EdCancel", Text = "Cancel" }),
        }),
    }),
})
local eitm = editWin:GetItems()

if not focus.supported then
    itm.FocusChk.Enabled = false
    itm.FocusChk.Checked = false
    itm.FocusChk.ToolTip = "Available on Windows for now."
end

-- Currency combo
itm.CurCombo:AddItems(CURRENCIES)
for i, c in ipairs(CURRENCIES) do
    if c == settings.currency then itm.CurCombo.CurrentIndex = i - 1 end
end

-- History tree columns
do
    local hdr = itm.HistTree:NewItem()
    hdr.Text[0] = "Date"
    hdr.Text[1] = "Duration"
    hdr.Text[2] = "Earnings"
    hdr.Text[3] = "Note"
    itm.HistTree:SetHeaderItem(hdr)
    itm.HistTree.ColumnCount = 4
    itm.HistTree.ColumnWidth[0] = 135
    itm.HistTree.ColumnWidth[1] = 70
    itm.HistTree.ColumnWidth[2] = 80
end

if recoveredNotice then itm.StatusLbl.Text = recoveredNotice end
if not idle.supported then
    itm.StatusLbl.Text = "Idle detection unavailable (" .. idle.why
        .. "). Tracking runs until you press Stop."
end

local historyProject = nil
refreshHistory = function()
    itm.HistTree:Clear()
    local projName = currentProjectName()
    historyProject = projName
    local shown = 0
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if s.project == projName then
            local it = itm.HistTree:NewItem()
            it.Text[0] = os.date("%Y-%m-%d %H:%M", s.startTs)
            it.Text[1] = fmtHMS(s.seconds)
            -- A flat-fee project earns its fee, not per session.
            it.Text[2] = feeFor(projName) and ""
                or ((s.currency or "") .. " " .. fmtMoney(sessionEarnings(s)))
            it.Text[3] = s.note or ""
            -- Hidden per-row data: Qt stretches the last column, so a
            -- zero-width ID column would still show.
            it:SetData(0, "UserRole", s.id)
            itm.HistTree:AddTopLevelItem(it)
            shown = shown + 1
            if shown >= 200 then break end
        end
    end
end

local BAR_MAX_PX = 150 -- width of the longest bar

-- refreshUI runs every second. Qt re-lays-out or restyles a widget on every
-- property write, so only write values that changed. Use this only for
-- properties that nothing else assigns directly (StatusLbl is written freely).
local shownProps = {}
local function setProp(id, prop, value)
    local key = id .. "." .. prop
    if shownProps[key] == value then return end
    shownProps[key] = value
    itm[id][prop] = value
end

local function setBarWidth(id, w)
    local key = id .. ".width"
    if shownProps[key] == w then return end
    shownProps[key] = w
    itm[id].MinimumSize = { w, 11 }
    itm[id].MaximumSize = { w, 11 }
end

local function refreshPages()
    local totals = projectPageTotals(currentProjectName())
    local maxSecs = 0
    for _, p in ipairs(PAGES) do maxSecs = math.max(maxSecs, totals[p] or 0) end
    for _, p in ipairs(PAGES) do
        local secs = totals[p] or 0
        local w = 2
        if maxSecs > 0 and secs > 0 then
            w = math.max(4, math.floor(secs / maxSecs * BAR_MAX_PX))
        end
        setBarWidth("Bar_" .. p, w)
        setProp("Bar_" .. p, "StyleSheet", secs > 0 and GREEN_BAR or EMPTY_BAR)
        setProp("Time_" .. p, "Text", secs > 0 and fmtHMS(secs) or "")
        setProp("Name_" .. p, "StyleSheet", secs > 0 and "" or "color: rgb(120,120,120);")
    end
end

-- Flat-fee projects: the fee is the earnings; the hourly rate becomes the
-- target, giving a time budget (fee / rate) and an effective hourly rate
-- (fee / hours worked). nil for projects billed hourly.
local BUDGET_OK, BUDGET_WARN, BUDGET_OVER, BUDGET_NONE =
    "color: rgb(63,185,80);", "color: rgb(230,170,40);", "color: rgb(230,82,82);",
    "color: rgb(120,120,120);"
local function flatFeeSummary(projName, totalSecs)
    local fee = feeFor(projName)
    if not fee then return nil end
    local rate, currency = rateFor(projName)
    -- Effective rate: what the fee pays per hour actually worked so far.
    local summary = { earnings = currency .. " " .. fmtMoney(fee) .. " flat fee" .. (totalSecs > 0
        and (" · " .. currency .. " " .. fmtMoney(fee / (totalSecs / 3600)) .. " / hr") or "") }
    if rate and rate > 0 then
        local budget = fee / rate * 3600
        local used = budget > 0 and totalSecs / budget or 0
        if totalSecs <= budget then
            summary.budget = fmtHMS(budget - totalSecs) .. " left of " .. fmtHMS(budget)
        else
            summary.budget = fmtHMS(totalSecs - budget) .. " over the " .. fmtHMS(budget) .. " budget"
        end
        summary.budgetStyle = used > 1 and BUDGET_OVER or used >= 0.8 and BUDGET_WARN or BUDGET_OK
    else
        summary.budget = "set your hourly rate to get one"
        summary.budgetStyle = BUDGET_NONE
    end
    return summary
end

-- Show the rate that applies: the running session's, else the one the open
-- project was last tracked with. An unknown project keeps the last-used rate.
local rateShownFor = nil
local function showProjectRate(projName)
    rateShownFor = projName
    local fee = feeFor(projName)
    itm.FeeEdit.Text = fee and fmtMoney(fee) or ""
    local rate, currency
    if sess and sess.project == projName then
        rate, currency = sess.rate, sess.currency
    elseif settings.projects[projName] and settings.projects[projName].rate then
        rate, currency = rateFor(projName)
    else
        return
    end
    itm.RateEdit.Text = fmtMoney(rate)
    for i, c in ipairs(CURRENCIES) do
        if c == currency then itm.CurCombo.CurrentIndex = i - 1 end
    end
end

local lastStorageStatus = nil
local function refreshUI()
    local projName = currentProjectName()
    if historyProject ~= projName then refreshHistory() end
    local rateProject = sess and sess.project or projName
    if rateShownFor ~= rateProject then showProjectRate(rateProject) end
    setProp("ProjectLbl", "Text", projName)
    setProp("TimeLbl", "Text", fmtHMS(sess and sess.seconds or 0))
    local totalSecs = projectTotalSeconds(projName)
    setProp("TotalLbl", "Text", fmtHMS(totalSecs))
    local flat = flatFeeSummary(projName, totalSecs)
    setProp("EarnLbl", "Text", flat and flat.earnings or projectEarnings(projName))
    setProp("BudgetLbl", "Text", flat and flat.budget or "set a flat fee to get one")
    setProp("BudgetLbl", "StyleSheet", flat and flat.budgetStyle or BUDGET_NONE)
    refreshPages()
    local today, week = rangeTotals()
    setProp("AllLbl", "Text", "All projects · Today " .. fmtHMS(today)
        .. " · This week " .. fmtHMS(week))
    local tracking = state == "running" or state == "armed" or state == "saving"
    if tracking then
        setProp("StartBtn", "Text", state == "saving" and "Retry save" or "Stop")
        setProp("StartBtn", "StyleSheet", STOP_STYLE)
    else
        setProp("StartBtn", "Text", "Start")
        setProp("StartBtn", "StyleSheet", START_STYLE)
    end
    -- Rate and currency are fixed per session (read on Start), so editing them
    -- mid-session would silently do nothing. The idle limit stays live.
    setProp("RateEdit", "Enabled", not tracking)
    setProp("CurCombo", "Enabled", not tracking)
    local storageStatus = nil
    for _, message in pairs(storageErrors) do
        storageStatus = message .. ". Check disk space and permissions."
        break
    end
    if storageStatus then itm.StatusLbl.Text = storageStatus
    elseif lastStorageStatus and itm.StatusLbl.Text == lastStorageStatus then
        itm.StatusLbl.Text = ""
    end
    lastStorageStatus = storageStatus
end

-- ---------------------------------------------------------------------------
-- Settings from the UI
-- ---------------------------------------------------------------------------
-- lenient = true keeps the last valid value for any invalid field instead of
-- refusing; used when closing, so a typo can never trap the window open.
-- quiet = true never redraws (the window may be closing; see shutdown).
local function pullSettings(lenient, quiet)
    local rate = nonnegative(itm.RateEdit.Text)
    local idleMin = nonnegative(itm.IdleEdit.Text)
    if not lenient and (not rate or not idleMin) then
        itm.StatusLbl.Text = "Enter a non-negative rate and idle timeout (0 disables idle stop)."
        return false
    end
    settings.rate = rate or settings.rate
    settings.currency = CURRENCIES[itm.CurCombo.CurrentIndex + 1] or settings.currency
    settings.idleMin = idleMin or settings.idleMin
    settings.autoStart = itm.AutoStartChk.Checked and true or false
    settings.countRenders = itm.RenderChk.Checked and true or false
    settings.pauseInBackground = itm.FocusChk.Checked and true or false
    if not lenient then
        -- Start: this is now the rate for the open project.
        local name = currentProjectName()
        local p = settings.projects[name] or {}
        p.rate, p.currency = settings.rate, settings.currency
        settings.projects[name] = p
    end
    if not saveSettings() then
        if not quiet then refreshUI() end
        return false
    end
    return true
end

-- The flat fee belongs to the project, not to a session, so it can change at
-- any time. TextChanged fires per keystroke (and when the field is filled in
-- for another project); save once on the next tick, and only real changes.
local feeDirty = false
local function saveFee(quiet)
    feeDirty = false
    local text = (itm.FeeEdit.Text or ""):gsub("%s", "")
    local fee = nil
    if text ~= "" then
        fee = nonnegative(text)
        if not fee then
            if not quiet then
                itm.StatusLbl.Text = "Enter the flat fee as a number, or leave it empty to bill hourly."
            end
            return false
        end
        if fee == 0 then fee = nil end
    end
    -- The project whose values the fields show (see showProjectRate).
    local name = rateShownFor or currentProjectName()
    if feeFor(name) == fee then return true end
    local p = settings.projects[name] or {}
    p.fee = fee
    settings.projects[name] = next(p) and p or nil
    if not saveSettings() then
        if not quiet then refreshUI() end
        return false
    end
    -- History rows show per-session earnings only for hourly projects.
    if not quiet then refreshHistory() end
    return true
end

-- ---------------------------------------------------------------------------
-- Tick (fires every second while the window is open)
-- ---------------------------------------------------------------------------
local pausedInputTs = nil
local lastRenderTs = nil -- last tick a counted render was running
local function autoStopIdle(idleSecs, now)
    pausedInputTs = now - idleSecs
    local cutoff = trimAfter(now - math.floor(idleSecs))
    if closeSession("(auto-stopped: idle)", cutoff) then
        state = "armed"
        itm.StatusLbl.Text = "Auto-paused while you were away. Tracking resumes when you're back."
    end
end

local BACKGROUND_NOTICE = "Paused while Resolve is in the background."
local backgroundShown = false
local function showBackgroundNotice(on)
    if on == backgroundShown then return end
    backgroundShown = on
    if on then
        itm.StatusLbl.Text = BACKGROUND_NOTICE
    elseif itm.StatusLbl.Text == BACKGROUND_NOTICE then
        itm.StatusLbl.Text = ""
    end
end

local function bringToFront()
    win:Show()
    pcall(function() win:Raise() end)
    pcall(function() win:ActivateWindow() end)
end

local function tick()
    local now = os.time()
    heartbeat()
    if exists(RAISE_FILE) then
        os.remove(RAISE_FILE)
        bringToFront()
    end
    if state == "saving" then
        if closeSession() then itm.StatusLbl.Text = "Session saved. Press Start to resume." end
    elseif state == "running" and sess then
        sess.note = itm.NoteEdit.Text or ""
        -- Optional: a render counts as work even with nobody at the desk.
        local rendering = settings.countRenders and renderingNow()
        -- Optional: while Resolve is in the background, skip the time since the
        -- last tick instead of counting it. The session stays open, so a quick
        -- look at another app does not split it.
        local background = settings.pauseInBackground and focus.supported
            and not rendering and not focus.resolveActive()
        sess.paused = background or nil
        if background then
            sess.lastTs = math.max(sess.lastTs, now)
        else
            accountUntil(now)
        end
        showBackgroundNotice(background)
        local thr = nonnegative(itm.IdleEdit.Text, settings.idleMin) * 60
        local idleSecs = idle.supported and idle.seconds() or 0
        -- A counted render is activity: idle time starts when it ends, so the
        -- rewind after an idle stop never removes the render itself.
        if rendering then
            lastRenderTs, idleSecs = now, 0
        elseif lastRenderTs then
            idleSecs = math.min(idleSecs, now - lastRenderTs)
        end
        if idle.supported and thr > 0 and idleSecs >= thr then
            autoStopIdle(idleSecs, now)
        else
            -- A switch counts once it is seen on two ticks in a row. Resolve
            -- unloads the project a moment before it closes script windows on
            -- quit; acting on that single sighting added a "(project
            -- switched)" note and a stray one-second "Untitled Project" row.
            local projName = currentProjectName()
            if projName == sess.project then
                pendingSwitch = nil
            elseif not pendingSwitch or pendingSwitch.name ~= projName then
                pendingSwitch = { name = projName, at = now }
            else
                -- Confirmed: move the time since the first sighting to the
                -- new project, so the split happens when the switch did.
                local at = pendingSwitch.at
                trimAfter(at)
                if closeSession("(project switched)", at) then
                    itm.NoteEdit.Text = ""
                    startSession(projName, at)
                    accountUntil(now)
                end
            end
            if sess and state == "running" then
                sess.lastPage = currentPage()
                saveLive()
            end
        end
    elseif state == "armed" then
        if not idle.supported then
            state = "idle"
        elseif now - idle.seconds() > (pausedInputTs or now) + 1 then
            -- Detect new input even if a delayed callback misses the first 2 s.
            -- Allow for the one-second resolution of os.time().
            itm.StatusLbl.Text = ""
            itm.NoteEdit.Text = ""
            startSession(currentProjectName())
        end
    end
    if state ~= "running" then showBackgroundNotice(false) end
    if feeDirty then saveFee() end
    refreshUI()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ticker = ui:Timer({ ID = "Ticker", Interval = 1000, SingleShot = false })

-- Timer timeouts dispatch on disp.On.Timeout (not per-ID); ev.who names the timer
local AUTOTEST = os.getenv("TT_AUTOTEST") ~= nil
local autotestFinish = nil

function disp.On.Timeout(ev)
    local who = ev and ev.who
    if who == "AutoTestGuard" then
        if autotestFinish then autotestFinish() end
        return
    end
    if who and who ~= "Ticker" then return end
    local ok, err = pcall(tick)
    if not ok then
        itm.StatusLbl.Text = "Error: " .. tostring(err)
        if AUTOTEST then print("AUTOTEST tick error: " .. tostring(err)); io.stdout:flush() end
    end
end

function win.On.StartBtn.Clicked(ev)
    if state == "running" or state == "armed" or state == "saving" then
        if sess then
            if not sess.endTs then sess.note = itm.NoteEdit.Text or "" end
            if not closeSession() then refreshUI(); return end
        end
        state = "idle"
        itm.NoteEdit.Text = ""
        itm.StatusLbl.Text = ""
    else
        if not pullSettings() then return end
        itm.StatusLbl.Text = ""
        startSession(currentProjectName())
    end
    refreshUI()
end

function win.On.ExportBtn.Clicked(ev)
    if state == "running" then tick() end
    local path = exportCSV()
    -- A full path has no spaces to wrap on and gets clipped; name the file and
    -- point at Open Folder instead.
    itm.StatusLbl.Text = path
        and ("Exported " .. path:match("[^\\/]+$") .. ". Open Folder shows it.")
        or "Export failed. Check disk space and permissions."
end

function win.On.FolderBtn.Clicked(ev)
    local ok = pcall(bmd.openfileexternal, "Open", DATA_DIR)
    if not ok then itm.StatusLbl.Text = "Data folder: " .. DATA_DIR end
end

function win.On.AutoStartChk.Clicked(ev)
    settings.autoStart = itm.AutoStartChk.Checked and true or false
    if not saveSettings() then refreshUI() end
end

function win.On.RenderChk.Clicked(ev)
    settings.countRenders = itm.RenderChk.Checked and true or false
    if not saveSettings() then refreshUI() end
end

function win.On.FocusChk.Clicked(ev)
    settings.pauseInBackground = focus.supported and itm.FocusChk.Checked and true or false
    if not saveSettings() then refreshUI() end
end

function win.On.FeeEdit.TextChanged(ev) feeDirty = true end

function win.On.ClientBtn.Clicked(ev)
    if state == "running" then tick() end
    local path, problem = exportClientTimesheet(currentProjectName())
    if not path then itm.StatusLbl.Text = problem; return end
    pcall(bmd.openfileexternal, "Open", path) -- shows it in the browser, ready to print
    itm.StatusLbl.Text = "Saved " .. path:match("[^\\/]+$")
        .. " and a matching CSV. Print the page to save a PDF."
end

local function selectedRow()
    local it = itm.HistTree:CurrentItem()
    if not it then
        local ok, selected = pcall(function() return itm.HistTree:SelectedItems() end)
        it = ok and selected and selected[1] or nil
    end
    return it
end

local function findSession(id)
    for i, s in ipairs(sessions) do
        if s.id == id then return s, i end
    end
end

-- ---------------------------------------------------------------------------
-- Adding and editing entries
-- ---------------------------------------------------------------------------
local editing = nil -- { id = session id } when editing, {} when adding

local function parseDuration(text)
    text = (text or ""):gsub("%s", "")
    local h, m, s = text:match("^(%d+):(%d%d):(%d%d)$")
    if not h then h, m = text:match("^(%d+):(%d%d)$"); s = "0" end
    if h then
        h, m, s = tonumber(h), tonumber(m), tonumber(s)
        if m >= 60 or s >= 60 then return nil end
        return h * 3600 + m * 60 + s
    end
    local hours = nonnegative(text)
    return hours and math.floor(hours * 3600 + 0.5) or nil
end

-- Rescales recorded page time to a new duration; the remainder goes to the
-- biggest page so the parts always add up to the whole.
local function scalePages(pages, from, to)
    if not pages or from <= 0 or not next(pages) then return { manual = to } end
    local out, used, biggest = {}, 0, nil
    for page, secs in pairs(pages) do
        local v = math.floor(secs * to / from)
        out[page], used = v, used + v
        if not biggest or secs > pages[biggest] then biggest = page end
    end
    out[biggest] = out[biggest] + (to - used)
    return out
end

local function openEditor(s)
    local projName = currentProjectName()
    editing = s and { id = s.id } or {}
    local startTs = s and s.startTs or (os.time() - 3600)
    local rate = s and s.rate or rateFor(projName)
    eitm.EdTitle.Text = s and ("Edit a session of " .. projName)
        or ("Add time worked outside Resolve to " .. projName)
    eitm.EdDate.Text = os.date("%Y-%m-%d", startTs)
    eitm.EdStart.Text = os.date("%H:%M", startTs)
    eitm.EdDur.Text = s and fmtHMS(s.seconds) or "1:00"
    eitm.EdRate.Text = fmtMoney(rate)
    eitm.EdNote.Text = s and (s.note or "") or ""
    eitm.EdStatus.Text = ""
    editWin:Show()
    pcall(function() editWin:Raise() end)
end

function win.On.AddBtn.Clicked(ev) openEditor(nil) end

function win.On.EditBtn.Clicked(ev)
    local it = selectedRow()
    local s = it and findSession(it:GetData(0, "UserRole"))
    if not s then
        itm.StatusLbl.Text = "Select a session in the history to edit it."
        return
    end
    openEditor(s)
end

local function closeEditor()
    editing = nil
    editWin:Hide()
end

function editWin.On.EdCancel.Clicked(ev) closeEditor() end
function editWin.On.EditWin.Close(ev) closeEditor() end

function editWin.On.EdSave.Clicked(ev)
    if not editing then return end
    local function problem(text) eitm.EdStatus.Text = text end
    local y, mo, d = (eitm.EdDate.Text or ""):match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*$")
    local hh, mi = (eitm.EdStart.Text or ""):match("^%s*(%d%d?):(%d%d)%s*$")
    if not y then return problem("Enter the date as YYYY-MM-DD.") end
    if not hh or tonumber(hh) > 23 or tonumber(mi) > 59 then
        return problem("Enter the start time as HH:MM.")
    end
    local startTs = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                              hour = tonumber(hh), min = tonumber(mi), sec = 0 })
    local check = os.date("*t", startTs)
    if check.month ~= tonumber(mo) or check.day ~= tonumber(d) then
        return problem("That date does not exist.")
    end
    local seconds = parseDuration(eitm.EdDur.Text)
    if not seconds or seconds <= 0 or seconds > 24 * 3600 then
        return problem("Enter a duration such as 1:30 or 1.5 (at most 24 hours).")
    end
    local rate = nonnegative(eitm.EdRate.Text)
    if not rate then return problem("Enter a non-negative hourly rate.") end
    local note = eitm.EdNote.Text or ""

    local projName = currentProjectName()
    if editing.id then
        local s = findSession(editing.id)
        if not s then return problem("That session no longer exists.") end
        local before = {}
        for k, v in pairs(s) do before[k] = v end
        if startTs ~= s.startTs or seconds ~= s.seconds then
            -- Calendar totals then spread the time across the new span.
            s.pages = scalePages(s.pages, s.seconds or 0, seconds)
            s.segments = nil
            s.startTs, s.endTs, s.seconds = startTs, startTs + seconds, seconds
        end
        s.rate, s.note, s.edited = rate, note, true
        if not saveSessions() then
            for k in pairs(s) do s[k] = nil end
            for k, v in pairs(before) do s[k] = v end
            return problem("Could not save. Check disk space and permissions.")
        end
        itm.StatusLbl.Text = "Session updated."
    else
        local _, currency = rateFor(projName)
        sessions[#sessions + 1] = {
            id = newId(), project = projName, startTs = startTs, endTs = startTs + seconds,
            seconds = seconds, rate = rate, currency = currency, note = note,
            pages = { manual = seconds }, manual = true,
        }
        if not saveSessions() then
            table.remove(sessions)
            return problem("Could not save. Check disk space and permissions.")
        end
        itm.StatusLbl.Text = "Added " .. fmtHMS(seconds) .. " to " .. projName .. "."
    end
    closeEditor()
    refreshHistory()
    refreshUI()
end

-- Deleting billable history cannot be undone, so it takes a second click on
-- the same row within a few seconds.
local DELETE_CONFIRM_S = 5
local pendingDelete = nil -- {id=, at=}

function win.On.DeleteBtn.Clicked(ev)
    local it = selectedRow()
    if not it then
        itm.StatusLbl.Text = "Select a session in the history first."
        return
    end
    local id, now = it:GetData(0, "UserRole"), os.time()
    if not (pendingDelete and pendingDelete.id == id
            and now - pendingDelete.at <= DELETE_CONFIRM_S) then
        pendingDelete = { id = id, at = now }
        itm.StatusLbl.Text = "Click Delete again to remove the "
            .. it.Text[1] .. " session from " .. it.Text[0] .. "."
        return
    end
    pendingDelete = nil
    local projName = currentProjectName()
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if s.project == projName and s.id == id then
            table.remove(sessions, i)
            if not saveSessions() then
                table.insert(sessions, i, s)
                refreshUI()
                return
            end
            refreshHistory()
            refreshUI()
            itm.StatusLbl.Text = "Session deleted."
            return
        end
    end
    itm.StatusLbl.Text = "Could not match that session."
end

-- byWindowClose: the window's X, or Resolve closing every script window as it
-- quits. Touching the window after that (redraws, Hide) makes Resolve abandon
-- the quit and linger without a window, which blocks reopening it.
local function shutdown(byWindowClose)
    closingWindow = byWindowClose
    if sess then
        if not sess.endTs then sess.note = itm.NoteEdit.Text or "" end
        if not closeSession() and not byWindowClose then
            -- Close button: keep the window open and retry the save.
            refreshUI()
            return
        end
        -- Closing by X or with Resolve: the window cannot stay. A session whose
        -- history save failed is frozen in live.lua and recovered next time.
    end
    if feeDirty then saveFee(byWindowClose) end
    pullSettings(true, byWindowClose)
    ticker:Stop()
    if not byWindowClose then win:Hide() end
    disp:ExitLoop()
end

function win.On.CloseBtn.Clicked(ev) shutdown(false) end
function win.On.ttwin.Close(ev) shutdown(true) end

-- ---------------------------------------------------------------------------
-- Go
-- ---------------------------------------------------------------------------
refreshHistory()
-- Not after a failed crash recovery: that session must be saved first.
if settings.autoStart and state == "idle" then startSession(currentProjectName()) end
refreshUI()
win:Show()

-- Export-only test: builds the whole UI (so bar/button code runs), exports the
-- sessions already on disk, prints the path, and exits without the tick loop.
if os.getenv("TT_EXPORT_TEST") then
    print("EXPORT_TEST: sessions loaded=" .. #sessions)
    print("EXPORT_TEST: csv=" .. tostring(exportCSV()))
    io.stdout:flush()
    ticker:Stop()
    win:Hide()
    os.remove(LOCK_FILE)
    return
end

-- Headless self-test: TT_AUTOTEST=1 starts a session, lets the real tick loop
-- run ~6 s, then closes the session, exports a CSV, and exits.
if AUTOTEST then
    pullSettings()
    startSession(currentProjectName())
    autotestFinish = function()
        print("AUTOTEST: state=" .. state
            .. " live_seconds=" .. tostring(sess and sess.seconds))
        if sess then
            sess.note = "autotest"
            closeSession()
        end
        state = "idle"
        print("AUTOTEST: sessions=" .. #sessions)
        local last = sessions[#sessions]
        if last then
            local pages = {}
            for k, v in pairs(last.pages or {}) do pages[#pages + 1] = k .. ":" .. v end
            print(string.format("AUTOTEST: last=%ds rate=%s pages=%s note=%s",
                last.seconds, tostring(last.rate), table.concat(pages, ","),
                tostring(last.note)))
        end
        print("AUTOTEST: csv=" .. tostring(exportCSV()))
        io.stdout:flush()
        ticker:Stop()
        disp:ExitLoop()
    end
    local guard = ui:Timer({ ID = "AutoTestGuard", Interval = 6000, SingleShot = true })
    guard:Start()
    print("AUTOTEST: started, idle.supported=" .. tostring(idle.supported))
    io.stdout:flush()
end

ticker:Start()
disp:RunLoop()
-- No win:Hide() here: shutdown() already hid the window if it should; calling
-- into it now would stall Resolve's quit (see shutdown).
os.remove(LOCK_FILE) -- RunLoop only returns after a clean shutdown

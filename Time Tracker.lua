--[[----------------------------------------------------------------------------
Time Tracker for DaVinci Resolve
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
  - Hourly rate + currency, earnings per session (rate changes are historical)
  - One-click CSV export of all projects (grouped, subtotalled, per-page columns)
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

local function startSession(projName)
    if sess then return false end
    local now = os.time()
    sess = {
        id = newId(), project = projName or currentProjectName(),
        startTs = now, lastTs = now, lastPage = currentPage(),
        seconds = 0, rate = settings.rate, currency = settings.currency,
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
        accountUntil(endTs or os.time())
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

        local pSecs, pEarn, pPages = 0, {}, {}
        for _, s in ipairs(list) do
            local earn = sessionEarnings(s)
            pSecs = pSecs + (s.seconds or 0)
            addEarnings(pEarn, s); addEarnings(gTotEarn, s)
            local row = {
                csvField(s.project),
                os.date("%Y-%m-%d", s.startTs),
                os.date("%H:%M", s.startTs),
                os.date("%H:%M", s.endTs or s.startTs),
                fmtHMS(s.seconds),
                string.format("%.4f", (s.seconds or 0) / 3600),
                fmtMoney(s.rate),
                csvField(s.currency),
                fmtMoney(earn),
                csvField(s.note),
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

local pagesBox = { ID = "PagesBox", Weight = 0, Spacing = 3 }
for _, p in ipairs(PAGES) do pagesBox[#pagesBox + 1] = pageRow(p) end

local win = disp:AddWindow({
    ID = "ttwin",
    WindowTitle = "Time Tracker",
    Geometry = { 300, 100, 480, 760 },

    ui:VGroup({
        ID = "root",
        Spacing = 6,

        ui:Label({ ID = "TitleLbl", Text = "TIME TRACKER", Weight = 0,
                   Alignment = { AlignHCenter = true } }),
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

        ui:HGroup({
            Weight = 0,
            ui:Label({ ID = "RateLbl", Text = "Rate / hr", Weight = 0 }),
            ui:ComboBox({ ID = "CurCombo", Weight = 0, MinimumSize = { 55, 24 } }),
            ui:LineEdit({ ID = "RateEdit", Text = fmtMoney(settings.rate), Weight = 1 }),
            ui:Label({ ID = "IdleLbl", Text = "  Idle stop (min)", Weight = 0 }),
            ui:LineEdit({ ID = "IdleEdit", Text = tostring(settings.idleMin),
                          Weight = 0, MinimumSize = { 45, 24 } }),
        }),
        ui:CheckBox({ ID = "AutoStartChk", Weight = 0, Checked = settings.autoStart,
                      Text = "Start tracking automatically when this window opens" }),

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

        ui:Label({ ID = "PagesCap", Text = "WHERE YOUR TIME GOES", Weight = 0 }),
        ui:VGroup(pagesBox),

        ui:Label({ ID = "AllLbl", Text = "", Weight = 0,
                   Alignment = { AlignHCenter = true } }),

        ui:Label({ ID = "HistCap", Text = "SESSION HISTORY", Weight = 0 }),
        ui:Tree({ ID = "HistTree", Weight = 1 }),

        ui:HGroup({
            Weight = 0,
            ui:Button({ ID = "ExportBtn", Text = "Export CSV" }),
            ui:Button({ ID = "FolderBtn", Text = "Open Folder" }),
            ui:Button({ ID = "DeleteBtn", Text = "Delete Selected" }),
            ui:Button({ ID = "CloseBtn", Text = "Close" }),
        }),
    }),
})

local itm = win:GetItems()

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
            it.Text[2] = (s.currency or "") .. " " .. fmtMoney(sessionEarnings(s))
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

local lastStorageStatus = nil
local function refreshUI()
    local projName = currentProjectName()
    if historyProject ~= projName then refreshHistory() end
    setProp("ProjectLbl", "Text", projName)
    setProp("TimeLbl", "Text", fmtHMS(sess and sess.seconds or 0))
    setProp("TotalLbl", "Text", fmtHMS(projectTotalSeconds(projName)))
    setProp("EarnLbl", "Text", projectEarnings(projName))
    refreshPages()
    local today, week = rangeTotals()
    setProp("AllLbl", "Text", "All projects · Today " .. fmtHMS(today)
        .. " · This week " .. fmtHMS(week))
    if state == "running" or state == "armed" or state == "saving" then
        setProp("StartBtn", "Text", state == "saving" and "Retry save" or "Stop")
        setProp("StartBtn", "StyleSheet", STOP_STYLE)
    else
        setProp("StartBtn", "Text", "Start")
        setProp("StartBtn", "StyleSheet", START_STYLE)
    end
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
    if not saveSettings() then
        if not quiet then refreshUI() end
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Tick (fires every second while the window is open)
-- ---------------------------------------------------------------------------
local pausedInputTs = nil
local function autoStopIdle(idleSecs, now)
    pausedInputTs = now - idleSecs
    local cutoff = trimAfter(now - math.floor(idleSecs))
    if closeSession("(auto-stopped: idle)", cutoff) then
        state = "armed"
        itm.StatusLbl.Text = "Auto-paused while you were away. Tracking resumes when you're back."
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
        accountUntil(now)
        local thr = nonnegative(itm.IdleEdit.Text, settings.idleMin) * 60
        local idleSecs = idle.supported and idle.seconds() or 0
        if idle.supported and thr > 0 and idleSecs >= thr then
            autoStopIdle(idleSecs, now)
        else
            local projName = currentProjectName()
            if projName ~= sess.project then
                if closeSession("(project switched)") then
                    itm.NoteEdit.Text = ""
                    startSession(projName)
                end
            else
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

-- Deleting billable history cannot be undone, so it takes a second click on
-- the same row within a few seconds.
local DELETE_CONFIRM_S = 5
local pendingDelete = nil -- {id=, at=}

function win.On.DeleteBtn.Clicked(ev)
    local it = itm.HistTree:CurrentItem()
    if not it then
        local ok, selected = pcall(function() return itm.HistTree:SelectedItems() end)
        it = ok and selected and selected[1] or nil
    end
    if not it then
        itm.StatusLbl.Text = "Select a session in the history first."
        return
    end
    local id, now = it:GetData(0, "UserRole"), os.time()
    if not (pendingDelete and pendingDelete.id == id
            and now - pendingDelete.at <= DELETE_CONFIRM_S) then
        pendingDelete = { id = id, at = now }
        itm.StatusLbl.Text = "Click Delete Selected again to remove the "
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

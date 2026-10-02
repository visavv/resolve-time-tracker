-- Standalone API smoke test, run via:
--   fuscript -l lua "test\api_test.lua"
-- Verifies the three risky building blocks without opening any UI:
--   1. attach to a running Resolve + read project name
--   2. GetCurrentPage()
--   3. ffi idle-seconds (GetLastInputInfo on Windows)

print("=== Time Tracker API smoke test ===")

-- 1+2: Resolve attach
local resolve = resolve or (bmd and bmd.scriptapp and bmd.scriptapp("Resolve"))
if resolve then
    local ok, page = pcall(function() return resolve:GetCurrentPage() end)
    print("Resolve attached: yes")
    print("GetCurrentPage(): " .. tostring(ok and page or "ERROR"))
    local ok2, name = pcall(function()
        local proj = resolve:GetProjectManager():GetCurrentProject()
        return proj and proj:GetName() or "(no project)"
    end)
    print("Current project:  " .. tostring(ok2 and name or "ERROR"))
else
    print("Resolve attached: NO (is Resolve running? external scripting allowed?)")
end

-- 3: ffi idle detection
local ok, ffi = pcall(require, "ffi")
if ok and ffi and ffi.os == "Windows" then
    local okDef, err = pcall(ffi.cdef, [[
        typedef struct { unsigned int cbSize; unsigned int dwTime; } TT_LASTINPUTINFO;
        int GetLastInputInfo(TT_LASTINPUTINFO *plii);
        unsigned int GetTickCount(void);
    ]])
    local okU, user32   = pcall(ffi.load, "user32")
    local okK, kernel32 = pcall(ffi.load, "kernel32")
    if okDef and okU and okK then
        local lii = ffi.new("TT_LASTINPUTINFO")
        lii.cbSize = ffi.sizeof("TT_LASTINPUTINFO")
        if user32.GetLastInputInfo(lii) ~= 0 then
            local idleMs = kernel32.GetTickCount() - lii.dwTime
            print(string.format("ffi idle detection: OK, idle for %.1f s", idleMs / 1000))
        else
            print("ffi idle detection: GetLastInputInfo returned 0")
        end
    else
        print("ffi idle detection: bindings FAILED: " .. tostring(err))
    end
else
    print("ffi idle detection: ffi not available (" .. tostring(ffi and ffi.os) .. ")")
end
print("=== done ===")

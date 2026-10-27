-- Insta360 Import: choose Insta360 X5 .insv clips and prepare them for editing.
--
-- For each clip the import tool (tools/ingest.py, run with Resolve's own Python) copies the two
-- lenses into separate files and reads and refines the lens calibration, showing a progress
-- window. This script then builds the clip in the open project: a compound clip "<name> 360"
-- in the "Insta360" bin, ready for the Insta360 Stitch effect.
--
-- Everything that touches the project happens here, inside Resolve, so no external scripting
-- setting is needed. @INGEST@ is filled in when the script is installed.
local INGEST = "@INGEST@"
local BIN_NAME = "Insta360"
local SOURCE_BIN_NAME = "Source files"   -- inside BIN_NAME: the lens files the 360 clips are made from
local PYTHONS = {
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolvePython",
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python3",
}

local function quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function dialog(text)
    os.execute("osascript -e " .. quote('display dialog "' .. text:gsub("\\", "\\\\"):gsub('"', '\\"')
        .. '" with title "Insta360 Import" buttons {"OK"} default button 1') .. " >/dev/null 2>&1")
end

-- Clips to import: INSTA360_FILES (newline separated) skips the file dialog, for testing.
local list = os.getenv("INSTA360_FILES")
if not list then
    local script = {
        'set picked to choose file with prompt "Choose Insta360 .insv clips to import" with multiple selections allowed',
        'set out to ""',
        'repeat with f in picked',
        'set out to out & POSIX path of f & linefeed',
        'end repeat',
        'return out',
    }
    local cmd = "osascript"
    for _, line in ipairs(script) do
        cmd = cmd .. " -e " .. quote(line)
    end
    local pipe = io.popen(cmd .. " 2>/dev/null")
    list = pipe:read("*a")
    pipe:close()
end
local files = {}
for path in list:gmatch("[^\n]+") do
    if path:lower():match("%.insv$") then
        table.insert(files, quote(path))
    end
end
if #files == 0 then
    print("Insta360 Import: no .insv files chosen")
    return
end

local resolveApp = resolve or (Resolve and Resolve()) or (bmd and bmd.scriptapp("Resolve"))
local project = resolveApp and resolveApp:GetProjectManager():GetCurrentProject()
if not project then
    dialog("Open a project in DaVinci Resolve first.")
    return
end

local python
for _, candidate in ipairs(PYTHONS) do
    if exists(candidate) then
        python = candidate
        break
    end
end
if not python then
    dialog("No Python found. Insta360 Import needs DaVinci Resolve 21.1 or later, which includes one.")
    return
end

-- 1. Copy the lenses and work out the calibration (shows its own progress window).
local report = os.tmpname()
os.execute(quote(python) .. " " .. quote(INGEST) .. " --no-resolve --progress --report " .. quote(report) .. " "
    .. table.concat(files, " ") .. " >/dev/null 2>&1")

local clips, messages = {}, {}
local f = io.open(report, "r")
if f then
    for line in f:lines() do
        local fields = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
            table.insert(fields, field)
        end
        if fields[1] == "FAILED" then
            table.insert(messages, fields[2])
        elseif #fields >= 6 then
            table.insert(clips, {name = fields[1], lensA = fields[2], lensB = fields[3], width = tonumber(fields[4]),
                                 height = tonumber(fields[5]), fps = fields[6], note = fields[7] or "",
                                 tag = fields[8] or ""})
        end
    end
    f:close()
end
os.remove(report)
if #clips == 0 and #messages == 0 then
    dialog("The import tool did not run. Check that the Insta360 Stitch plugin is installed.")
    return
end

-- 2. Build each prepared clip in the project.
local pool = project:GetMediaPool()
local folder
for _, sub in ipairs(pool:GetRootFolder():GetSubFolderList() or {}) do
    if sub:GetName() == BIN_NAME then
        folder = sub
    end
end
folder = folder or pool:AddSubFolder(pool:GetRootFolder(), BIN_NAME)

-- The bin shows only the "<name> 360" clips people edit with; the lens files they are made
-- from go into a sub-bin. Lens files left in the bin by earlier imports are tidied away too.
local sourceFolder
for _, sub in ipairs(folder:GetSubFolderList() or {}) do
    if sub:GetName() == SOURCE_BIN_NAME then
        sourceFolder = sub
    end
end
sourceFolder = sourceFolder or pool:AddSubFolder(folder, SOURCE_BIN_NAME)
local stray = {}
for _, item in ipairs(folder:GetClipList() or {}) do
    local name = item:GetName() or ""
    if name:match("_lens[AB]%.mov$") or name:match("_tag%.mov$") then
        table.insert(stray, item)
    end
end
if #stray > 0 then
    pool:MoveClips(stray, sourceFolder)
end
pool:SetCurrentFolder(folder)

local function basename(path)
    return path:match("([^/]+)$")
end

-- The clip's tag (see tools/clip_tag.py), a transparent movie as long as the clip, over it on a
-- third track, so the plugin can tell which clip it is working on.
local function addTagTrack(timeline, tagPath, start)
    if tagPath == "" or not exists(tagPath) then
        return {}, nil
    end
    local imported = pool:ImportMedia({tagPath}) or {}
    if not imported[1] then
        return {}, nil
    end
    timeline:AddTrack("video")
    local items = pool:AppendToTimeline({{mediaPoolItem = imported[1], trackIndex = 3, recordFrame = start}}) or {}
    for _, item in ipairs(items) do
        item:SetProperty("Scaling", 4)
    end
    return items, imported[1]
end

-- Diagnostics for layouts Resolve did not accept, in a file the user can send.
local LOG = (os.getenv("HOME") or "/tmp") .. "/Library/Logs/Insta360Import.log"
local function log(text)
    local f = io.open(LOG, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S  ") .. text .. "\n")
        f:close()
    end
end

-- Puts one lens on its half of the frame (see the comment in build) and checks that Resolve
-- really applied it, trying the all-at-once form if the one-by-one form was not taken.
local function placeLens(item, side, width)
    local wanted = {Scaling = 4, ZoomGang = false, ZoomX = 0.5, ZoomY = 1.0, Pan = side * width / 4.0}
    local function applied()
        for key, value in pairs(wanted) do
            local got = item:GetProperty(key)
            if type(value) == "number" then
                if type(got) ~= "number" or math.abs(got - value) > 1e-3 * math.max(1, math.abs(value)) then
                    return false, key .. "=" .. tostring(got)
                end
            elseif got ~= value and not (value == false and (got == 0 or got == nil)) then
                return false, key .. "=" .. tostring(got)
            end
        end
        return true
    end
    for _, key in ipairs({"Scaling", "ZoomGang", "ZoomX", "ZoomY", "Pan"}) do
        item:SetProperty(key, wanted[key])
    end
    local ok, problem = applied()
    if not ok then
        log("lens layout not taken one by one (" .. problem .. "); trying SetProperties")
        local all = {RetimeAndScalingEnabled = true, TransformEnabled = true}
        for key, value in pairs(wanted) do
            all[key] = value
        end
        if item.SetProperties then
            item:SetProperties(all)
        end
        ok, problem = applied()
    end
    if not ok then
        log("lens layout rejected by Resolve " .. tostring(resolveApp:GetVersionString()) .. ": " .. problem)
    end
    return ok, problem
end

local function build(clip)
    local compoundName = clip.name .. " 360"
    for _, existing in ipairs(folder:GetClipList() or {}) do
        if existing:GetName() == compoundName then
            return "already in the bin, skipped"
        end
    end

    if project:GetTimelineCount() == 0 then
        project:SetSetting("timelineFrameRate", clip.fps)
    end
    local imported = pool:ImportMedia({clip.lensA, clip.lensB}) or {}
    local a, b
    for _, item in ipairs(imported) do
        if item:GetName() == basename(clip.lensA) then a = item end
        if item:GetName() == basename(clip.lensB) then b = item end
    end
    if not a or not b then
        return "FAILED: Resolve did not import both lens files"
    end

    local timeline = pool:CreateEmptyTimeline(clip.name .. " dual")
    if not timeline then
        return "FAILED: could not create its timeline (name already used?)"
    end
    local width, height = 2 * clip.width, clip.height
    timeline:SetSetting("useCustomSettings", "1")
    timeline:SetSetting("timelineResolutionWidth", tostring(width))
    timeline:SetSetting("timelineResolutionHeight", tostring(height))
    if tonumber(timeline:GetSetting("timelineFrameRate")) ~= tonumber(clip.fps) then
        timeline:SetSetting("timelineFrameRate", clip.fps)
    end

    timeline:AddTrack("video")
    local start = timeline:GetStartFrame()
    local itemA = (pool:AppendToTimeline({{mediaPoolItem = a, trackIndex = 1, recordFrame = start}}) or {})[1]
    local itemB = (pool:AppendToTimeline({{mediaPoolItem = b, trackIndex = 2, recordFrame = start}}) or {})[1]
    if not itemA or not itemB then
        return "FAILED: could not place the lenses on its timeline"
    end
    -- Same layout as tools/ingest.py build(): each lens stretched over the frame, squeezed to
    -- half its width and moved a quarter of the width to its side, so lens A fills the left half
    -- and lens B the right half in a timeline of any shape.
    for _, placed in ipairs({{itemA, -1}, {itemB, 1}}) do
        local ok, problem = placeLens(placed[1], placed[2], width)
        if not ok then
            return "FAILED: Resolve did not accept the lens layout (" .. problem .. "). Please send ~/Library/Logs/Insta360Import.log"
        end
    end
    local tagItems, tagMedia = addTagTrack(timeline, clip.tag, start)
    local parts = {itemA, itemB}
    for _, item in ipairs(tagItems) do
        table.insert(parts, item)
    end
    if not timeline:CreateCompoundClip(parts, {name = compoundName}) then
        return "FAILED: could not create the compound clip"
    end
    -- The working timeline is not needed once the compound clip exists (it keeps its own copy),
    -- and the lens files go out of sight into the sub-bin.
    pool:DeleteTimelines({timeline})
    pool:MoveClips(tagMedia and {a, b, tagMedia} or {a, b}, sourceFolder)
    pool:SetCurrentFolder(folder)
    return "ready"
end

local imported = 0
for _, clip in ipairs(clips) do
    local ok, result = pcall(build, clip)
    result = ok and result or ("FAILED: " .. tostring(result))
    if result == "ready" then
        imported = imported + 1
    end
    table.insert(messages, clip.name .. ": " .. result .. (clip.note ~= "" and (" (" .. clip.note .. ")") or ""))
end
if imported > 0 then
    table.insert(messages, "")
    table.insert(messages, "Use the '<name> 360' clips in the '" .. BIN_NAME .. "' bin: put one on a timeline and add the Insta360 Stitch effect. "
        .. "(The lens files they are made from are in '" .. SOURCE_BIN_NAME .. "'; leave them there.)")
end
print("Insta360 Import:\n" .. table.concat(messages, "\n"))
dialog(table.concat(messages, "\n"))

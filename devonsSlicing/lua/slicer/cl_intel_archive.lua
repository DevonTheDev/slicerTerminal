-- A private, disposable archive view. It never owns a terminal or latest intel.
local previous = slicerIntelArchiveController
local module = {}
slicerIntelArchiveController = module
if type(previous) == "table" then
    previous.replaced = true
    if type(previous.retire) == "function" then previous.retire() end
end
if slicerIntelArchiveController ~= module then return end

-- This holder belongs to the Lua VM, not a frame or a replaceable module.
-- The marker prevents a missing/corrupted holder from becoming a fresh zero.
if previous == nil and slicerIntelArchiveSerialInitialized == nil and slicerIntelArchiveSerialState == nil then
    slicerIntelArchiveSerialState = {value = 0}
    slicerIntelArchiveSerialInitialized = true
end
local serialState = slicerIntelArchiveSerialState

local REQUEST, REPLY = "SlicerIntelArchiveRequest", "SlicerIntelArchiveReply"
local UNAVAILABLE = "Saved intel is unavailable on this server. You can still use !readIntel."
local SEND_FAILED = "Saved intel could not be requested. Refresh/select again."
local DISPLAY_FAILED = "Saved intel could not be displayed. Refresh/select again."
local SERIAL_FAILED = "Saved intel requests are unavailable for this connection."
local function supportedSize(width, height)
    return type(width) == "number" and type(height) == "number"
        and width == width and height == height and width < math.huge and height < math.huge
        and width >= 640 and height >= 480
end

local function owns(controller, identity)
    return slicerIntelArchiveController == module and not module.replaced and module.active == controller
        and not controller.retired and controller.frame ~= nil
        and (identity == nil or controller.identity == identity)
end

-- Panel getters can call back into Lua. Recheck the captured owners afterwards.
local function live(controller, identity)
    if not owns(controller, identity) then return false end
    local frame = controller.frame
    local ok, visible = pcall(function()
        return IsValid(frame) and not frame:IsMarkedForDeletion() and frame:IsVisible()
    end)
    return ok and visible and owns(controller, identity) and controller.frame == frame
end

local function pending(controller, attempt)
    return attempt.controller == controller and controller.frame == attempt.frame
        and controller.pending == attempt and live(controller, attempt)
        and controller.pending == attempt and controller.frame == attempt.frame
end

local function retire(controller)
    if not controller then return end
    if module.active == controller then module.active = nil end
    controller.retired = true
    controller.pending, controller.identity, controller.rendering = nil, nil, nil
    controller.entries, controller.listToken, controller.selected, controller.displayed = nil, nil, nil, nil
    local frame = controller.frame
    controller.frame = nil
    return frame
end

function module.retire()
    if module.retiring then return end
    module.retiring = true
    local frame = retire(module.active)
    if frame then
        pcall(function()
            if IsValid(frame) and not frame:IsMarkedForDeletion() then frame:Remove() end
        end)
    end
    module.retiring = false
end

local function notify(text)
    pcall(function() chat.AddText(Color(255, 251, 0), text) end)
end

local function fail(controller, attempt, message)
    if not pending(controller, attempt) then return end
    controller.pending = nil
    if controller.rendering == attempt then controller.rendering = nil end
    local ok = pcall(function()
        if live(controller, attempt) then controller.status:SetText(message) end
    end)
    if not ok and live(controller, attempt) then notify(message) end
end

local function nextToken()
    if slicerIntelArchiveSerialInitialized ~= true or serialState ~= slicerIntelArchiveSerialState
        or type(serialState) ~= "table" or type(serialState.value) ~= "number"
        or serialState.value ~= serialState.value or serialState.value < 0
        or serialState.value % 1 ~= 0 or serialState.value >= 9007199254740991 then return nil end
    serialState.value = serialState.value + 1
    return string.format("%.0f", serialState.value)
end

local function footer(count)
    return "Saved " .. count .. "/10. The newest 10 clues are kept for this connection; a new clue removes the oldest when full. Refresh for the latest list. Disconnect/map change loses them."
end

local function metadata(entry)
    return "#" .. entry.award .. " — " .. entry.fileName .. (entry.folder == 0 and ".data" or ".sys")
        .. " — " .. entry.consoleName
end

local function change(controller, attempt, action)
    if not pending(controller, attempt) then return false end
    action()
    return pending(controller, attempt)
end

local function send(controller, attempt)
    if not pending(controller, attempt) then return end
    if not attempt.request then fail(controller, attempt, SERIAL_FAILED); return end
    local unavailable = false
    local ok, sent = pcall(function()
        local pooled = util.NetworkStringToID(REQUEST)
        if type(pooled) ~= "number" or pooled <= 0 then unavailable = true; return false end
        if not pending(controller, attempt) then return false end
        net.Start(REQUEST)
        if not pending(controller, attempt) then return false end
        net.WriteUInt(attempt.operation, 8)
        if not pending(controller, attempt) then return false end
        net.WriteString(attempt.request)
        if not pending(controller, attempt) then return false end
        net.WriteString(attempt.award or "")
        if not pending(controller, attempt) then return false end
        net.SendToServer()
        return true
    end)
    if not ok or not sent then
        fail(controller, attempt, unavailable and UNAVAILABLE or SEND_FAILED)
        return
    end
    -- A synchronous reply/replacement may already have consumed this attempt.
    if not pending(controller, attempt) then return end
    local scheduled = pcall(function()
        timer.Simple(5, function()
            fail(controller, attempt, "No reply received. Refresh/select again.")
        end)
    end)
    if not scheduled then fail(controller, attempt, SEND_FAILED) end
end

local function attemptFor(controller, operation, award)
    if not live(controller) then return nil end
    -- Invalidate the prior attempt even when the serial holder fails closed.
    controller.pending, controller.identity = nil, nil
    local token = nextToken()
    local attempt = {controller = controller, frame = controller.frame, operation = operation,
        request = token, award = award, listToken = controller.listToken}
    controller.pending, controller.identity = attempt, attempt
    return attempt
end

local function refresh(controller)
    if not live(controller) then return end
    local attempt = attemptFor(controller, 1)
    if not attempt then return end
    controller.entries, controller.listToken, controller.selected, controller.displayed = {}, nil, nil, nil
    controller.rendering = attempt
    local ok = pcall(function()
        if not change(controller, attempt, function() controller.selector:Clear() end) then return end
        if not change(controller, attempt, function() controller.selector:SetValue("Select a saved clue") end) then return end
        if not change(controller, attempt, function() controller.metadata:SetText("") end) then return end
        if not change(controller, attempt, function() controller.body:SetText("") end) then return end
        if not change(controller, attempt, function() controller.footer:SetText(footer(0)) end) then return end
        change(controller, attempt, function() controller.status:SetText("Loading saved intel...") end)
    end)
    if controller.rendering == attempt then controller.rendering = nil end
    if not ok then fail(controller, attempt, DISPLAY_FAILED); return end
    send(controller, attempt)
end

local function selectAward(controller, award)
    if not live(controller) or controller.rendering or type(award) ~= "string" then return end
    local entry = controller.entries and controller.entries[award]
    if not entry or not controller.listToken then return end
    local current = controller.pending
    if current and current.operation == 2 and current.award == award
        and current.listToken == controller.listToken then return end
    if controller.selected == award and controller.displayed == award then return end
    local attempt = attemptFor(controller, 2, award)
    if not attempt then return end
    controller.selected, controller.displayed = award, nil
    local ok = pcall(function()
        -- Clear first: a new heading must never accompany the previous body.
        if not change(controller, attempt, function() controller.body:SetText("") end) then return end
        if not change(controller, attempt, function() controller.metadata:SetText(metadata(entry)) end) then return end
        change(controller, attempt, function() controller.status:SetText("Loading clue...") end)
    end)
    if not ok then fail(controller, attempt, DISPLAY_FAILED); return end
    send(controller, attempt)
end

local function entryFrom(cursor)
    local entry = {award = cursor:string(16), consoleName = cursor:string(128),
        fileName = cursor:string(128), folder = cursor:byte()}
    if not validSlicerIntelAward(entry.award) or type(entry.consoleName) ~= "string"
        or type(entry.fileName) ~= "string" or slicerIntelArchiveName(entry.consoleName) ~= entry.consoleName
        or slicerIntelArchiveName(entry.fileName) ~= entry.fileName
        or (entry.folder ~= 0 and entry.folder ~= 1) then return nil end
    return entry
end

local function decode(bitLength)
    local cursor = slicerIntelArchiveReadPacket(bitLength, 4392)
    if not cursor then return nil end
    local operation, request, status = cursor:byte(), cursor:string(16), cursor:byte()
    if (operation ~= 1 and operation ~= 2) or not validSlicerIntelAward(request) then return nil end
    local invalid = {operation = operation, request = request}
    if status ~= 0 and status ~= 1 and status ~= 2 then return nil, invalid end
    if (operation == 1 and bitLength > 2780 * 8) or (status ~= 0 and bitLength > 19 * 8) then return nil, invalid end
    local result = {operation = operation, request = request, status = status}
    if status == 0 and operation == 1 then
        local count = cursor:byte()
        if not count or count > 10 then return nil, invalid end
        result.entries, result.byAward = {}, {}
        for i = 1, count do
            local entry = entryFrom(cursor)
            if not entry or result.byAward[entry.award] then return nil, invalid end
            result.entries[i], result.byAward[entry.award] = entry, entry
        end
    elseif status == 0 then
        result.entry = entryFrom(cursor)
        result.body = cursor:string(4096)
        local canonical = normalizeSlicerIntel(result.body)
        if not result.entry or not canonical or canonical == "" or canonical ~= result.body then return nil, invalid end
    end
    if not cursor:done() then return nil, invalid end
    return result
end

local function receive(bitLength)
    local controller = module.active
    local attempt = controller and controller.pending
    if not attempt then return end
    local ok, result, invalid = pcall(decode, bitLength)
    if not ok or not pending(controller, attempt) then return end
    local prefix = result or invalid
    if not prefix or prefix.operation ~= attempt.operation or prefix.request ~= attempt.request then return end
    if not result then fail(controller, attempt, DISPLAY_FAILED); return end
    if result.status ~= 0 then
        local message = result.status == 2 and "Wait a moment, then refresh/select again."
            or (attempt.operation == 2 and "That clue is no longer saved. Refresh the list." or UNAVAILABLE)
        fail(controller, attempt, message)
        return
    end
    if attempt.operation == 2 then
        local entry = controller.entries and controller.entries[attempt.award]
        local received = result.entry
        if controller.selected ~= attempt.award or controller.listToken ~= attempt.listToken
            or not entry or received.award ~= attempt.award or received.consoleName ~= entry.consoleName
            or received.fileName ~= entry.fileName or received.folder ~= entry.folder then
            fail(controller, attempt, DISPLAY_FAILED)
            return
        end
    end
    controller.rendering = attempt
    local rendered = pcall(function()
        if attempt.operation == 1 then
            if not change(controller, attempt, function() controller.selector:Clear() end) then return end
            if not change(controller, attempt, function() controller.selector:SetSortItems(false) end) then return end
            for _, entry in ipairs(result.entries) do
                if not change(controller, attempt, function() controller.selector:AddChoice(metadata(entry), entry.award) end) then return end
            end
            if not change(controller, attempt, function() controller.footer:SetText(footer(#result.entries)) end) then return end
            if not change(controller, attempt, function() controller.status:SetText("Select a saved clue to read it.") end) then return end
            controller.entries, controller.listToken = result.byAward, attempt.request
        else
            if not change(controller, attempt, function() controller.body:SetText(result.body) end) then return end
            if not change(controller, attempt, function() controller.status:SetText("Saved clue loaded.") end) then return end
            controller.displayed = attempt.award
        end
        if pending(controller, attempt) then controller.pending = nil end
    end)
    if controller.rendering == attempt then controller.rendering = nil end
    if not rendered then fail(controller, attempt, DISPLAY_FAILED) end
end
net.Receive(REPLY, receive)

local function reflow(controller, screenWidth, screenHeight)
    if not live(controller) or not supportedSize(screenWidth, screenHeight) then return end
    local width, height = math.min(720, screenWidth - 40), math.min(600, screenHeight - 40)
    local frame = controller.frame
    local function rect(panel, x, y, w, h)
        if not live(controller) or controller.frame ~= frame then return false end
        panel:SetPos(x, y)
        if not live(controller) or controller.frame ~= frame then return false end
        panel:SetSize(w, h)
        return live(controller) and controller.frame == frame
    end
    if not rect(frame, (screenWidth - width) / 2, (screenHeight - height) / 2, width, height) then return end
    if not rect(controller.selector, 16, 32, width - 128, 28) then return end
    if not rect(controller.refresh, width - 96, 32, 80, 28) then return end
    if not rect(controller.metadata, 16, 72, width - 32, 64) then return end
    if not rect(controller.body, 16, 144, width - 32, height - 272) then return end
    if not rect(controller.status, 16, height - 120, width - 32, 32) then return end
    rect(controller.footer, 16, height - 80, width - 32, 64)
end

function slicerOpenIntelArchive()
    if slicerIntelArchiveController ~= module or module.replaced or module.retiring then return end
    local current = module.active
    if current and live(current) then
        local ok = pcall(function()
            if not live(current) then return end
            current.frame:MakePopup()
            if live(current) then current.frame:MoveToFront() end
        end)
        if not ok and live(current) then notify(DISPLAY_FAILED) end
        return
    end
    -- A validity getter may have opened a replacement while checking current.
    if slicerIntelArchiveController ~= module or module.active ~= current then return end
    module.retire()
    if slicerIntelArchiveController ~= module or module.replaced or module.active ~= nil then return end
    local controller = {entries = {}}
    module.active = controller
    local ok = pcall(function()
        local frame = vgui.Create("DFrame")
        if slicerIntelArchiveController ~= module or module.active ~= controller or controller.retired then
            if IsValid(frame) then frame:Remove() end
            return
        end
        controller.frame = frame
        frame:SetTitle("Saved mission intel")
        frame:SetDeleteOnClose(true)
        frame:SetDraggable(true)
        frame:ShowCloseButton(true)
        local nativeClose, nativeRemove = frame.Close, frame.Remove
        function frame:Close() retire(controller); return nativeClose(self) end
        function frame:Remove() retire(controller); return nativeRemove(self) end
        frame.OnClose = function() retire(controller) end
        frame.OnRemove = frame.OnClose

        controller.selector = vgui.Create("DComboBox", frame)
        controller.selector:SetSortItems(false)
        controller.selector.OnSelect = function(_, _, _, award) selectAward(controller, award) end
        controller.refresh = vgui.Create("DButton", frame)
        controller.refresh:SetText("Refresh")
        controller.refresh.DoClick = function() refresh(controller) end
        controller.metadata = vgui.Create("DTextEntry", frame)
        controller.metadata:SetMultiline(true)
        controller.metadata:SetEditable(false)
        controller.metadata:SetText("")
        controller.body = vgui.Create("DTextEntry", frame)
        controller.body:SetMultiline(true)
        controller.body:SetEditable(false)
        controller.body:SetText("")
        controller.status = vgui.Create("DLabel", frame)
        controller.status:SetWrap(true)
        controller.footer = vgui.Create("DLabel", frame)
        controller.footer:SetWrap(true)
        controller.footer:SetText(footer(0))
        local width, height = ScrW(), ScrH()
        if not supportedSize(width, height) then width, height = 640, 480 end
        reflow(controller, width, height)
        if not live(controller) then return end
        frame:MakePopup()
        if live(controller) then refresh(controller) end
    end)
    if not ok then
        if module.active == controller then module.retire(); notify(DISPLAY_FAILED) end
    end
end

hook.Add("OnScreenSizeChanged", "slicerIntelArchive", function()
    local controller = module.active
    if not controller then return end
    local ok = pcall(reflow, controller, ScrW(), ScrH())
    if not ok then
        local attempt = controller.pending
        if attempt then fail(controller, attempt, DISPLAY_FAILED)
        elseif live(controller) then notify(DISPLAY_FAILED) end
    end
end)
for _, event in ipairs({"ShutDown", "InitPostEntity"}) do
    hook.Add(event, "slicerIntelArchive", function()
        if slicerIntelArchiveController == module then module.retire() end
    end)
end

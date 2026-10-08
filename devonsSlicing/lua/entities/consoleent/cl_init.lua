include("entities/consoleent/shared.lua")

local COMMAND_PROMPT = "Run commands here... (/help | Up/Down history)"
local commandHelpFrame, commandHelpOwner
local activeTerminalSession
-- Reincludes retain live initial drafts and requests; retired forms leave no cache.
slicerInitialSetupState = slicerInitialSetupState or {forms = {}, requests = {}}
slicerInitialSetupSerial = slicerInitialSetupSerial or 0
local setupForms, setupRequests = slicerInitialSetupState.forms, slicerInitialSetupState.requests
local closeConsoleUI

local function closeCommandHelp()
    if IsValid(commandHelpFrame) and not commandHelpFrame:IsMarkedForDeletion() then commandHelpFrame:Remove() end
    commandHelpFrame, commandHelpOwner = nil, nil
end

local function terminalCommands(info, stage)
    local commands = {}
    local function add(command, description)
        commands[#commands + 1] = {command, description}
    end
    if stage == "login" then
        add("/a[" .. info.name .. "]", "Log in to this terminal")
        add("/q[" .. info.name .. "]", "Quit this terminal")
    elseif stage == "folders" then
        for _, folder in ipairs({"data", "server", "tools"}) do
            add("/a[" .. info.name .. "]/{_" .. folder .. "}", "Open the " .. folder .. " folder")
        end
        add("/q[" .. info.name .. "]", "Quit this terminal")
    else
        add("//[" .. info.name .. "]/{_" .. stage .. "}", "Return to folder selection")
        if info.fileType == stage then
            local extensions = {data = "data", server = "sys", tools = "exe"}
            local prefix = stage == "tools" and "/r" or "/d"
            add(prefix .. "{_" .. stage .. "}/" .. info.fileName .. "." .. extensions[stage],
                stage == "tools" and "Run the door tool" or "Download the target file")
        end
    end
    add("/help", "Show these commands. Up/Down recalls this terminal's last 20 submissions.")
    return commands
end

local function isLiveCommandPanel(panel)
    return IsValid(panel) and not panel:IsMarkedForDeletion() and panel:IsVisible()
end

-- The server authenticates the sender, not the legacy payload entities. Only
-- callbacks belonging to this live local session/page may send its quit packet.
local function quitTerminal(session, page)
    if activeTerminalSession ~= session or not isLiveCommandPanel(page) then return end
    closeConsoleUI()
    net.Start("playerQuitConsole")
        net.WriteEntity(session.player)
        net.WriteEntity(session.console)
    net.SendToServer()
end

local function supportedPlayerSize(width, height)
    return type(width) == "number" and type(height) == "number"
        and width == width and height == height and width < math.huge and height < math.huge
        and width >= 640 and height >= 480
end

-- One mutable geometry budget shared by every player page. Keep content
-- between the heading/objective and the persistent command/action footer.
local function playerLayout(width, height)
    if not supportedPlayerSize(width, height) then width, height = 640, 480 end
    local layout = {width = width, height = height, margin = 20, gap = 12}
    layout.headerHeight = math.min(100, math.max(64, math.floor(height * 0.12)))
    layout.objectiveY, layout.objectiveHeight = layout.headerHeight + 8, 40
    layout.inputY, layout.inputHeight = height - 68, 48
    layout.actionsY = layout.inputY - 42
    layout.contentY = layout.headerHeight + 60
    layout.contentHeight = layout.actionsY - 20 - layout.contentY
    layout.folderSize = math.min(512, math.floor((width - 64) / 3), layout.contentHeight - 32)
    layout.folderX = math.floor((width - layout.folderSize * 3 - layout.gap * 2) / 2)
    layout.folderY = layout.contentY + math.floor((layout.contentHeight - layout.folderSize - 32) / 2)
    layout.rowWidth = math.min(420, width - layout.margin * 2)
    layout.rowHeight = math.min(100, math.floor((layout.contentHeight - layout.gap * 2) / 3))
    layout.rowX = math.floor((width - layout.rowWidth) / 2)
    layout.rowY = layout.contentY + math.floor((layout.contentHeight - layout.rowHeight * 3 - layout.gap * 2) / 2)
    return layout
end

local function isPlayerLayoutPanel(panel)
    return IsValid(panel) and not panel:IsMarkedForDeletion()
end

local function setPlayerRect(panel, x, y, width, height)
    if not isPlayerLayoutPanel(panel) then return end
    panel:SetPos(x, y)
    panel:SetSize(width, height)
end

-- A stage replaces its previous record; repeated visits retain at most five.
-- Hidden folder pages still reflow, but retired sessions/marked panels never do.
local function registerPlayerPage(session, stage, frame, background)
    local record = {frame = frame, geometry = {}}
    session.pages[stage] = record
    record.reflow = function()
        if activeTerminalSession ~= session or session.pages[stage] ~= record then return end
        if not isPlayerLayoutPanel(frame) then
            session.pages[stage] = nil
            return
        end
        local layout = session.layout
        setPlayerRect(frame, 0, 0, layout.width, layout.height)
        setPlayerRect(background, 0, 0, layout.width, layout.height)
        if isPlayerLayoutPanel(record.animatedObjective) then record.animatedObjective:Stop() end
        for _, geometry in ipairs(record.geometry) do geometry() end
    end
    return record
end

local function trackPlayerGeometry(page, geometry)
    page.geometry[#page.geometry + 1] = geometry
    geometry()
end

local function layoutPlayerLabel(label, layout, text, objective, page)
    -- Bound long labels to their own band; keep their full value for help and
    -- command insertion. Native font wrapping/readability still needs a game check.
    label:SetFont(#text > 40 and "HackingFont" or (objective and "PlayerObjectiveFont" or "PlayerHeadingFont"))
    label:SetText(text)
    label:SetWrap(true)
    label:SetContentAlignment(5)
    trackPlayerGeometry(page, function()
        setPlayerRect(label, layout.margin, objective and layout.objectiveY or 0,
            layout.width - layout.margin * 2, objective and layout.objectiveHeight or layout.headerHeight)
    end)
end

local function layoutFolder(image, parent, layout, column, identity, page)
    local caption = vgui.Create("DLabel", parent)
    caption:SetFont("HackingFont")
    caption:SetText(identity)
    caption:SetTextColor(Color(220, 220, 220, 255))
    caption:SetContentAlignment(5)
    trackPlayerGeometry(page, function()
        local x = layout.folderX + (column - 1) * (layout.folderSize + layout.gap)
        setPlayerRect(image, x, layout.folderY, layout.folderSize, layout.folderSize)
        setPlayerRect(caption, x, layout.folderY + layout.folderSize + 8, layout.folderSize, 24)
    end)
end

local function layoutFileRow(row, layout, index, page)
    trackPlayerGeometry(page, function()
        setPlayerRect(row, layout.rowX, layout.rowY + (index - 1) * (layout.rowHeight + layout.gap),
            layout.rowWidth, layout.rowHeight)
    end)
end

local function layoutCommandHelp(help, layout)
    local width = math.min(760, layout.width - layout.margin * 2)
    local height = math.min(420, layout.contentHeight)
    setPlayerRect(help, math.floor((layout.width - width) / 2),
        layout.contentY + math.floor((layout.contentHeight - height) / 2), width, height)
    -- The same docked scroll panel follows its parent through native layout.
end

hook.Add("OnScreenSizeChanged", "SlicerPlayerTerminalReflow", function()
    local session = activeTerminalSession
    if not session then return end
    local width, height = ScrW(), ScrH() -- These already reflect the new size.
    local layout = session.layout
    if not supportedPlayerSize(width, height) or (width == layout.width and height == layout.height) then return end
    for key, value in pairs(playerLayout(width, height)) do layout[key] = value end
    for _, page in pairs(session.pages) do page.reflow() end
    if isPlayerLayoutPanel(commandHelpFrame) and isPlayerLayoutPanel(commandHelpOwner)
        and commandHelpOwner.IsCurrentTerminalPage() then
        layoutCommandHelp(commandHelpFrame, layout)
    end
end)

local function configureCommandAssistance(input, parent, info, stage, history, session)
    local layout = session.layout
    input.IsCurrentTerminalPage = function()
        return activeTerminalSession == session and isLiveCommandPanel(parent) and isLiveCommandPanel(input)
    end
    input.QuitTerminal = function()
        if input.IsCurrentTerminalPage() then quitTerminal(session, parent) end
    end
    input:SetHistoryEnabled(true)
    input.History = history
    input.HistoryPos = 0
    local commands = terminalCommands(info, stage)
    input.ShowCommandHelp = function()
        if not isLiveCommandPanel(input) or not isLiveCommandPanel(parent) then return end
        if isLiveCommandPanel(commandHelpFrame) and commandHelpOwner == input then
            commandHelpFrame:MakePopup()
            return
        end
        closeCommandHelp()
        commandHelpOwner = input
        commandHelpFrame = vgui.Create("DFrame", parent)
        layoutCommandHelp(commandHelpFrame, layout)
        commandHelpFrame:SetTitle("Commands - " .. info.name .. " / " .. stage)
        commandHelpFrame:SetDeleteOnClose(true)
        commandHelpFrame:ShowCloseButton(true)
        commandHelpFrame:MakePopup()
        local help = commandHelpFrame -- Callbacks belong to this exact opened help window.
        local function canInsertCommand()
            return commandHelpFrame == help and commandHelpOwner == input
                and isLiveCommandPanel(help) and isLiveCommandPanel(parent) and isLiveCommandPanel(input)
                and input:IsKeyboardInputEnabled()
                and not timer.Exists("AccessDelay") and not timer.Exists("DownloadDataFile")
                and not timer.Exists("DownloadServerFile")
        end
        local scroll = vgui.Create("DScrollPanel", help)
        scroll:Dock(FILL)
        local notice = scroll:Add("DLabel")
        notice:Dock(TOP)
        notice:DockMargin(12, 6, 12, 8)
        notice:SetFont("HackingFont")
        notice:SetTextColor(Color(220, 220, 220, 255))
        notice:SetWrap(true)
        notice:SetAutoStretchVertical(true)
        notice:SetText("Insert replaces the current draft. Press Enter to run.")
        for _, command in ipairs(commands) do
            local commandText = command[1]
            local label = scroll:Add("DLabel")
            label:Dock(TOP)
            label:DockMargin(12, 6, 12, 8)
            label:SetFont("HackingFont")
            label:SetTextColor(Color(220, 220, 220, 255))
            label:SetWrap(true)
            label:SetAutoStretchVertical(true)
            label:SetText(commandText .. "\n" .. command[2])
            local insert = scroll:Add("DButton")
            insert:Dock(TOP)
            insert:DockMargin(12, 0, 12, 8)
            insert:SetTall(26)
            insert:SetText("Insert command")
            insert.Think = function(self) self:SetEnabled(canInsertCommand()) end
            insert:Think()
            insert.DoClick = function()
                if not canInsertCommand() then return end
                closeCommandHelp()
                input.HistoryPos = 0
                input:SetText(commandText)
                input:SetCaretPos(utf8.len(commandText) or #commandText)
                input:RequestFocus()
            end
        end
    end
    local button = vgui.Create("DButton", parent)
    button:SetText("Commands (/help)")
    button.DoClick = input.ShowCommandHelp
    local quit = vgui.Create("DButton", parent)
    quit:SetText("Quit terminal")
    quit.DoClick = function()
        if isLiveCommandPanel(quit) then quitTerminal(session, parent) end
    end
    trackPlayerGeometry(session.pages[stage], function()
        setPlayerRect(input, layout.margin, layout.inputY, layout.width - layout.margin * 2, layout.inputHeight)
        setPlayerRect(button, layout.margin, layout.actionsY, 160, 30)
        setPlayerRect(quit, layout.margin + 172, layout.actionsY, 160, 30)
    end)
end

local function handleCommandAssistance(input)
    if not IsValid(input) or not input.IsCurrentTerminalPage() then return true end
    local value = input:GetValue()
    if string.Trim(value) ~= "" and #value <= 512 then
        input:AddHistory(value)
        while #input.History > 20 do table.remove(input.History, 1) end
    end
    if string.lower(string.Trim(value)) == "/help" then
        input.ShowCommandHelp()
        input:SetText("")
        input:SetPlaceholderText(COMMAND_PROMPT)
        input:SetPlaceholderColor(Color(140, 140, 140, 220))
        return true
    end
    closeCommandHelp()
    return false
end

-- A terminal has several independent frames, timers and Think hooks. Tear all
-- of them down together so death, quitting and completion cannot leave a timer
-- reopening a closed terminal or updating a removed panel.
closeConsoleUI = function()
    activeTerminalSession = nil -- Retire ownership before Remove hooks can reenter.
    closeCommandHelp()
    for _, panel in pairs({firstPage, secondPage, insideData, insideServer, insideTools}) do
        if IsValid(panel) then panel:Remove() end
    end
    firstPage, secondPage, insideData, insideServer, insideTools = nil, nil, nil, nil, nil
    for _, name in ipairs({
        "AccessDelay", "DownloadDataFile", "DownloadServerFile",
        "firstPageGlitch", "firstPageReturn", "secondPageGlitch", "secondPageReturn",
        "dataPageGlitch", "dataPageReturn",
    }) do
        timer.Remove(name)
    end
    for _, name in ipairs({"printDelay", "downloadDataFile", "downloadServerFile"}) do
        hook.Remove("Think", name)
    end
end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code draws the console entities model for the client
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

-- Draws the entity model
function ENT:Draw()

    self:DrawModel()

    local ang = self:GetAngles()

    ang:RotateAroundAxis(self:GetAngles():Up(), 90)
    ang:RotateAroundAxis(self:GetAngles():Right(), -90)

    cam.Start3D2D(self:GetPos(), ang, 0.1)

        draw.SimpleText("<CONSOLE>", "ConsoleFont", -480, -850, Color(255, 0, 0, 255))

    cam.End3D2D()

end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code sets up our custom font
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

surface.CreateFont("HackingFont", {
    font = "Data Control",
    size = 15,
})

surface.CreateFont("FolderFont", {
    font = "Data Control",
    size = 60

})

surface.CreateFont("PlayerHeadingFont", {
    font = "Data Control",
    size = 32,
})

surface.CreateFont("PlayerObjectiveFont", {
    font = "Data Control",
    size = 20,
})

surface.CreateFont("ConsoleFont", {
    font = "Data Control",
    size = 500

})


--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code sets up the editable fields for the GM/Admin who spawned the entity
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

-- START OF ADMIN UI
local function setCreatorRect(panel, x, y, width, height)
    if not isLiveCommandPanel(panel) then return end
    panel:SetPos(x, y)
    panel:SetSize(width, height)
end

-- Each current visible form owns its geometry and last supported screen budget.
-- Reflow changes rectangles only; drafts, pending replies and focus stay intact.
local function registerCreatorGeometry(form, geometry)
    function form.reflow(width, height)
        if not form.isCurrent() or not supportedPlayerSize(width, height)
            or (form.width == width and form.height == height) then return end
        geometry(width, height)
        form.width, form.height = width, height
    end
    local width, height = ScrW(), ScrH()
    if not supportedPlayerSize(width, height) then width, height = 640, 480 end
    form.reflow(width, height)
end

local function nextInitialSetupToken()
    if type(slicerInitialSetupSerial) ~= "number" or slicerInitialSetupSerial < 0
        or slicerInitialSetupSerial % 1 ~= 0 or slicerInitialSetupSerial >= 9007199254740991 then return end
    slicerInitialSetupSerial = slicerInitialSetupSerial + 1
    return string.format("%.0f", slicerInitialSetupSerial)
end

net.Receive("PlayerSpawnedConsole", function()
    local callingPlayer = net.ReadEntity()
    local sentConsoleName = net.ReadString()
    if not IsValid(callingPlayer) or not callingPlayer:IsPlayer() or not callingPlayer:Alive()
        or type(sentConsoleName) ~= "string" then return end

    local previous = setupForms[sentConsoleName]
    if previous and previous.isCurrent() then
        previous.frame:MakePopup()
        previous.frame:MoveToFront()
        return -- Repeated Use retains both focused drafts and pending submissions.
    end
    if previous then previous.close() end

    local initialParent = vgui.Create("DFrame")
    local setup = {frame = initialParent, retired = false}
    setupForms[sentConsoleName] = setup
    function setup.isCurrent()
        return not setup.retired and setupForms[sentConsoleName] == setup and isLiveCommandPanel(initialParent)
    end
    local function retireSetup()
        if setup.retired then return end
        setup.retired = true -- Retire ownership before native cleanup can reenter.
        if setupForms[sentConsoleName] == setup then setupForms[sentConsoleName] = nil end
        local submission = setup.pending
        if submission and setupRequests[submission.token] == submission then setupRequests[submission.token] = nil end
        setup.pending = nil
    end
    -- Close and Remove can defer OnRemove. Retire synchronously at both native
    -- entry points so retained callbacks cannot acknowledge or submit meanwhile.
    local nativeClose, nativeRemove = initialParent.Close, initialParent.Remove
    function initialParent:Close()
        retireSetup()
        return nativeClose(self)
    end
    function initialParent:Remove()
        retireSetup()
        return nativeRemove(self)
    end
    initialParent.OnClose, initialParent.OnRemove = retireSetup, retireSetup
    function setup.close()
        retireSetup()
        if IsValid(initialParent) and not initialParent:IsMarkedForDeletion() then initialParent:Close() end
    end
    initialParent:ShowCloseButton(false)
    initialParent:MakePopup()
    initialParent:SetTitle("")
    initialParent:SetDeleteOnClose(true)
    initialParent:SetDraggable(false)
    function initialParent.Paint(self, w, h)
        draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
    end

    local fileType = vgui.Create("DComboBox", initialParent)
    fileType:AddChoice("data", nil, false, nil)
    fileType:AddChoice("server", nil, false, nil)
    fileType:AddChoice("tools", nil, false, nil)

    local consoleNameFrame = vgui.Create("DTextEntry", initialParent)
    consoleNameFrame:AllowInput(true)
    consoleNameFrame:SetPlaceholderText("Enter Console Name Here")
    consoleNameFrame:SetPlaceholderColor(Color(150, 150, 150, 200))
    consoleNameFrame:SetTextColor(Color(0, 0, 0, 255))

    local slicerTime = vgui.Create("DTextEntry", initialParent)
    slicerTime:AllowInput(true)
    slicerTime:SetPlaceholderText("Enter Slice Time here (Seconds)")
    slicerTime:SetPlaceholderColor(Color(150, 150, 150, 200))
    slicerTime:SetTextColor(Color(0, 0, 0, 255))

    local fileName = vgui.Create("DTextEntry", initialParent)
    fileName:AllowInput(true)
    fileName:SetPlaceholderText("Enter File Name here (No extension)")
    fileName:SetPlaceholderColor(Color(150, 150, 150, 200))
    fileName:SetTextColor(Color(0, 0, 0, 255))

    local finishButton = vgui.Create("DButton", initialParent)
    finishButton:SetText("Done")
    local laterButton = vgui.Create("DButton", initialParent)
    laterButton:SetText("Set up later")
    local status = vgui.Create("DLabel", initialParent)
    status:SetFont("HackingFont")
    status:SetWrap(true)
    local function showStatus(message, failed)
        status:SetText(message)
        status:SetTextColor(failed and Color(255, 150, 150, 255) or Color(220, 220, 220, 255))
    end
    local function lockInputs(pending)
        finishButton:SetEnabled(not pending)
        fileType:SetEnabled(not pending)
        laterButton:SetText(pending and "Close" or "Set up later")
        for _, input in ipairs({consoleNameFrame, slicerTime, fileName}) do input:SetEditable(not pending) end
    end
    showStatus("Enter the console settings, then choose Done.", false)
    lockInputs(false)

    function finishButton.DoClick()
        if not setup.isCurrent() or setup.pending or not IsValid(callingPlayer)
            or not callingPlayer:IsPlayer() or not callingPlayer:Alive() then return end
        -- Read current focused controls rather than stale focus-loss callbacks.
        local enteredConsoleName = consoleNameFrame:GetValue()
        local enteredSliceDelay = tonumber(slicerTime:GetValue())
        local enteredFileType = fileType:GetSelected()
        local enteredFileName = fileName:GetValue()
        if #enteredConsoleName > 128 or string.Trim(enteredConsoleName) == ""
            or #enteredFileName > 128 or string.Trim(enteredFileName) == ""
            or enteredSliceDelay == nil or enteredSliceDelay != enteredSliceDelay
            or enteredSliceDelay <= 0 or enteredSliceDelay == math.huge
            or (enteredFileType != "data" and enteredFileType != "server" and enteredFileType != "tools") then
            callingPlayer:ChatPrint("One or more fields is invalid")
            showStatus("Invalid fields: choose a folder, nonblank names of at most 128 bytes, and a finite positive delay.", true)
            return
        end
        local token = nextInitialSetupToken()
        if not token then
            showStatus("Setup submission is unavailable in this client session. Close this form and reconnect before trying again.", true)
            return
        end
        local submission = {token = token}
        setup.pending, setupRequests[token] = submission, submission
        function submission.reply(result)
            if not setup.isCurrent() or setup.pending ~= submission or setupRequests[token] ~= submission
                or type(result) ~= "table" then return end
            if result.ok == true then
                if type(result.name) ~= "string" or #result.name > 128 or string.Trim(result.name) == ""
                    or result.fileType ~= enteredFileType then return end
                retireSetup()
                initialParent:Close()
                if result.fileType == "tools" and IsValid(callingPlayer) and callingPlayer:IsPlayer() then
                    -- Keep accepted settings unchanged; clean controls only for display.
                    -- Two messages preserve the full name within ChatPrint's 255-byte limit.
                    local displayName = result.name:gsub("[%z\1-\31\127]", " ")
                    callingPlayer:ChatPrint('Setup accepted for console "' .. displayName .. '". Look at that console and type !setEntity first.')
                    callingPlayer:ChatPrint("Then look at its intended door and type !setEntity to link it.")
                end
            elseif result.ok == false then
                if type(result.message) ~= "string" or #result.message == 0 or #result.message > 256 then return end
                setupRequests[token], setup.pending = nil, nil
                lockInputs(false)
                showStatus(result.message, true)
            end
        end
        -- Register and lock before sending: a reentrant click or immediate reply
        -- must observe the exact current submission and its immutable draft.
        lockInputs(true)
        showStatus("Saving setup... Closing cannot undo an accepted setup.", false)
        net.Start("AdminFinishedCreation")
            net.WriteTable({enteredConsoleName, enteredSliceDelay, enteredFileType, enteredFileName, sentConsoleName, token})
        net.SendToServer()
    end
    function laterButton.DoClick()
        if setup.isCurrent() then setup.close() end -- Dismissal never cancels a server commit or another hack.
    end

    -- Keep the original centered six-row group for opening and live resizing.
    registerCreatorGeometry(setup, function(width, height)
        setCreatorRect(initialParent, 0, 0, width, height)
        local controlHeight, controlGap, statusHeight = 48, 12, 72
        local columnWidth = math.min(400, width - 40)
        local columnHeight = controlHeight * 6 + controlGap * 6 + statusHeight
        local columnX, columnY = (width - columnWidth) / 2, (height - columnHeight) / 2
        for index, control in ipairs({consoleNameFrame, slicerTime, fileType, fileName, laterButton, finishButton}) do
            setCreatorRect(control, columnX, columnY + (index - 1) * (controlHeight + controlGap),
                columnWidth, controlHeight)
        end
        setCreatorRect(status, columnX, columnY + (controlHeight + controlGap) * 6, columnWidth, statusHeight)
    end)
end)

net.Receive("SlicerInitialSetupReply", function()
    local token, result = net.ReadString(), net.ReadTable()
    if type(token) ~= "string" then return end
    local submission = setupRequests[token]
    if submission then submission.reply(result) end
end)

-- Configured-console edits are independent of initial setup and hacking sessions.
-- The server owns each ticket; the client only keeps its current visible form.
local setupEditForms, setupEditTokens = {}, {}

hook.Add("OnScreenSizeChanged", "SlicerCreatorFormReflow", function()
    local width, height = ScrW(), ScrH()
    if not supportedPlayerSize(width, height) then return end
    for _, form in pairs(setupForms) do
        if form.reflow then form.reflow(width, height) end
    end
    for _, form in pairs(setupEditForms) do form.reflow(width, height) end
end)

net.Receive("SlicerSetupEditOpen", function()
    local console = net.ReadEntity()
    local callingPlayer = net.ReadEntity()
    local token = net.ReadString()
    local information = net.ReadTable()
    if not IsValid(console) or not IsValid(callingPlayer) or not callingPlayer:IsPlayer()
        or not callingPlayer:Alive() or token == "" then return end

    local previous = setupEditForms[console]
    if previous and previous.token == token and previous.isCurrent() then
        previous.frame:MakePopup()
        previous.frame:MoveToFront()
        return -- Preserve focused drafts and pending submissions on repeated opens.
    end
    if previous then previous.close() end
    if type(information) ~= "table" or type(information.name) ~= "string"
        or type(information.fileName) ~= "string" or type(information.delay) ~= "number"
        or (information.fileType ~= "data" and information.fileType ~= "server" and information.fileType ~= "tools") then return end

    local frame = vgui.Create("DFrame")
    local edit = {frame = frame, token = token, pending = false, retired = false}
    setupEditForms[console], setupEditTokens[token] = edit, edit
    function edit.isCurrent()
        return not edit.retired and setupEditForms[console] == edit
            and setupEditTokens[token] == edit and isLiveCommandPanel(frame)
    end
    local function retire(cancel)
        if edit.retired then return end
        edit.retired = true -- Retire before any native cleanup or network send.
        if setupEditForms[console] == edit then setupEditForms[console] = nil end
        if setupEditTokens[token] == edit then setupEditTokens[token] = nil end
        if cancel then
            net.Start("SlicerSetupEditCancel")
                net.WriteEntity(console)
                net.WriteString(token)
            net.SendToServer()
        end
    end
    -- Native removal is deferred. Wrap both entry points so stale callbacks
    -- cannot submit or acknowledge during the interval before OnRemove runs.
    local nativeClose, nativeRemove = frame.Close, frame.Remove
    function frame:Close()
        retire(true)
        return nativeClose(self)
    end
    function frame:Remove()
        retire(true)
        return nativeRemove(self)
    end
    frame.OnClose = function() retire(true) end
    frame.OnRemove = function() retire(true) end
    function edit.close()
        retire(true)
        if IsValid(frame) and not frame:IsMarkedForDeletion() then frame:Close() end
    end

    local width, height = 460, 430
    frame:SetTitle("Edit console settings")
    frame:SetDeleteOnClose(true)
    frame:SetDraggable(false)
    frame:ShowCloseButton(true)
    frame:MakePopup()

    local function label(text, y, labelHeight)
        local panel = vgui.Create("DLabel", frame)
        panel:SetFont("HackingFont")
        panel:SetTextColor(Color(220, 220, 220, 255))
        panel:SetText(text)
        panel:SetWrap(true)
        panel:SetPos(20, y)
        panel:SetSize(width - 40, labelHeight or 20)
        return panel
    end
    local function entry(title, value, y)
        label(title, y)
        local panel = vgui.Create("DTextEntry", frame)
        panel:SetText(tostring(value))
        panel:SetPos(20, y + 22)
        panel:SetSize(width - 40, 36)
        return panel
    end
    local name = entry("Console name", information.name, 40)
    -- Lua 5.1's tostring can round a stored double. Keep simple values short,
    -- but preserve the exact delay when another field alone is being edited.
    local delayText = tostring(information.delay)
    if tonumber(delayText) ~= information.delay then delayText = string.format("%.17g", information.delay) end
    local delay = entry("Slice delay (seconds)", delayText, 110)
    local fileName = entry("Filename (no extension)", information.fileName, 180)
    label("Folder: " .. information.fileType .. " (fixed)", 250, 24)
    local status = label("Change the fields above, then save.", 286, 60)
    local save = vgui.Create("DButton", frame)
    save:SetText("Save changes")
    save:SetPos(20, 366)
    save:SetSize((width - 52) / 2, 44)
    local cancel = vgui.Create("DButton", frame)
    cancel:SetText("Cancel")
    cancel:SetPos(32 + (width - 52) / 2, 366)
    cancel:SetSize((width - 52) / 2, 44)

    local function setPending(pending)
        edit.pending = pending
        save:SetEnabled(not pending)
        cancel:SetText(pending and "Close" or "Cancel")
        -- Acknowledgement cannot discard edits typed after the submitted draft.
        for _, input in ipairs({name, delay, fileName}) do input:SetEditable(not pending) end
    end
    local function showStatus(message, failed)
        status:SetText(message)
        status:SetTextColor(failed and Color(255, 150, 150, 255) or Color(220, 220, 220, 255))
    end
    save.DoClick = function()
        if not edit.isCurrent() or edit.pending then return end
        if not IsValid(console) or not IsValid(callingPlayer) or not callingPlayer:IsPlayer()
            or not callingPlayer:Alive() then
            showStatus("This edit is no longer current. Close this form and use !editConsole to reopen it.", true)
            return
        end
        local enteredName, enteredFile = name:GetValue(), fileName:GetValue()
        local enteredDelay = tonumber(delay:GetValue())
        if #enteredName > 128 or string.Trim(enteredName) == ""
            or #enteredFile > 128 or string.Trim(enteredFile) == ""
            or enteredDelay == nil or enteredDelay ~= enteredDelay
            or enteredDelay <= 0 or enteredDelay == math.huge then
            showStatus("Invalid fields: names must be nonblank and at most 128 bytes; delay must be a finite number greater than 0.", true)
            return
        end
        setPending(true)
        showStatus("Saving changes... Closing cannot undo a submitted save.", false)
        net.Start("SlicerSetupEditSave")
            net.WriteEntity(console)
            net.WriteString(token)
            net.WriteTable({name = enteredName, delay = enteredDelay, fileName = enteredFile})
        net.SendToServer()
    end
    cancel.DoClick = function()
        if edit.isCurrent() then edit.close() end
    end
    function edit.reply(result)
        if not edit.isCurrent() or type(result) ~= "table" then return end
        if result.ok == true then
            if not edit.pending then return end
            retire(false) -- The acknowledged ticket was consumed, not cancelled.
            frame:Close()
        elseif result.ok == false then
            setPending(false)
            local message = type(result.message) == "string" and result.message ~= "" and result.message
                or "Changes were not saved. Close this form and use !editConsole to reopen it."
            showStatus(message, true)
        end
    end
    registerCreatorGeometry(edit, function(screenWidth, screenHeight)
        setCreatorRect(frame, (screenWidth - width) / 2, (screenHeight - height) / 2, width, height)
    end)
end)

net.Receive("SlicerSetupEditReply", function()
    local token = net.ReadString()
    local result = net.ReadTable()
    local edit = setupEditTokens[token]
    if edit then edit.reply(result) end -- No entity is needed after console removal.
end)

-- END OF ADMIN UI


--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code creates the UI for the hacking console. It accesses the information send to the server through a net.receive function
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

-- START OF HACKING UI

net.Receive("ServerSendsEntityInformation", function() -- Frames open

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code sets up the local variables and assigns them to the values sent by the server
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    
    local usedConsole = net.ReadEntity()
    local callingPlayer = net.ReadEntity()

    local consoleInfo = net.ReadTable()
    local commandHistory = {} -- Shared across this terminal only, never a later session.
    --[[
    Output of this table is
    name
    delay
    fileType
    fileName
    inUse
    --]]

    local consoleName = net.ReadString()

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code checks to see if the client has the hacking tool, and if so begins to draw the hacking UI
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    local upperBound = 7
    local lowerBound = 3
if(!consoleInfo["inUse"]) then
    closeConsoleUI()
    local layout = playerLayout(ScrW(), ScrH())
    local terminalSession = {player = callingPlayer, console = usedConsole, layout = layout, pages = {}}
    activeTerminalSession = terminalSession

    surface.PlaySound("code_welcome.wav")

    net.Start("updateInUse")
        net.WriteString(consoleName)
    net.SendToServer()

    -- Creates the parent frame that we can close
   firstPage = vgui.Create("DFrame")
   firstPage:SetPos(0, 0)
   firstPage:SetSize(layout.width, layout.height)
   firstPage:MakePopup()
   firstPage:SetDraggable(false)
   firstPage:SetTitle("")
   firstPage:ShowCloseButton(false)
   function firstPage.Paint(self, w, h)
       draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
   end


   -- Set the background image for the hacking UI
   local backgroundImage = vgui.Create("DImage", firstPage)
   backgroundImage:SetSize(layout.width, layout.height)
   backgroundImage:SetPos(0, 0)
   backgroundImage:SetImage("vgui/consoleframe1.png")
   local loginPage = registerPlayerPage(terminalSession, "login", firstPage, backgroundImage)
   -- Creates the glitch effect for the console background
   timer.Create("firstPageGlitch", math.random(lowerBound, upperBound), 0, function()
       backgroundImage:SetImage("vgui/consoleframe2.png")
       timer.Create("firstPageReturn", 0.5, 1, function()
           backgroundImage:SetImage("vgui/consoleframe1.png")
       end)
   end)

   local findFileLabel1 = vgui.Create("DLabel", firstPage)
   layoutPlayerLabel(findFileLabel1, layout, "Locate file '" .. consoleInfo["fileName"] .. "'", true, loginPage)
   findFileLabel1:SetTextColor(Color(255, 0, 0, 255))
   findFileLabel1:SetPos(-layout.width, layout.objectiveY)
   
   findFileLabel1:MoveTo(layout.margin, layout.objectiveY, 1, 0.2, 1)
   loginPage.animatedObjective = findFileLabel1


   -- Prints the console identifier to the top
   local consoleNameLabel = vgui.Create("DLabel", firstPage)
   layoutPlayerLabel(consoleNameLabel, layout, consoleInfo["name"], false, loginPage)

   -- Paints the banner
   function consoleNameLabel.Paint(self, w, h)
       draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
   end


   -- Creates the username and password "inputs"
   local userBox = vgui.Create("DTextEntry", firstPage)
   userBox:SetFont("HackingFont")
   userBox:SetPlaceholderText("User ID")
   userBox:SetPlaceholderColor(Color(140, 140, 140, 220))
   userBox:SetEditable(false) -- Stops the player being able to interact with the console

   local passBox = vgui.Create("DTextEntry", firstPage)
   passBox:SetFont("HackingFont")
   passBox:SetPlaceholderText("Password ID")
   passBox:SetPlaceholderColor(Color(140, 140, 140, 220))
   passBox:SetEditable(false) -- Stops the player being able to interact with the console
   trackPlayerGeometry(loginPage, function()
       local x, y = (layout.width - 100) / 2, layout.contentY + (layout.contentHeight - 50) / 2
       setPlayerRect(userBox, x, y, 100, 25)
       setPlayerRect(passBox, x, y + 25, 100, 25)
   end)

   -- Creates the access terminal
   local inputTerminal1 = vgui.Create("DTextEntry", firstPage)
   inputTerminal1:SetFont("HackingFont")
   inputTerminal1:SetPlaceholderText(COMMAND_PROMPT)
   inputTerminal1:SetPlaceholderColor(Color(140, 140, 140, 220))
   inputTerminal1:SetTextColor(Color(36, 209, 36, 255))
   inputTerminal1:SetPaintBackground(false)
   inputTerminal1:SetCursorColor(Color(36, 209, 36, 255))
   configureCommandAssistance(inputTerminal1, firstPage, consoleInfo, "login", commandHistory, terminalSession)

   inputTerminal1.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
       self:SetPlaceholderText("")
   end
   
   function inputTerminal1:OnEnter()
       if handleCommandAssistance(inputTerminal1) then return end

    surface.PlaySound("code_enter.wav")

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code checks to see if the entered value is equal to the quit command, and then quits the console
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

       -- Quits the console
       if(string.lower(inputTerminal1:GetValue()) == "/q[" .. consoleInfo["name"] .. "]") then
           inputTerminal1.QuitTerminal()
           return
       end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code checks to see if the entered value is equal to the access command, and then runs the countdown timer and loads the next page
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

       if(string.lower(inputTerminal1:GetValue()) == "/a[" .. consoleInfo["name"] .. "]") then
           timer.Create("AccessDelay", consoleInfo["delay"], 1, function()
               timer.Remove("AccessDelay")
               
--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code sets up the second page of the console
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

               firstPage:Remove() -- Removes the login terminal
               timer.Remove("firstPageGlitch") -- Removes the glitch effect so errors are thrown
               timer.Remove("firstPageReturn") -- Removes the glitch effect so errors are thrown

                surface.PlaySound("code_accessgranted.wav")

               -- Creates the parent frame that we can close
               secondPage = vgui.Create("DFrame")
               secondPage:SetPos(0, 0)
               secondPage:SetSize(layout.width, layout.height)
               secondPage:MakePopup()
               secondPage:SetDraggable(false)
               secondPage:SetTitle("")
               secondPage:ShowCloseButton(false)
               function secondPage.Paint(self, w, h)
                   draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
               end


               -- Set the background image for the hacking UI
               local backgroundImage = vgui.Create("DImage", secondPage)
               backgroundImage:SetSize(layout.width, layout.height)
               backgroundImage:SetPos(0, 0)
               backgroundImage:SetImage("vgui/consoleframe1.png")
               local folderPage = registerPlayerPage(terminalSession, "folders", secondPage, backgroundImage)
               -- Creates the glitch effect for the console background
               timer.Create("secondPageGlitch", math.random(lowerBound, upperBound), 0, function()
                   backgroundImage:SetImage("vgui/consoleframe2.png")
                   timer.Create("secondPageReturn", 0.5, 1, function()
                       backgroundImage:SetImage("vgui/consoleframe1.png")
                   end)
               end)

               local findFileLabel2 = vgui.Create("DLabel", secondPage)
               layoutPlayerLabel(findFileLabel2, layout, "Locate file '" .. consoleInfo["fileName"] .. "'", true, folderPage)
               findFileLabel2:SetTextColor(Color(255, 0, 0, 255))


               -- Prints the console identifier to the top
               local consoleNameLabel = vgui.Create("DLabel", secondPage)
               layoutPlayerLabel(consoleNameLabel, layout, consoleInfo["name"], false, folderPage)

               -- Paints the banner
               function consoleNameLabel.Paint(self, w, h)
                   draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
               end


               -- Creates the images to display the different folders
               local dataFolderImage = vgui.Create("DImage", secondPage)
               layoutFolder(dataFolderImage, secondPage, layout, 2, "{_data}", folderPage)
               dataFolderImage:SetImage("vgui/folder1.png")

               local serverFolderImage = vgui.Create("DImage", secondPage)
               layoutFolder(serverFolderImage, secondPage, layout, 3, "{_server}", folderPage)
               serverFolderImage:SetImage("vgui/folder2.png")

               local toolsFolderImage = vgui.Create("DImage", secondPage)
               layoutFolder(toolsFolderImage, secondPage, layout, 1, "{_tools}", folderPage)
               toolsFolderImage:SetImage("vgui/folder3.png")

               -- Creates the access terminal
               local inputTerminal2 = vgui.Create("DTextEntry", secondPage)
               inputTerminal2:SetFont("HackingFont")
               inputTerminal2:SetPlaceholderText(COMMAND_PROMPT)
               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
               inputTerminal2:SetPaintBackground(false)
               inputTerminal2:SetCursorColor(Color(36, 209, 36, 255))
               configureCommandAssistance(inputTerminal2, secondPage, consoleInfo, "folders", commandHistory, terminalSession)

               inputTerminal2.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                   self:SetPlaceholderText("")
               end

               inputTerminal2.OnLoseFocus = function(self)
                   self:SetPlaceholderText(COMMAND_PROMPT)
                   self:SetPlaceholderColor(Color(140, 140, 140, 220))
               end
               
               function inputTerminal2:OnEnter()
                   if handleCommandAssistance(inputTerminal2) then return end

                surface.PlaySound("code_enter.wav")
--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code checks to see if the entered value is equal to the a function and then runs that function
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

local acceptedFolders = {
   "{_data}",
   "{_server}",
   "{_tools}",
}

local filenames = {
   "hitlist",
   "consoleLogs",
   "important",
}

local decoyFilenames = {}
for _, filename in ipairs(filenames) do
   if string.lower(filename) != string.lower(consoleInfo["fileName"]) then
       decoyFilenames[#decoyFilenames + 1] = filename
       if #decoyFilenames == 2 then break end
   end
end

                   if(string.lower(inputTerminal2:GetValue()) == "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1]) then

                       timer.Stop("secondPageGlitch") -- Removes the glitch effect so errors aren't thrown
                       timer.Stop("secondPageReturn") -- Removes the glitch effect so errors aren't thrown

                       -- Creates the parent frame that we can close
                       insideData = vgui.Create("DFrame")
                       insideData:SetPos(0, 0)
                       insideData:SetSize(layout.width, layout.height)
                       insideData:MakePopup()
                       insideData:SetDraggable(false)
                       insideData:SetTitle("")
                       insideData:ShowCloseButton(false)
                       function insideData.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
                       end


                       -- Set the background image for the hacking UI
                       local dataBackgroundImage = vgui.Create("DImage", insideData)
                       dataBackgroundImage:SetSize(layout.width, layout.height)
                       dataBackgroundImage:SetPos(0, 0)
                       dataBackgroundImage:SetImage("vgui/consoleframe1.png")
                       local dataPage = registerPlayerPage(terminalSession, "data", insideData, dataBackgroundImage)
                       -- Creates the glitch effect for the console background
                       timer.Create("dataPageGlitch", math.random(lowerBound, upperBound), 0, function()
                           dataBackgroundImage:SetImage("vgui/consoleframe2.png")
                           timer.Create("dataPageReturn", 0.5, 1, function()
                               dataBackgroundImage:SetImage("vgui/consoleframe1.png")
                           end)
                       end)

                       local findFileLabel3 = vgui.Create("DLabel", insideData)
                       layoutPlayerLabel(findFileLabel3, layout, "Locate file '" .. consoleInfo["fileName"] .. "'", true, dataPage)
                       findFileLabel3:SetTextColor(Color(255, 0, 0, 255))
                        

                       -- Prints the console identifier to the top
                       local dataNameLabel = vgui.Create("DLabel", insideData)
                       layoutPlayerLabel(dataNameLabel, layout, consoleInfo["name"] .. "/" .. acceptedFolders[1], false, dataPage)

                       -- Paints the banner
                       function dataNameLabel.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
                       end  

                       if(consoleInfo["fileType"] == "data") then
                           local dataRequiredFile = vgui.Create("DTextEntry", insideData)
                           layoutFileRow(dataRequiredFile, layout, 2, dataPage)
                           dataRequiredFile:SetFont("HackingFont")
                           dataRequiredFile:SetText(string.upper(consoleInfo["fileName"]) .. ".data")
                           dataRequiredFile:SetEditable(false)

                           local randomFile1 = vgui.Create("DTextEntry", insideData)
                           layoutFileRow(randomFile1, layout, 1, dataPage)
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetText(decoyFilenames[1] .. ".data")
                           randomFile1:SetEditable(false)

                           local randomFile2 = vgui.Create("DTextEntry", insideData)
                           layoutFileRow(randomFile2, layout, 3, dataPage)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetText(decoyFilenames[2] .. ".data")
                           randomFile2:SetEditable(false)
                       else
                           local randomFile1 = vgui.Create("DTextEntry", insideData)
                           layoutFileRow(randomFile1, layout, 2, dataPage)
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetEditable(false)
                           randomFile1:SetText("consoleLogs.data")

                           local randomFile2 = vgui.Create("DTextEntry", insideData)
                           layoutFileRow(randomFile2, layout, 1, dataPage)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetEditable(false)
                           randomFile2:SetText("recentlyDeleted.data")

                           local randomFile3 = vgui.Create("DTextEntry", insideData)
                           layoutFileRow(randomFile3, layout, 3, dataPage)
                           randomFile3:SetFont("HackingFont")
                           randomFile3:SetEditable(false)
                           randomFile3:SetText("cleaningLog.data")
                       end

                       secondPage:Hide()

                       -- Creates the access terminal
                       local dataInputTerminal = vgui.Create("DTextEntry", insideData)
                       dataInputTerminal:SetFont("HackingFont")
                       dataInputTerminal:SetPlaceholderText(COMMAND_PROMPT)
                       dataInputTerminal:SetPlaceholderColor(Color(140, 140, 140, 220))
                       dataInputTerminal:SetTextColor(Color(36, 209, 36, 255))
                       dataInputTerminal:SetPaintBackground(false)
                       dataInputTerminal:SetCursorColor(Color(36, 209, 36, 255))
                       configureCommandAssistance(dataInputTerminal, insideData, consoleInfo, "data", commandHistory, terminalSession)

                       dataInputTerminal.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                           self:SetPlaceholderText("")
                       end

                       dataInputTerminal.OnLoseFocus = function(self)
                           self:SetPlaceholderText(COMMAND_PROMPT)
                           self:SetPlaceholderColor(Color(140, 140, 140, 220))
                       end

                       function dataInputTerminal.OnEnter()
                           if handleCommandAssistance(dataInputTerminal) then return end

                            surface.PlaySound("code_enter.wav")

                           if(string.lower(dataInputTerminal:GetValue()) == "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1]) then
                               insideData:Remove()
                               insideData = nil
                               timer.Remove("dataPageGlitch")
                               timer.Remove("dataPageReturn")

                               -- Resets the input terminal
                               inputTerminal2:SetPlaceholderText(COMMAND_PROMPT)
                               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
                               inputTerminal2:SetText("")
                               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
                               timer.Start("secondPageGlitch")
                               secondPage:Show() -- Shows the previous page
                               return
                           end
                           if(string.lower(dataInputTerminal:GetValue()) == "/d" .. acceptedFolders[1] .. "/" .. consoleInfo["fileName"] .. ".data") then
                               if(consoleInfo["fileType"] == "data") then
                                   timer.Create("DownloadDataFile", consoleInfo["delay"], 1, function()
                                       closeConsoleUI()

                                       net.Start("destroyOnServer")
                                           net.WriteEntity(usedConsole) -- Allows us to delete the console on server side
                                       net.SendToServer()

                                   end)
                                   hook.Add("Think", "downloadDataFile", function()
                                       if(timer.Exists("DownloadDataFile")) then
                                           local timeLeft = math.Round(timer.TimeLeft("DownloadDataFile"), 2) -- Sets the time left = to 2 decimal places (aesthetics)
                                           dataInputTerminal:SetEditable(false) -- Prevents the player typing in the box once the countdown has started
                                           dataInputTerminal:SetText("")
                                           if(timeLeft > 0.01) then
                                               dataInputTerminal:SetPlaceholderColor(Color(36, 209, 36, 255))
                                               dataInputTerminal:SetPlaceholderText("Time to download: " .. timeLeft .. " seconds") -- Counts down for the player
                                           end 
                                       end
                                   
                                   end)
                               else
                                   dataInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                                   dataInputTerminal:SetText("")
                                   dataInputTerminal:SetPlaceholderText("[ERROR] - FILE NOT HERE (/help)")
                                   return
                               end
                           end
                           if(string.lower(dataInputTerminal:GetValue()) != "/d" .. acceptedFolders[1] .. "/" .. consoleInfo["fileName"] .. ".data" and string.lower(dataInputTerminal:GetValue()) != "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1]) then
                            dataInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                            dataInputTerminal:SetText("")
                            dataInputTerminal:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                            end
                       end

                   end

                   if(string.lower(inputTerminal2:GetValue()) == "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2]) then

                       timer.Stop("secondPageGlitch") -- Removes the glitch effect so errors aren't thrown
                       timer.Stop("secondPageReturn") -- Removes the glitch effect so errors aren't thrown

                       -- Creates the parent frame that we can close
                       insideServer = vgui.Create("DFrame")
                       insideServer:SetPos(0, 0)
                       insideServer:SetSize(layout.width, layout.height)
                       insideServer:MakePopup()
                       insideServer:SetDraggable(false)
                       insideServer:SetTitle("")
                       insideServer:ShowCloseButton(false)
                       function insideServer.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
                       end


                       -- Set the background image for the hacking UI
                       local serverBackgroundImage = vgui.Create("DImage", insideServer)
                       serverBackgroundImage:SetSize(layout.width, layout.height)
                       serverBackgroundImage:SetPos(0, 0)
                       serverBackgroundImage:SetImage("vgui/consoleframe1.png")
                       local serverPage = registerPlayerPage(terminalSession, "server", insideServer, serverBackgroundImage)
                       -- Creates the glitch effect for the console background
                       timer.Create("dataPageGlitch", math.random(lowerBound, upperBound), 0, function()
                           serverBackgroundImage:SetImage("vgui/consoleframe2.png")
                           timer.Create("dataPageReturn", 0.5, 1, function()
                               serverBackgroundImage:SetImage("vgui/consoleframe1.png")
                           end)
                       end)

                       local findFileLabel4 = vgui.Create("DLabel", insideServer)
                       layoutPlayerLabel(findFileLabel4, layout, "Locate file '" .. consoleInfo["fileName"] .. "'", true, serverPage)
                       findFileLabel4:SetTextColor(Color(255, 0, 0, 255))


                       -- Prints the console identifier to the top
                       local serverNameLabel = vgui.Create("DLabel", insideServer)
                       layoutPlayerLabel(serverNameLabel, layout, consoleInfo["name"] .. "/" .. acceptedFolders[2], false, serverPage)

                       -- Paints the banner
                       function serverNameLabel.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
                       end  

                       if(consoleInfo["fileType"] == "server") then
                           local serverRequiredFile = vgui.Create("DTextEntry", insideServer)
                           layoutFileRow(serverRequiredFile, layout, 2, serverPage)
                           serverRequiredFile:SetFont("HackingFont")
                           serverRequiredFile:SetText(string.upper(consoleInfo["fileName"]) .. ".sys")
                           serverRequiredFile:SetEditable(false)

                           local randomFile1 = vgui.Create("DTextEntry", insideServer)
                           layoutFileRow(randomFile1, layout, 1, serverPage)
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetText(decoyFilenames[1] .. ".sys")
                           randomFile1:SetEditable(false)

                           local randomFile2 = vgui.Create("DTextEntry", insideServer)
                           layoutFileRow(randomFile2, layout, 3, serverPage)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetText(decoyFilenames[2] .. ".sys")
                           randomFile2:SetEditable(false)
                       else
                           local randomFile1 = vgui.Create("DTextEntry", insideServer)
                           layoutFileRow(randomFile1, layout, 2, serverPage)
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetEditable(false)
                           randomFile1:SetText("updateCheck.sys")

                           local randomFile2 = vgui.Create("DTextEntry", insideServer)
                           layoutFileRow(randomFile2, layout, 1, serverPage)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetEditable(false)
                           randomFile2:SetText("connections.sys")

                           local randomFile3 = vgui.Create("DTextEntry", insideServer)
                           layoutFileRow(randomFile3, layout, 3, serverPage)
                           randomFile3:SetFont("HackingFont")
                           randomFile3:SetEditable(false)
                           randomFile3:SetText("idCheck.sys")
                       end

                       secondPage:Hide()

                       -- Creates the access terminal
                       local serverInputTerminal = vgui.Create("DTextEntry", insideServer)
                       serverInputTerminal:SetFont("HackingFont")
                       serverInputTerminal:SetPlaceholderText(COMMAND_PROMPT)
                       serverInputTerminal:SetPlaceholderColor(Color(140, 140, 140, 220))
                       serverInputTerminal:SetTextColor(Color(36, 209, 36, 255))
                       serverInputTerminal:SetPaintBackground(false)
                       serverInputTerminal:SetCursorColor(Color(36, 209, 36, 255))
                       configureCommandAssistance(serverInputTerminal, insideServer, consoleInfo, "server", commandHistory, terminalSession)

                       serverInputTerminal.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                           self:SetPlaceholderText("")
                       end

                       serverInputTerminal.OnLoseFocus = function(self)
                           self:SetPlaceholderText(COMMAND_PROMPT)
                           self:SetPlaceholderColor(Color(140, 140, 140, 220))
                       end

                       function serverInputTerminal.OnEnter()
                           if handleCommandAssistance(serverInputTerminal) then return end

                        surface.PlaySound("code_enter.wav")

                           if(string.lower(serverInputTerminal:GetValue()) == "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2]) then
                               insideServer:Remove()
                               insideServer = nil
                               timer.Remove("dataPageGlitch")
                               timer.Remove("dataPageReturn")

                               -- Resets the input terminal
                               inputTerminal2:SetPlaceholderText(COMMAND_PROMPT)
                               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
                               inputTerminal2:SetText("")
                               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
                               timer.Start("secondPageGlitch")
                               secondPage:Show() -- Shows the previous page
                               return
                           end
                           if(string.lower(serverInputTerminal:GetValue()) == "/d" .. acceptedFolders[2] .. "/" .. consoleInfo["fileName"] .. ".sys") then
                               if(consoleInfo["fileType"] == "server") then
                                   timer.Create("DownloadServerFile", consoleInfo["delay"], 1, function()
                                       closeConsoleUI()

                                       net.Start("destroyOnServer")
                                           net.WriteEntity(usedConsole) -- Allows us to delete the console on server side
                                       net.SendToServer()

                                   end)
                                   hook.Add("Think", "downloadServerFile", function()
                                       if(timer.Exists("DownloadServerFile")) then
                                           local timeLeft = math.Round(timer.TimeLeft("DownloadServerFile"), 2) -- Sets the time left = to 2 decimal places (aesthetics)
                                           serverInputTerminal:SetEditable(false) -- Prevents the player typing in the box once the countdown has started
                                           serverInputTerminal:SetText("")
                                           if(timeLeft > 0.01) then
                                            serverInputTerminal:SetPlaceholderColor(Color(36, 209, 36, 255))
                                            serverInputTerminal:SetPlaceholderText("Time to download: " .. timeLeft .. " seconds") -- Counts down for the player
                                           end 
                                       end
                                   
                                   end)
                               else
                                   serverInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                                   serverInputTerminal:SetText("")
                                   serverInputTerminal:SetPlaceholderText("[ERROR] - FILE NOT HERE (/help)")
                                   return
                               end
                           end
                           if(string.lower(serverInputTerminal:GetValue()) != "/d" .. acceptedFolders[2] .. "/" .. consoleInfo["fileName"] .. ".sys" and string.lower(serverInputTerminal:GetValue()) != "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2]) then
                            serverInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                            serverInputTerminal:SetText("")
                            serverInputTerminal:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                            end
                       end

                   end

                   if(string.lower(inputTerminal2:GetValue()) == "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3]) then

                       timer.Stop("secondPageGlitch") -- Removes the glitch effect so errors aren't thrown
                       timer.Stop("secondPageReturn") -- Removes the glitch effect so errors aren't thrown

                       -- Creates the parent frame that we can close
                       insideTools = vgui.Create("DFrame")
                       insideTools:SetPos(0, 0)
                       insideTools:SetSize(layout.width, layout.height)
                       insideTools:MakePopup()
                       insideTools:SetDraggable(false)
                       insideTools:SetTitle("")
                       insideTools:ShowCloseButton(false)
                       function insideTools.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
                       end


                       -- Set the background image for the hacking UI
                       local toolsBackgroundImage = vgui.Create("DImage", insideTools)
                       toolsBackgroundImage:SetSize(layout.width, layout.height)
                       toolsBackgroundImage:SetPos(0, 0)
                       toolsBackgroundImage:SetImage("vgui/consoleframe1.png")
                       local toolsPage = registerPlayerPage(terminalSession, "tools", insideTools, toolsBackgroundImage)
                       -- Creates the glitch effect for the console background
                       timer.Create("dataPageGlitch", math.random(lowerBound, upperBound), 0, function()
                           toolsBackgroundImage:SetImage("vgui/consoleframe2.png")
                           timer.Create("dataPageReturn", 0.5, 1, function()
                               toolsBackgroundImage:SetImage("vgui/consoleframe1.png")
                           end)
                       end)

                       local findFileLabel5 = vgui.Create("DLabel", insideTools)
                       layoutPlayerLabel(findFileLabel5, layout, "Locate file '" .. consoleInfo["fileName"] .. "'", true, toolsPage)
                       findFileLabel5:SetTextColor(Color(255, 0, 0, 255))


                       -- Prints the console identifier to the top
                       local toolsNameLabel = vgui.Create("DLabel", insideTools)
                       layoutPlayerLabel(toolsNameLabel, layout, consoleInfo["name"] .. "/" .. acceptedFolders[3], false, toolsPage)

                       -- Paints the banner
                       function toolsNameLabel.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
                       end  

                       if(consoleInfo["fileType"] == "tools") then
                           local toolsRequiredFile = vgui.Create("DTextEntry", insideTools)
                           layoutFileRow(toolsRequiredFile, layout, 2, toolsPage)
                           toolsRequiredFile:SetFont("HackingFont")
                           toolsRequiredFile:SetText(string.upper(consoleInfo["fileName"]) .. ".exe")
                           toolsRequiredFile:SetEditable(false)

                           local randomFile1 = vgui.Create("DTextEntry", insideTools)
                           layoutFileRow(randomFile1, layout, 1, toolsPage)
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetText(decoyFilenames[1] .. ".exe")
                           randomFile1:SetEditable(false)

                           local randomFile2 = vgui.Create("DTextEntry", insideTools)
                           layoutFileRow(randomFile2, layout, 3, toolsPage)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetText(decoyFilenames[2] .. ".sys")
                           randomFile2:SetEditable(false)
                       else
                           local randomFile1 = vgui.Create("DTextEntry", insideTools)
                           layoutFileRow(randomFile1, layout, 2, toolsPage)
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetEditable(false)
                           randomFile1:SetText("mainControl.exe")

                           local randomFile2 = vgui.Create("DTextEntry", insideTools)
                           layoutFileRow(randomFile2, layout, 1, toolsPage)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetEditable(false)
                           randomFile2:SetText("washingMachine.exe")

                           local randomFile3 = vgui.Create("DTextEntry", insideTools)
                           layoutFileRow(randomFile3, layout, 3, toolsPage)
                           randomFile3:SetFont("HackingFont")
                           randomFile3:SetEditable(false)
                           randomFile3:SetText("breathing.exe")
                       end

                       secondPage:Hide()

                       -- Creates the access terminal
                       local toolsInputTerminal = vgui.Create("DTextEntry", insideTools)
                       toolsInputTerminal:SetFont("HackingFont")
                       toolsInputTerminal:SetPlaceholderText(COMMAND_PROMPT)
                       toolsInputTerminal:SetPlaceholderColor(Color(140, 140, 140, 220))
                       toolsInputTerminal:SetTextColor(Color(36, 209, 36, 255))
                       toolsInputTerminal:SetPaintBackground(false)
                       toolsInputTerminal:SetCursorColor(Color(36, 209, 36, 255))
                       configureCommandAssistance(toolsInputTerminal, insideTools, consoleInfo, "tools", commandHistory, terminalSession)

                       toolsInputTerminal.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                           self:SetPlaceholderText("")
                       end

                       toolsInputTerminal.OnLoseFocus = function(self)
                           self:SetPlaceholderText(COMMAND_PROMPT)
                           self:SetPlaceholderColor(Color(140, 140, 140, 220))
                       end

                       function toolsInputTerminal.OnEnter()
                           if handleCommandAssistance(toolsInputTerminal) then return end

                        surface.PlaySound("code_enter.wav")

                           if(string.lower(toolsInputTerminal:GetValue()) == "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3]) then
                               insideTools:Remove()
                               insideTools = nil
                               timer.Remove("dataPageGlitch")
                               timer.Remove("dataPageReturn")

                               -- Resets the input terminal
                               inputTerminal2:SetPlaceholderText(COMMAND_PROMPT)
                               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
                               inputTerminal2:SetText("")
                               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
                               timer.Start("secondPageGlitch")
                               secondPage:Show() -- Shows the previous page
                               return
                           end
                           if(string.lower(toolsInputTerminal:GetValue()) == "/r" .. acceptedFolders[3] .. "/" .. consoleInfo["fileName"] .. ".exe") then
                               if(consoleInfo["fileType"] == "tools") then
                                   closeConsoleUI()

                                   net.Start("PlayerActivatedDoor")
                                       net.WriteEntity(usedConsole) -- Allows us to delete the console on server side
                                   net.SendToServer()

                                   return
                               else
                                   toolsInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                                   toolsInputTerminal:SetText("")
                                   toolsInputTerminal:SetPlaceholderText("[ERROR] - FILE NOT HERE (/help)")
                                   return
                               end
                           end
                           if(string.lower(toolsInputTerminal:GetValue()) != "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3] and string.lower(toolsInputTerminal:GetValue()) != "/r" .. acceptedFolders[3] .. "/" .. consoleInfo["fileName"] .. ".exe") then
                            toolsInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                            toolsInputTerminal:SetText("")
                            toolsInputTerminal:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                            end
                       end
                   end

                   -- Quits the console
                   if(string.lower(inputTerminal2:GetValue()) == "/q[" .. consoleInfo["name"] .. "]") then
                       inputTerminal2.QuitTerminal()
                        return
                   end

                   -- Runs an error message for input terminal 2
                   if(string.lower(inputTerminal2:GetValue()) != "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3] and string.lower(inputTerminal2:GetValue()) != "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2] and string.lower(inputTerminal2:GetValue()) != "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1] and string.lower(inputTerminal2:GetValue()) != "/q[" .. consoleInfo["name"] .. "]") then
                    inputTerminal2:SetPlaceholderColor(Color(255, 0, 0, 255))
                    inputTerminal2:SetText("")
                    inputTerminal2:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                    end
               end

           end) 

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code creates the countdown timer for the initial access
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
            hook.Add("Think", "printDelay", function() -- Runs this function every tick of the server
                if(timer.Exists("AccessDelay")) then
                    local timeLeft = math.Round(timer.TimeLeft("AccessDelay"), 2) -- Sets the time left = to 2 decimal places (aesthetics)
                    inputTerminal1:SetEditable(false) -- Prevents the player typing in the box once the countdown has started
                    inputTerminal1:SetText("")
                    if(timeLeft > 0.01) then
                        inputTerminal1:SetPlaceholderColor(Color(36, 209, 36, 255))
                        inputTerminal1:SetPlaceholderText("Time to access: " .. timeLeft .. " seconds") -- Counts down for the player
                    end
                    if(timeLeft <= 0.01) then
                        inputTerminal1:SetPlaceholderColor(Color(36, 209, 36, 255))
                        inputTerminal1:SetPlaceholderText("Access Granted") -- Counts down for the player
                    end
                end
            end)
        end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code runs an error command if they inputs dont match the required values
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        if(string.lower(inputTerminal1:GetValue()) != "/a[" .. consoleInfo["name"] .. "]" and string.lower(inputTerminal1:GetValue()) != "/q[" .. consoleInfo["name"] .. "]") then
            inputTerminal1:SetPlaceholderColor(Color(255, 0, 0, 255))
            inputTerminal1:SetText("")
            inputTerminal1:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
        end

    end
else
    callingPlayer:ChatPrint("This console is being used by someone else")
end
end)

   

-- END OF HACKING UI

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code creates a UI for the player if they try to access a locked door
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
local printPanel = true

net.Receive("PlayerAlert", function()

    if(printPanel == true) then
        local alertMessage = vgui.Create("DLabel")
        alertMessage:SetFont("FolderFont")
        alertMessage:SetText("This door is locked. Find a console to open it.")
        alertMessage:SetTextColor(Color(255, 0, 0, 255))
        alertMessage:SetSize(ScrW(), 100)
        alertMessage:SetPos(0, ScrH() - 100)
        alertMessage:SetContentAlignment(5)

        function alertMessage.Paint(self, w, h)
            draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 200))
        end

        printPanel = false

        timer.Create("removeAlert", 4, 1, function()
            alertMessage:Remove()
            printPanel = true
        end)
    end
    
end)


--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code closes the UI if the player has died while in the console
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
-- Only the server can confirm that a completion request was accepted.
-- This notice changes chat only, never a newer terminal's UI.
net.Receive("SlicerCompleted", function()
    local consoleName = net.ReadString()
    local fileName = net.ReadString()
    local fileType = net.ReadString()
    local playerName = net.ReadString()
    local extension = ({data = "data", server = "sys", tools = "exe"})[fileType]
    if not extension then return end
    local verb = fileType == "tools" and "executed" or "downloaded"
    chat.AddText(Color(255, 251, 0), "[" .. string.upper(consoleName) .. "]: ",
        Color(255, 255, 255, 255), playerName .. " has " .. verb .. " '" .. fileName .. "." .. extension .. "'")
end)

net.Receive("PlayerDied", closeConsoleUI)

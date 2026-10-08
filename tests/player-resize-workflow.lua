-- Drive the actual client callbacks and server receivers through viewport changes.
-- Rectangles, countdown source values, deferred deletion and input/scroll state
-- are explicit test doubles; native Derma behavior and transport are not modeled.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", think = "downloadDataFile", packet = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", think = "downloadServerFile", packet = "destroyOnServer"},
        {folder = "tools", extension = "exe", packet = "PlayerActivatedDoor"},
    }
    local transitions = {{640, 480}, {1366, 768}, {800, 600}}

    local function upvalue(callback, wanted, seen)
        if type(callback) ~= "function" then return nil end
        seen = seen or {}
        if seen[callback] then return nil end
        seen[callback] = true
        local nested, index = {}, 1
        while true do
            local name, value = debug.getupvalue(callback, index)
            if not name then break end
            if name == wanted then return value end
            if type(value) == "function" then nested[#nested + 1] = value end
            index = index + 1
        end
        for _, child in ipairs(nested) do
            local found = upvalue(child, wanted, seen)
            if found ~= nil then return found end
        end
    end

    local function instrumentClient()
        local client = gmod.client()
        client.viewport = {1920, 1080}
        client.mutations, client.timeLeftReads = {}, {}
        client.ScrW = function() return client.viewport[1] end
        client.ScrH = function() return client.viewport[2] end
        client.timer.TimeLeft = function(name)
            client.timeLeftReads[#client.timeLeftReads + 1] = name
            local timer = assert(client.timers[name], "Missing countdown source")
            return timer.remaining or timer.delay
        end
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            panel.x, panel.y, panel.width, panel.height = 0, 0, 0, 0
            function panel:SetSize(w, h)
                assert(self.valid and not self:IsMarkedForDeletion(), "Geometry touched retired panel")
                self.width, self.height = w, h
                self.geometryCalls = (self.geometryCalls or 0) + 1
            end
            function panel:SetPos(x, y)
                assert(self.valid and not self:IsMarkedForDeletion(), "Geometry touched retired panel")
                self.x, self.y = x, y
                self.geometryCalls = (self.geometryCalls or 0) + 1
            end
            function panel:Center()
                self:SetPos(((self.parent and self.parent.width or client.viewport[1]) - self.width) / 2,
                    ((self.parent and self.parent.height or client.viewport[2]) - self.height) / 2)
            end
            function panel:GetX() return self.x end
            function panel:GetY() return self.y end
            function panel:SetImage(path) self.image = path end
            function panel:MoveTo(x, y) self.animationTarget = {x, y}; self:SetPos(x, y) end
            function panel:Stop() self.animationTarget = nil; self.stopCalls = (self.stopCalls or 0) + 1 end
            for _, name in ipairs({"SetText", "SetEditable", "SetKeyboardInputEnabled", "SetPlaceholderText",
                "SetHistoryEnabled", "AddHistory", "SetCaretPos", "RequestFocus", "MakePopup", "Hide", "Show"}) do
                local original = panel[name]
                panel[name] = function(self, ...)
                    client.mutations[#client.mutations + 1] = {panel = self, name = name}
                    return original(self, ...)
                end
            end
            return panel
        end
        return client
    end

    local function packetCount(env, name)
        local count = 0
        for _, packet in ipairs(env.messages) do if packet.name == name then count = count + 1 end end
        return count
    end
    local function deliver(target, packet, sender)
        assert(packet, "Missing real callback packet")
        target.receive(packet.name, sender, unpackValues(packet.values))
    end
    local function live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    local function activeEntry(client)
        for i = #client.panels, 1, -1 do
            local panel = client.panels[i]
            if panel.OnEnter and live(panel) then return panel end
        end
        error("Missing current command input")
    end
    local function button(page, text)
        for _, panel in ipairs(page.children) do
            if panel.class == "DButton" and panel.text == text then return panel end
        end
        error("Missing " .. text)
    end
    local function openHelp(entry)
        button(entry.parent, "Commands (/help)"):DoClick()
        for i = #entry.parent.children, 1, -1 do
            local panel = entry.parent.children[i]
            if live(panel) and panel.class == "DFrame" and panel.title:match("^Commands") then
                return panel, assert(panel.children[1], "Missing existing Commands scroll")
            end
        end
        error("Commands failed to open")
    end
    local function insertion(help, command)
        local children = help.children[1].children
        for i, panel in ipairs(children) do
            if panel.class == "DLabel" and panel.text:sub(1, #command + 1) == command .. "\n" then
                return assert(children[i + 1])
            end
        end
        error("Missing insertion for " .. command)
    end
    local function action(kind)
        return (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension
    end
    local function fixture(kind)
        local f = {server = gmod.new(), client = instrumentClient(), kind = kind}
        local server = f.server
        f.owner, f.hacker, f.other = server.player(), server.player(), server.player()
        f.hacker.name = "Resize Hacker"
        f.console = server.console(f.owner)
        f.info = assert(server.configure(f.owner, f.console, kind.folder, 2))
        if kind.folder == "tools" then
            f.door = server.entity("func_door_rotating")
            f.owner.target = f.door
            server.fire("PlayerSay", f.owner, "!setEntity")
            equal(f.door.inputs[1], "Lock")
        end
        server.now = 37
        server.open(f.hacker, f.console)
        deliver(f.client, server.lastMessage("ServerSendsEntityInformation"))
        f.sessions = assert(upvalue(server.ENT.AcceptInput, "sessions"), "Missing real server session table")
        f.reservation = assert(f.sessions[f.hacker])
        f.deadline = f.reservation.completeAt
        equal(f.deadline, kind.timer and 41 or 39, "Original deadline derives from server-open time")
        f.localSession = assert(upvalue(activeEntry(f.client).IsCurrentTerminalPage, "session"))
        f.layout = f.localSession.layout
        return f
    end
    local function assertReservation(f)
        equal(f.sessions[f.hacker], f.reservation, "Keep the original server session object")
        equal(f.reservation.console, f.console, "Keep the original console identity")
        equal(f.reservation.completeAt, f.deadline, "Resize must not postpone or shorten completeAt")
        equal(f.info.inUse, true, "Keep the exclusive reservation")
        local openings = packetCount(f.server, "ServerSendsEntityInformation")
        f.server.open(f.other, f.console)
        equal(packetCount(f.server, "ServerSendsEntityInformation"), openings, "A competitor remains rejected")
        equal(f.sessions[f.other], nil)
    end
    local function visit(f, stage)
        local client = f.client
        if stage ~= "login" then
            client.command("/a[terminal]")
            client.fireTimer("AccessDelay")
            if stage ~= "folders" then client.command("/a[terminal]/{_" .. stage .. "}") end
        end
        return activeEntry(client)
    end
    local stateKeys = {"text", "title", "hidden", "editable", "keyboardInputEnabled", "History", "HistoryPos",
        "caret", "selectionStart", "selectionEnd", "placeholder", "popupCalls", "scrollOffset", "OnEnter",
        "IsCurrentTerminalPage", "ShowCommandHelp", "QuitTerminal"}
    local function snapshot(client)
        local saved = {panels = {}, timers = {}, hooks = {}, watched = {}, count = #client.panels,
            messages = #client.messages, timerEvents = #client.timerEvents, mutations = #client.mutations,
            timeLeftReads = #client.timeLeftReads, focus = client.focusedPanel}
        for _, panel in ipairs(client.panels) do
            local values = {}
            for _, key in ipairs(stateKeys) do values[key] = panel[key] end
            if panel.History then
                values.historyItems = {}
                for key, value in pairs(panel.History) do values.historyItems[key] = value end
            end
            saved.panels[panel] = values
        end
        for name, timer in pairs(client.timers) do
            saved.timers[name] = {timer = timer, callback = timer.callback, delay = timer.delay,
                stopped = timer.stopped, repeats = timer.repeats}
            saved.watched[timer.callback] = true
        end
        for name, callback in pairs(client.hooks.Think or {}) do
            saved.hooks[name], saved.watched[callback] = callback, true
        end
        return saved
    end
    local function unchanged(client, saved)
        equal(#client.panels, saved.count, "Resize must reuse every existing control")
        equal(#client.messages, saved.messages, "Resize sends no packets")
        equal(#client.timerEvents, saved.timerEvents, "Resize changes no timers")
        equal(#client.mutations, saved.mutations, "Resize must not alter text/history/editability/visibility/focus")
        equal(#client.timeLeftReads, saved.timeLeftReads, "Resize does not run countdown Think")
        equal(client.focusedPanel, saved.focus, "Keep focus ownership proxy")
        for panel, values in pairs(saved.panels) do
            for _, key in ipairs(stateKeys) do equal(panel[key], values[key], "Keep existing panel " .. key) end
            for key, value in pairs(values.historyItems or {}) do equal(panel.History[key], value, "Keep submitted history contents") end
            for key in pairs(panel.History or {}) do equal(panel.History[key], values.historyItems[key], "No added history values") end
        end
        for name, values in pairs(saved.timers) do
            equal(client.timers[name], values.timer, "Keep timer object " .. name)
            for _, key in ipairs({"callback", "delay", "stopped", "repeats"}) do
                equal(client.timers[name][key], values[key], "Keep timer " .. name .. " " .. key)
            end
        end
        for name in pairs(client.timers) do assert(saved.timers[name], "Unexpected timer after resize") end
        for name, callback in pairs(saved.hooks) do equal(client.hooks.Think[name], callback, "Keep Think callback " .. name) end
        for name in pairs(client.hooks.Think or {}) do assert(saved.hooks[name], "Unexpected Think hook") end
    end
    local function noProgressCalls(saved, callback)
        local count = 0
        local previous, mask, interval = debug.gethook()
        debug.sethook(function(event)
            if event == "call" or event == "tail call" then
                local info = debug.getinfo(2, "f")
                if info and saved.watched[info.func] then count = count + 1 end
            end
        end, "c")
        local ok, result = pcall(callback)
        debug.sethook(previous, mask, interval)
        assert(ok, result)
        equal(result, nil, "Resize hook leaves other addons in control")
        equal(count, 0, "Resize invokes no existing timer or Think callbacks")
    end
    local function geometry(entry, width, height)
        local page = entry.parent
        equal(page.width, width, "Open page width follows actual viewport")
        equal(page.height, height, "Open page height follows actual viewport")
        equal(entry.x, 20); equal(entry.y, height - 68)
        equal(entry.width, width - 40); equal(entry.height, 48)
        local background
        for _, child in ipairs(page.children) do
            if child.class == "DImage" and child.image and child.image:match("/consoleframe") then background = child end
        end
        assert(background, "Missing actual page background")
        equal(background.width, width); equal(background.height, height)
        for _, label in ipairs({"Commands (/help)", "Quit terminal"}) do
            local control = button(page, label)
            equal(control.y, height - 110)
            assert(control.x >= 0 and control.x + control.width <= width, "Footer action is clipped")
        end
    end
    local function resize(f, width, height, entry, otherEntry)
        local client, saved = f.client, snapshot(f.client)
        local oldWidth, oldHeight = unpackValues(client.viewport)
        client.viewport = {width, height}
        noProgressCalls(saved, function() return client.fire("OnScreenSizeChanged", oldWidth, oldHeight) end)
        unchanged(client, saved)
        equal(f.localSession.layout, f.layout, "Keep one shared layout table")
        geometry(entry or activeEntry(client), width, height)
        if otherEntry then geometry(otherEntry, width, height) end
        assertReservation(f)
    end
    local function draft(entry)
        entry:SetText("draft café 漢字 /a[terminal]")
        entry.HistoryPos, entry.caret, entry.selectionStart, entry.selectionEnd = 1, 7, 2, 5
        return entry:GetValue()
    end
    local function helpGeometry(help, width, height)
        local header = math.min(100, math.max(64, math.floor(height * 0.12)))
        local contentY, contentHeight = header + 60, height - 130 - (header + 60)
        equal(help.width, math.min(760, width - 40))
        equal(help.height, math.min(420, contentHeight))
        equal(help.x, math.floor((width - help.width) / 2))
        equal(help.y, contentY + math.floor((contentHeight - help.height) / 2))
    end
    local function progress(f, entry, timerName, thinkName, prefix, hidden)
        local client = f.client
        local timer, think = assert(client.timers[timerName]), assert(client.hooks.Think[thinkName])
        timer.remaining = 1.75
        client.fire("Think")
        equal(entry.editable, false); equal(entry.keyboardInputEnabled, false)
        equal(entry.placeholder, prefix .. "1.75 seconds")
        local text = draft(entry)
        local help, scroll = openHelp(entry)
        scroll.scrollOffset = 91
        local insert = insertion(help, "/help")
        insert:Think(); equal(insert.enabled, false)
        for _, size in ipairs(transitions) do
            resize(f, size[1], size[2], entry, hidden)
            equal(client.timers[timerName], timer); equal(client.hooks.Think[thinkName], think)
            equal(entry:GetValue(), text); equal(entry.editable, false)
            equal(help.children[1], scroll); equal(scroll.scrollOffset, 91)
            helpGeometry(help, size[1], size[2])
            local before = snapshot(client)
            insert:DoClick()
            unchanged(client, before)
            equal(entry:GetValue(), text, "Progress lock survives repeated resizing")
        end
        resize(f, 800, 600, entry, hidden) -- Same-size/MSAA-like event.
        timer.remaining = 0.625
        client.fire("Think")
        equal(client.timeLeftReads[#client.timeLeftReads], timerName, "Next Think reads the same countdown name")
        equal(client.timers[timerName], timer, "Next Think keeps the original countdown object")
        equal(entry.placeholder, prefix .. "0.625 seconds", "Next Think uses the original timer's current remaining value")
        equal(entry.editable, false); equal(entry:GetValue(), "")
        return timer, think
    end

    for _, kind in ipairs(kinds) do
        test("live resize preserves AccessDelay and later " .. kind.folder .. " navigation", function()
            local f = fixture(kind)
            local entry = activeEntry(f.client)
            f.client.command("/a[terminal]")
            progress(f, entry, "AccessDelay", "printDelay", "Time to access: ")
            f.client.fireTimer("AccessDelay")
            local folders = activeEntry(f.client)
            geometry(folders, 800, 600)
            equal(folders.History, entry.History, "Navigation retains the session history")
            f.client.command("/a[terminal]/{_" .. kind.folder .. "}")
            geometry(activeEntry(f.client), 800, 600)
            equal(folders.parent.hidden, true)
            assertReservation(f)
        end)
    end
    for _, kind in ipairs({kinds[1], kinds[2]}) do
        test("live resize preserves " .. kind.timer .. " and its hidden folder page", function()
            local f = fixture(kind)
            local folders = visit(f, "folders")
            f.client.command("/a[terminal]/{_" .. kind.folder .. "}")
            local entry = activeEntry(f.client)
            f.client.command(action(kind))
            progress(f, entry, kind.timer, kind.think, "Time to download: ", folders)
            equal(folders.parent.hidden, true, "Resize does not reveal the retained folder page")
            equal(packetCount(f.client, kind.packet), 0)
        end)
    end
    for _, kind in ipairs(kinds) do
        test("live resize keeps help close/reopen and hidden navigation for " .. kind.folder, function()
            local f = fixture(kind)
            local folders = visit(f, "folders")
            f.client.command("/a[terminal]/{_" .. kind.folder .. "}")
            local entry = activeEntry(f.client)
            local text = draft(entry)
            local help, scroll = openHelp(entry)
            scroll.scrollOffset = 73
            resize(f, 640, 480, entry, folders)
            equal(entry:GetValue(), text); equal(scroll.scrollOffset, 73)
            helpGeometry(help, 640, 480)
            local oldInsert = insertion(help, "//[terminal]/{_" .. kind.folder .. "}")
            help:Close()
            resize(f, 1366, 768, entry, folders)
            local replacement, newScroll = openHelp(entry)
            assert(replacement ~= help and newScroll ~= scroll, "Explicit reopening creates a fresh Commands window")
            helpGeometry(replacement, 1366, 768)
            local before = snapshot(f.client)
            oldInsert:DoClick(); unchanged(f.client, before)
            local back = "//[terminal]/{_" .. kind.folder .. "}"
            insertion(replacement, back):DoClick()
            equal(entry:GetValue(), back, "Help inserts the unchanged exact command")
            equal(f.client.focusedPanel, entry)
            entry:OnEnter()
            equal(activeEntry(f.client), folders)
            geometry(folders, 1366, 768)
            for _, folder in ipairs({"data", "server", "tools"}) do
                f.client.command("/a[terminal]/{_" .. folder .. "}")
                local current = activeEntry(f.client)
                geometry(current, 1366, 768)
                resize(f, 800, 600, current, folders)
                f.client.command("//[terminal]/{_" .. folder .. "}")
                equal(activeEntry(f.client), folders)
                resize(f, 1366, 768, folders)
            end
            local captions = 0
            for _, child in ipairs(folders.parent.children) do
                if child.class == "DLabel" and child.text:match("^{_") then captions = captions + 1 end
            end
            equal(captions, 3, "Repeated resize never duplicates folder captions")
        end)
        test("live resize retires a deferred old " .. kind.folder .. " record when the same stage reopens", function()
            local f = fixture(kind)
            local client = f.client
            local folders = visit(f, "folders")
            client.command("/a[terminal]/{_" .. kind.folder .. "}")
            local oldEntry = activeEntry(client)
            resize(f, 640, 480, oldEntry, folders)
            local oldRecord = assert(f.localSession.pages[kind.folder])
            client.deferPanelRemoval = true
            client.command("//[terminal]/{_" .. kind.folder .. "}")
            assert(oldEntry.parent.valid and oldEntry.parent:IsMarkedForDeletion())
            local oldCalls, before = oldEntry.parent.geometryCalls, snapshot(client)
            oldRecord.reflow()
            unchanged(client, before)
            equal(f.localSession.pages[kind.folder], nil, "Retire the old marked page record")
            -- The shared convenience finder predates deferred-removal cases;
            -- address the actual visible folder entry instead of a marked one.
            folders:SetText("/a[terminal]/{_" .. kind.folder .. "}")
            folders:OnEnter()
            local current = activeEntry(client)
            local replacement = assert(f.localSession.pages[kind.folder])
            assert(replacement ~= oldRecord and current ~= oldEntry)
            geometry(current, 640, 480)
            resize(f, 1366, 768, current, folders)
            before = snapshot(client)
            oldRecord.reflow(); oldEntry:OnEnter()
            unchanged(client, before)
            equal(f.localSession.pages[kind.folder], replacement, "Old callback cannot retire its replacement record")
            equal(activeEntry(client), current)
            equal(oldEntry.parent.geometryCalls, oldCalls, "Marked old frame stays untouched")
            local count = 0
            for _ in pairs(f.localSession.pages) do count = count + 1 end
            assert(count <= 5, "Keep one bounded record per player stage")
        end)
    end

    for _, kind in ipairs(kinds) do
        for _, timing in ipairs({"before", "at"}) do
            test("resized " .. kind.folder .. " completion " .. timing .. " original server deadline", function()
                local f = fixture(kind)
                local client, server = f.client, f.server
                local entry = activeEntry(client)
                client.command("/a[terminal]")
                resize(f, 640, 480, entry)
                client.fireTimer("AccessDelay")
                local folders = activeEntry(client)
                client.command("/a[terminal]/{_" .. kind.folder .. "}")
                entry = activeEntry(client)
                resize(f, 1366, 768, entry, folders)
                if kind.timer then
                    client.command(action(kind)); client.fire("Think")
                    resize(f, 800, 600, entry, folders)
                    client.fireTimer(kind.timer)
                else
                    resize(f, 800, 600, entry, folders)
                    client.command(action(kind))
                end
                client.assertClosed()
                equal(packetCount(client, kind.packet), 1, "Actual completion callback sends one request")
                equal(packetCount(client, "playerQuitConsole"), 0)
                equal(#client.chatMessages, 0, "Completion awaits server acceptance")
                local packet = assert(client.lastMessage(kind.packet))
                equal(#packet.values, 1); equal(packet.values[1], f.console)
                equal(f.sessions[f.hacker], f.reservation)
                equal(f.reservation.completeAt, f.deadline)
                server.now = f.deadline - (timing == "before" and 0.001 or 0)
                deliver(server, packet, f.hacker)
                equal(f.info.inUse, false); equal(f.sessions[f.hacker], nil)
                if timing == "before" then
                    equal(f.console.removed, nil)
                    equal(packetCount(server, "SlicerCompleted"), 0, "Before-deadline completion is rejected")
                    equal(packetCount(server, "PlayerDied"), 1)
                    if f.door then equal(#f.door.inputs, 1); equal(f.door.inputs[1], "Lock") end
                    deliver(client, server.lastMessage("PlayerDied"))
                else
                    equal(f.console.removed, true)
                    equal(packetCount(server, "SlicerCompleted"), 1, "Exact-deadline completion is accepted once")
                    local accepted = assert(server.lastMessage("SlicerCompleted"))
                    equal(accepted.player, f.hacker)
                    deliver(client, accepted)
                    equal(#client.chatMessages, 1)
                    if f.door then equal(#f.door.inputs, 2); equal(f.door.inputs[2], "Unlock") end
                end
                local sent = #server.messages
                deliver(server, packet, f.hacker)
                equal(#server.messages, sent, "A replay cannot produce another acceptance")
                local before = snapshot(client)
                client.viewport = {640, 480}
                noProgressCalls(before, function() return client.fire("OnScreenSizeChanged", 800, 600) end)
                unchanged(client, before); client.assertClosed()
            end)
        end
    end

    local cancellations = {
        {kind = kinds[1], stage = "login", timer = "AccessDelay", command = "/a[terminal]"},
        {kind = kinds[1], stage = "data", timer = "DownloadDataFile", command = action(kinds[1])},
        {kind = kinds[2], stage = "server", timer = "DownloadServerFile", command = action(kinds[2])},
        {kind = kinds[3], stage = "tools"},
    }
    for _, phase in ipairs(cancellations) do
        for _, reason in ipairs({"quit", "death", "terminal removal"}) do
            test("resized " .. phase.stage .. " " .. reason .. " retires deferred old callbacks on reopen", function()
                local f = fixture(phase.kind)
                local client, server = f.client, f.server
                local entry = visit(f, phase.stage)
                if phase.command then client.command(phase.command); client.fire("Think") end
                local help = openHelp(entry)
                local insert = insertion(help, "/help")
                resize(f, 640, 480, entry)
                local oldSession = f.localSession
                local record = assert(oldSession.pages[phase.stage], "Missing current stage resize record")
                local reflow = assert(record.reflow, "Missing guarded page-owned reflow")
                local stableHook = assert(client.hooks.OnScreenSizeChanged.SlicerPlayerTerminalReflow)
                local quit = button(entry.parent, "Quit terminal")
                client.deferPanelRemoval = true
                if reason == "quit" then
                    quit:DoClick()
                    local packet = assert(client.lastMessage("playerQuitConsole"))
                    equal(packet.values[1], f.hacker); equal(packet.values[2], f.console)
                    deliver(server, packet, f.hacker)
                    equal(packetCount(client, "playerQuitConsole"), 1)
                elseif reason == "death" then
                    f.hacker.alive = false
                    server.fire("PlayerDeath", f.hacker)
                    deliver(client, server.lastMessage("PlayerDied"))
                else
                    f.console:Remove()
                    deliver(client, server.lastMessage("PlayerDied"))
                end
                assert(entry.parent.valid and entry.parent:IsMarkedForDeletion(), "Keep native-like deferred old frame")
                equal(f.info.inUse, false); equal(f.sessions[f.hacker], nil)
                equal(next(client.timers), nil); equal(next(client.hooks.Think or {}), nil)
                local oldCalls = entry.parent.geometryCalls
                local closed = snapshot(client)
                reflow()
                client.viewport = {1366, 768}
                noProgressCalls(closed, function() return stableHook(640, 480) end)
                unchanged(client, closed)
                equal(entry.parent.geometryCalls, oldCalls, "Retired callback never touches deletion-marked old frame")

                local replacement = server.console(f.owner)
                local replacementInfo = assert(server.configure(f.owner, replacement, "data", 2))
                f.hacker.alive = true -- A later use follows the modeled respawn.
                server.open(f.hacker, replacement)
                deliver(client, server.lastMessage("ServerSendsEntityInformation"))
                local current = activeEntry(client)
                local newSession = assert(upvalue(current.IsCurrentTerminalPage, "session"))
                assert(newSession ~= oldSession)
                geometry(current, 1366, 768)
                client.command("/a[terminal]"); client.fire("Think")
                local newTimer = assert(client.timers.AccessDelay)
                local newReservation = assert(f.sessions[f.hacker])
                local saved = snapshot(client)
                reflow(); insert:DoClick(); quit:DoClick(); entry:OnEnter()
                unchanged(client, saved)
                equal(activeEntry(client), current); equal(client.timers.AccessDelay, newTimer)
                equal(f.sessions[f.hacker], newReservation); equal(newReservation.console, replacement)
                equal(replacementInfo.inUse, true)
                equal(entry.parent.geometryCalls, oldCalls)
                -- A retained global hook intentionally reads the current session.
                -- It is not an old page callback and must still reflow replacement.
                client.viewport = {800, 600}
                noProgressCalls(saved, function() return stableHook(1366, 768) end)
                unchanged(client, saved)
                geometry(current, 800, 600)
                equal(entry.parent.geometryCalls, oldCalls)
                equal(packetCount(client, phase.kind.packet), 0, "Cancellation never completes old work")
                equal(packetCount(server, "SlicerCompleted"), 0)
            end)
        end
    end
end

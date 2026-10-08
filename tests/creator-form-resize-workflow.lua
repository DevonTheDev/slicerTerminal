-- Actual creator/hacking UI callbacks and server receivers across viewport changes.
-- Only transport, rectangles, input-state proxies and deferred native cleanup are
-- doubled. Native fonts, hit-testing, focus/caret, dropdowns and timing need GMod.
return function(gmod, test, equal)
    local support = dofile("tests/player-resize-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local sizes = {{640, 480}, {800, 600}, {1024, 600}, {1280, 720}, {1366, 768}, {1920, 1080}}
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", complete = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", complete = "destroyOnServer"},
        {folder = "tools", extension = "exe", complete = "PlayerActivatedDoor"},
    }
    local function deliver(client, packet)
        assert(packet, "Missing real server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, owner, packet)
        assert(packet, "Missing real client packet")
        server.receive(packet.name, owner, unpackValues(packet.values))
    end
    local function upvalue(callback, wanted, seen)
        if type(callback) ~= "function" then return end
        seen = seen or {}
        if seen[callback] then return end
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
    local function clientAt(width, height, deferred)
        local client = support.clientAt(width or 1920, height or 1080)
        client.timeLeftReads = 0
        local timeLeft = client.timer.TimeLeft
        client.timer.TimeLeft = function(name)
            client.timeLeftReads = client.timeLeftReads + 1
            return timeLeft(name)
        end
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            for _, name in ipairs({"SetEnabled", "SetTitle", "MoveToFront", "SetDeleteOnClose", "SetDraggable"}) do
                local original = panel[name]
                panel[name] = function(self, ...)
                    client.stateCalls[#client.stateCalls + 1] = {panel = self, operation = name}
                    return original(self, ...)
                end
            end
            if deferred and class == "DFrame" then
                -- Neither lifecycle callback runs until the test releases it.
                function panel:Close() self.hidden = true; self.nativeCloseQueued = true end
                function panel:Remove() self.markedForDeletion = true; self.nativeRemoveQueued = true end
            end
            return panel
        end
        return client
    end
    local function fixture(deferred, width, height)
        local server = gmod.new()
        return {server = server, client = clientAt(width, height, deferred), owner = server.player()}
    end
    local function formSince(client, first, editing)
        local form, entries = {editing = editing}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and (panel.text == "Done" or panel.text == "Save changes") then form.submit = panel
            elseif panel.class == "DButton" and (panel.text == "Set up later" or panel.text == "Cancel") then form.dismiss = panel
            elseif panel.class == "DLabel" then form.status = panel end
        end
        assert(form.frame and form.submit and form.dismiss and form.status, "Expected original creator controls")
        equal(#entries, 3, "Keep all three actual form inputs")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        form.inputs = entries
        form.controls = editing and {form.name, form.delay, form.file, form.submit, form.dismiss, form.status}
            or {form.name, form.delay, form.folder, form.file, form.dismiss, form.submit, form.status}
        function form:fill(name, delay, file, folder)
            self.name:SetText(name or "  Terminal  ")
            self.delay:SetText(delay or "2.5")
            self.file:SetText(file or "  Secret  ")
            if self.folder then self.folder.selected = folder or "data" end
        end
        return form
    end
    local function setup(f, console)
        if console then f.server.open(f.owner, console) else console = f.server.console(f.owner) end
        local opening = assert(f.server.lastMessage("PlayerSpawnedConsole"))
        equal(opening.player, f.owner); equal(opening.values[2], console:GetName())
        local first = #f.client.panels + 1
        deliver(f.client, opening)
        local form = formSince(f.client, first, false)
        form.console, form.opening = console, opening
        return form
    end
    local function configured(f, folder, delay, name)
        local console = f.server.console(f.owner)
        f.server.receive("AdminFinishedCreation", f.owner, {name or "Terminal", delay or 2.5,
            folder or "data", "Secret", console:GetName()})
        assert(console.SlicerInformation, "Configure through the actual legacy server handler")
        return console
    end
    local function edit(f, console)
        f.owner.target = console
        local before = #f.server.messages
        f.server.fire("PlayerSay", f.owner, "!editConsole")
        assert(#f.server.messages > before, "Real creator command must open an editor")
        local opening = assert(f.server.lastMessage("SlicerSetupEditOpen"))
        equal(opening.player, f.owner); equal(opening.values[1], console); equal(opening.values[2], f.owner)
        local first = #f.client.panels + 1
        deliver(f.client, opening)
        local form = formSince(f.client, first, true)
        form.console, form.opening, form.token = console, opening, opening.values[3]
        return form
    end
    local function pending(form, expected)
        equal(support.live(form.frame), true)
        equal(form.submit.enabled, not expected)
        for _, input in ipairs(form.inputs) do equal(input.editable, not expected) end
        if form.folder then equal(form.folder.enabled, not expected) end
        equal(form.dismiss.text, expected and "Close" or (form.editing and "Cancel" or "Set up later"))
    end
    local function submit(f, form)
        local before = #f.client.messages
        form.submit:DoClick()
        equal(#f.client.messages, before + 1, "One actual save sends exactly one packet")
        pending(form, true)
        local packet = assert(f.client.lastMessage(form.editing and "SlicerSetupEditSave" or "AdminFinishedCreation"))
        if form.editing then
            equal(packet.values[1], form.console); equal(packet.values[2], form.token)
        else
            equal(packet.values[1][5], form.console:GetName())
            assert(type(packet.values[1][6]) == "string", "Initial request has a correlated identity")
        end
        return packet
    end
    local function response(f, form, packet, accepted, sender)
        local before = #f.server.messages
        relay(f.server, sender or f.owner, packet)
        assert(#f.server.messages > before, "Real receiver must acknowledge the request")
        local reply = assert(f.server.lastMessage(form.editing and "SlicerSetupEditReply" or "SlicerInitialSetupReply"))
        equal(reply.player, sender or f.owner)
        equal(reply.values[1], form.editing and packet.values[2] or packet.values[1][6])
        equal(reply.values[2].ok, accepted)
        return reply
    end
    local stateKeys = {"text", "title", "selected", "enabled", "hidden", "editable", "keyboardInputEnabled",
        "placeholder", "History", "HistoryPos", "caret", "selectionStart", "selectionEnd", "popupCalls", "frontCalls",
        "scrollOffset", "deleteOnClose", "OnEnter", "DoClick", "OnClose", "OnRemove", "ShowCommandHelp", "QuitTerminal"}
    local function snapshot(client)
        local saved = {panels = {}, timers = {}, think = {}, watched = {}, count = #client.panels,
            messages = #client.messages, state = #client.stateCalls, timerEvents = #client.timerEvents,
            focusCalls = #client.focusCalls, caretCalls = #client.caretCalls, historyCalls = #client.historyCalls,
            reads = client.timeLeftReads, focus = client.focusedPanel}
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
        for name, callback in pairs(client.hooks.Think or {}) do saved.think[name], saved.watched[callback] = callback, true end
        return saved
    end
    local function unchanged(client, saved)
        equal(#client.panels, saved.count, "Reuse exact creator/player panels")
        equal(#client.messages, saved.messages, "Reflow sends no submit, retry, cancel or quit packet")
        equal(#client.stateCalls, saved.state, "Reflow calls no state setter, popup or focus operation")
        equal(#client.timerEvents, saved.timerEvents, "Reflow creates, removes, starts and stops no timers")
        equal(#client.focusCalls, saved.focusCalls); equal(#client.caretCalls, saved.caretCalls)
        equal(#client.historyCalls, saved.historyCalls); equal(client.focusedPanel, saved.focus)
        equal(client.timeLeftReads, saved.reads, "Reflow does not read or advance a countdown")
        for panel, values in pairs(saved.panels) do
            for _, key in ipairs(stateKeys) do equal(panel[key], values[key], "Preserve exact existing panel " .. key) end
            for key, value in pairs(values.historyItems or {}) do equal(panel.History[key], value) end
            for key in pairs(panel.History or {}) do equal(panel.History[key], values.historyItems[key]) end
        end
        for name, values in pairs(saved.timers) do
            equal(client.timers[name], values.timer, "Keep original timer object")
            for _, key in ipairs({"callback", "delay", "stopped", "repeats"}) do equal(client.timers[name][key], values[key]) end
        end
        for name in pairs(client.timers) do assert(saved.timers[name], "No unexpected timer") end
        for name, callback in pairs(saved.think) do equal(client.hooks.Think[name], callback) end
        for name in pairs(client.hooks.Think or {}) do assert(saved.think[name], "No unexpected Think callback") end
    end
    local function geometry(form, width, height)
        local frame = form.frame
        assert(support.live(frame), "Fit assertions require the current visible form")
        if form.editing then
            equal(frame.width, 460); equal(frame.height, 430)
            equal(frame.x, (width - 460) / 2, "Saved editor centers within the new viewport")
            equal(frame.y, (height - 430) / 2)
        else
            equal(frame.width, width, "Initial setup follows the new viewport")
            equal(frame.height, height); equal(frame.x, 0); equal(frame.y, 0)
        end
        for _, panel in ipairs(form.controls) do
            assert(panel.x >= 0 and panel.y >= 0 and panel.width > 0 and panel.height > 0, "Creator rectangle remains usable")
            assert(panel.x + panel.width <= frame.width and panel.y + panel.height <= frame.height,
                "Creator inputs/actions/status remain contained")
        end
        if not form.editing then
            equal(form.status.height, 72); equal(form.status.y, (height - 432) / 2 + 360)
            for i = 1, 6 do
                local panel = form.controls[i]
                equal(panel.height, 48); equal(panel.width, 400)
                equal(panel.x, (width - 400) / 2); equal(panel.y, (height - 432) / 2 + (i - 1) * 60)
            end
        end
    end
    local function resize(f, width, height, forms, noGeometry)
        local client, saved, progressCalls = f.client, snapshot(f.client), 0
        local geometryCount, previous, mask, interval = #client.geometryCalls, debug.gethook()
        debug.sethook(function(event)
            if event == "call" or event == "tail call" then
                local info = debug.getinfo(2, "f")
                if info and saved.watched[info.func] then progressCalls = progressCalls + 1 end
            end
        end, "c")
        local ok, result = pcall(client.resize, width, height)
        debug.sethook(previous, mask, interval)
        assert(ok, result)
        equal(result, nil, "Screen hook leaves other addons in control")
        equal(progressCalls, 0, "Resize invokes no existing timer/Think callback")
        unchanged(client, saved)
        if noGeometry then equal(#client.geometryCalls, geometryCount, "Same/unsupported size changes no geometry") end
        for _, form in ipairs(forms or {}) do geometry(form, width, height) end
    end
    local function retiredGeometry(client, first, form)
        local owned = {[form.frame] = true}
        for _, child in ipairs(form.frame.children) do owned[child] = true end
        for i = first, #client.geometryCalls do assert(not owned[client.geometryCalls[i].panel], "Old callback cannot reflow a retired owner") end
    end
    local function oldReflow(form)
        local record = assert(upvalue(form.submit.DoClick, form.editing and "edit" or "setup"), "Actual callback owns its creator record")
        return assert(record.reflow, "Each current creator record owns its geometry callback")
    end
    local function select(f, target)
        f.owner.target = target
        f.server.fire("PlayerSay", f.owner, "!setEntity")
    end
    local function registered(f, console)
        local count, record = 0
        for _, item in ipairs(f.server.returnSpawnedEntities()) do
            if item.entity == console then count, record = count + 1, item end
        end
        equal(count, 1); equal(record.information, console.SlicerInformation); equal(record.entityName, console:GetName())
    end

    test("pending initial setup and saved edit reflow independently with exact drafts and correlated outcomes", function()
        local f = fixture()
        local initial = setup(f)
        local savedConsole = configured(f, "server", 2.7182818284590451)
        local saved = edit(f, savedConsole)
        initial:fill("  Café draft  ", "2.", "  Résumé  ", "tools")
        saved:fill("  名称 draft  ", "2.", "  文件  ")
        saved.name.caret, saved.name.selectionStart, saved.name.selectionEnd = 5, 1, 4
        saved.name:RequestFocus()
        for _, size in ipairs(sizes) do resize(f, size[1], size[2], {initial, saved}) end
        for i = #sizes - 1, 1, -1 do resize(f, sizes[i][1], sizes[i][2], {initial, saved}) end
        initial:fill("  Café draft  ", "4.25", "  Résumé  ", "tools")
        saved.delay:SetText("3.75")
        local first, second = submit(f, initial), submit(f, saved)
        local oldSubmission = assert(upvalue(initial.submit.DoClick, "setup")).pending
        local firstToken, secondToken = first.values[1][6], second.values[2]
        resize(f, 1366, 768, {initial, saved})
        equal(first.values[1][6], firstToken); equal(second.values[2], secondToken)
        equal(first.values[1][1], "  Café draft  "); equal(first.values[1][3], "tools")
        equal(second.values[3].name, "  名称 draft  "); equal(second.values[3].delay, 3.75)
        -- Make only the initial packet invalid at the server transport boundary.
        first.values[1][2] = 0
        local rejected = response(f, initial, first, false)
        local accepted = response(f, saved, second, true)
        pending(initial, true); pending(saved, true)
        resize(f, 640, 480, {initial, saved})
        deliver(f.client, accepted); equal(support.live(saved.frame), false); pending(initial, true)
        deliver(f.client, rejected); pending(initial, false)
        equal(initial.status.text, rejected.values[2].message)
        equal(initial.name:GetValue(), "  Café draft  "); equal(initial.delay:GetValue(), "4.25")
        equal(initial.file:GetValue(), "  Résumé  "); equal(initial.folder:GetSelected(), "tools")
        resize(f, 800, 600, {initial})
        local retry = submit(f, initial)
        assert(retry.values[1][6] ~= firstToken, "An explicit retry alone allocates a new setup request")
        deliver(f.client, rejected)
        oldSubmission.reply(rejected.values[2]) -- The actual retained callback also lost ownership.
        pending(initial, true)
        resize(f, 1024, 600, {initial})
        local nextReply = response(f, initial, retry, true)
        deliver(f.client, nextReply); equal(support.live(initial.frame), false)
        deliver(f.client, nextReply); deliver(f.client, accepted)
        registered(f, initial.console); registered(f, savedConsole)
    end)

    test("two initial forms and one rejected editor retain independent dimensions and reordered replies", function()
        local f = fixture()
        local alpha, beta = setup(f), setup(f)
        local console = configured(f, "data")
        local editor = edit(f, console)
        alpha:fill("Alpha", "3.5", "Alpha file", "server")
        beta:fill("Beta draft", "2.", "Beta file", "data")
        editor:fill("Rejected edit", "4.5", "Rejected file")
        local alphaRequest, editRequest = submit(f, alpha), submit(f, editor)
        editRequest.values[3].delay = 0
        deliver(f.client, response(f, editor, editRequest, false)); pending(editor, false)
        resize(f, 640, 480, {alpha, beta, editor})
        beta.delay:SetText("6.25")
        local betaRequest = submit(f, beta)
        assert(alphaRequest.values[1][6] ~= betaRequest.values[1][6])
        local alphaReply, betaReply = response(f, alpha, alphaRequest, true), response(f, beta, betaRequest, true)
        resize(f, 1366, 768, {alpha, beta, editor})
        deliver(f.client, betaReply); pending(alpha, true); pending(editor, false)
        resize(f, 800, 600, {alpha, editor})
        deliver(f.client, betaReply); deliver(f.client, alphaReply)
        equal(support.live(alpha.frame), false); equal(support.live(beta.frame), false)
        equal(editor.name:GetValue(), "Rejected edit")
        local panelCount = #f.client.panels
        deliver(f.client, editor.opening)
        equal(#f.client.panels, panelCount, "A repeated current ticket retains the exact rejected draft")
        resize(f, 1024, 600, {editor})
        editor.dismiss:DoClick(); relay(f.server, f.owner, f.client.lastMessage("SlicerSetupEditCancel"))
    end)

    test("same and invalid viewport events preserve live pending geometry then recover", function()
        local f = fixture()
        local initial, editor = setup(f), edit(f, configured(f, "server"))
        initial:fill(); editor:fill()
        local request = submit(f, initial)
        resize(f, 640, 480, {initial, editor})
        resize(f, 640, 480, {initial, editor}, true)
        local invalid = {{0, 0}, {639, 480}, {640, 479}, {-1, -2}, {"800", 600},
            {math.huge, 600}, {800, -math.huge}, {0 / 0, 600}, {800, 0 / 0}}
        for _, size in ipairs(invalid) do
            resize(f, size[1], size[2], nil, true)
            geometry(initial, 640, 480); geometry(editor, 640, 480); pending(initial, true)
        end
        resize(f, 1920, 1080, {initial, editor})
        deliver(f.client, response(f, initial, request, true))
        editor.dismiss:DoClick()
    end)

    test("new initial and edit forms use the supported minimum during invalid viewport values", function()
        local f = fixture(nil, 0 / 0, math.huge)
        local initial, editor = setup(f), edit(f, configured(f))
        geometry(initial, 640, 480); geometry(editor, 640, 480)
        initial:fill("Minimum draft", "2.", "Untouched", "data")
        resize(f, 1280, 720, {initial, editor})
    end)

    test("initial client reinclude preserves a pending request and reflows its original controls once", function()
        local f = fixture()
        local form = setup(f); form:fill("Original pending", "5.75", "Pending file", "server")
        local request, first = submit(f, form), #f.client.panels
        local serial = f.client.slicerInitialSetupSerial
        f.client.include("entities/consoleent/cl_init.lua")
        equal(#f.client.panels, first); equal(f.client.slicerInitialSetupSerial, serial)
        pending(form, true)
        resize(f, 640, 480, {form})
        resize(f, 640, 480, {form}, true)
        f.server.open(f.owner, form.console)
        deliver(f.client, f.server.lastMessage("PlayerSpawnedConsole"))
        equal(#f.client.panels, first); pending(form, true)
        resize(f, 1366, 768, {form})
        deliver(f.client, response(f, form, request, true))
        equal(support.live(form.frame), false)
        equal(form.console.SlicerInformation.name, "original pending")
        equal(form.console.SlicerInformation.delay, 5.75)
    end)

    for _, entryPath in ipairs({"deferred Use", "unconfigured duplicate Use"}) do
        test(entryPath .. " opens creator-owned setup that reflows before real acknowledgement", function()
            local f = fixture()
            local original = setup(f)
            original:fill("Discarded draft", "2.", "Discarded file", "tools")
            original.dismiss:DoClick()
            equal(#f.client.messages, 0)
            local console, previousOwner = original.console, f.owner
            if entryPath == "unconfigured duplicate Use" then
                local data = {Name = console:GetName(), SlicerCreator = console.SlicerCreator}
                console:OnEntityCopyTableFinish(data)
                f.owner = f.server.player()
                local copy = setmetatable(f.server.entity("consoleent"), {__index = f.server.ENT})
                copy:Initialize(); copy:SetName(data.Name); copy.SlicerCreator = data.SlicerCreator
                copy:OnDuplicated(data); copy:PostEntityPaste(f.owner, copy, {})
                assert(copy:GetName() ~= console:GetName())
                equal(copy.SlicerCreator, f.owner); equal(copy.SlicerInformation, nil)
                console = copy
            end
            local before = #f.server.messages
            f.server.open(entryPath == "deferred Use" and f.server.player() or previousOwner, console)
            equal(#f.server.messages, before, "Use still checks this console's real creator")
            f.owner.weapon = nil
            local fresh = setup(f, console)
            fresh:fill("Fresh draft", "3.125", "Fresh file", "data")
            resize(f, 640, 480, {fresh})
            local request = submit(f, fresh)
            resize(f, 1366, 768, {fresh})
            deliver(f.client, response(f, fresh, request, true))
            equal(support.live(fresh.frame), false); equal(console.SlicerInformation.name, "fresh draft")
            equal(console.SlicerInformation.delay, 3.125); registered(f, console)
            if entryPath == "unconfigured duplicate Use" then
                equal(original.console.SlicerInformation, nil); equal(original.console.SlicerCreator, previousOwner)
            end
        end)
    end

    for _, editing in ipairs({false, true}) do
        for _, retirement in ipairs({"Close", "Remove", "Hide"}) do
            test((editing and "saved edit" or "initial setup") .. " deferred " .. retirement .. " prevents old geometry and replies from touching a replacement", function()
                local f = fixture(true)
                local console = editing and configured(f, "server") or nil
                local old = editing and edit(f, console) or setup(f)
                console = old.console
                old:fill("Old pending", "3.5", "Old file", "server")
                local oldRequest = submit(f, old)
                local reflow, oldSubmit, oldDismiss = oldReflow(old), old.submit.DoClick, old.dismiss.DoClick
                old.frame[retirement](old.frame)
                assert(old.frame.valid, "Deferred native lifecycle retains panel identity")
                if editing then
                    -- Use the real public cancellation receiver to retire the server ticket.
                    f.server.receive("SlicerSetupEditCancel", f.owner, console, old.token)
                end
                local fresh = editing and edit(f, console) or setup(f, console)
                fresh:fill("Replacement draft", "7.25", "Replacement file", "server")
                local freshRequest = submit(f, fresh)
                local geometryFirst, messages = #f.client.geometryCalls + 1, #f.client.messages
                if retirement == "Close" then old.frame:Show() end
                resize(f, 640, 480, {fresh})
                reflow(640, 480); oldSubmit(); oldDismiss()
                retiredGeometry(f.client, geometryFirst, old)
                equal(#f.client.messages, messages, "Retained creator callbacks send no packets")
                -- Retired initial requests may still commit; retiring an edit ticket rejects its save.
                local oldReply = response(f, old, oldRequest, not editing)
                deliver(f.client, oldReply); pending(fresh, true)
                equal(fresh.name:GetValue(), "Replacement draft")
                if old.frame.OnClose then old.frame:OnClose() end
                if old.frame.OnRemove then old.frame:OnRemove() end
                geometryFirst = #f.client.geometryCalls + 1
                resize(f, 1366, 768, {fresh}); reflow(1366, 768); oldSubmit(); oldDismiss()
                retiredGeometry(f.client, geometryFirst, old)
                equal(#f.client.messages, messages)
                deliver(f.client, response(f, fresh, freshRequest, editing))
                if editing then
                    equal(support.live(fresh.frame), false); equal(console.SlicerInformation.name, "replacement draft")
                else
                    pending(fresh, false); equal(console.SlicerInformation.name, "old pending")
                    equal(fresh.name:GetValue(), "Replacement draft")
                    resize(f, 800, 600, {fresh})
                end
                deliver(f.client, oldReply); registered(f, console)
            end)
        end
    end

    test("resize preserves sender, exact console and ticket authority before genuine replies", function()
        local f = fixture()
        local initial = setup(f); initial:fill("Owner only", "3.25", "Owner file", "data")
        local console, other = configured(f, "server"), configured(f, "data")
        local editor = edit(f, console); editor:fill("Owner edit", "4.75", "Edited file")
        local setupRequest, editRequest = submit(f, initial), submit(f, editor)
        resize(f, 640, 480, {initial, editor})
        local outsider, information, otherInformation = f.server.player(), console.SlicerInformation, other.SlicerInformation
        response(f, initial, setupRequest, false, outsider)
        response(f, editor, editRequest, false, outsider)
        equal(initial.console.SlicerInformation, nil); equal(console.SlicerInformation, information)
        local wrongConsole = {name = editRequest.name, values = {other, editRequest.values[2], editRequest.values[3]}}
        response(f, editor, wrongConsole, false)
        equal(other.SlicerInformation, otherInformation); equal(console.SlicerInformation, information)
        local wrongRequest = {name = "SlicerInitialSetupReply", values = {"9007199254740991", {ok = false, message = "Unrelated request"}}}
        local wrongTicket = {name = "SlicerSetupEditReply", values = {"9007199254740991", {ok = true}}}
        deliver(f.client, wrongRequest); deliver(f.client, wrongTicket)
        pending(initial, true); pending(editor, true)
        resize(f, 1024, 600, {initial, editor})
        deliver(f.client, response(f, editor, editRequest, true))
        deliver(f.client, response(f, initial, setupRequest, true))
        equal(console.SlicerInformation.name, "owner edit"); equal(other.SlicerInformation, otherInformation)
        equal(initial.console.SlicerInformation.name, "owner only")
    end)

    for _, change in ipairs({"removed console", "retired ticket", "changed owner"}) do
        test("resized editor retains its rejected draft after " .. change, function()
            local f = fixture()
            local console = configured(f, "tools")
            local form = edit(f, console); form:fill("Stale draft", "4.5", "Stale file")
            local request = submit(f, form)
            resize(f, 640, 480, {form})
            local original = console.SlicerInformation
            if change == "removed console" then console:Remove()
            elseif change == "retired ticket" then f.server.receive("SlicerSetupEditCancel", f.owner, console, form.token)
            else console.SlicerCreator = f.server.player() end
            local rejected = response(f, form, request, false)
            resize(f, 1366, 768, {form})
            deliver(f.client, rejected); pending(form, false)
            equal(form.status.text, rejected.values[2].message); equal(form.name:GetValue(), "Stale draft")
            equal(console.SlicerInformation, original); equal(original.name, "terminal")
            equal(console.SlicerDoor, nil)
            resize(f, 800, 600, {form})
        end)
    end

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " resized creator setup and name-only saved edit preserve exact delay through normal completion", function()
            local f = fixture()
            local form = setup(f)
            local preciseDelay = 2.7182818284590451
            form:fill("  Terminal  ", "2.7182818284590451", "  Secret  ", kind.folder)
            local request = submit(f, form)
            resize(f, 640, 480, {form})
            local accepted = response(f, form, request, true)
            resize(f, 1366, 768, {form})
            local console = form.console
            equal(console.SlicerInformation.delay, preciseDelay)
            local door, beta
            if kind.folder == "tools" then
                beta = configured(f, "tools", 2, "Beta")
                select(f, beta)
                equal(f.owner.SlicerPendingConsole, beta)
                resize(f, 1280, 720, {form})
                equal(f.owner.SlicerPendingConsole, beta)
            end
            local beforeChats = #f.owner.chats
            deliver(f.client, accepted)
            if kind.folder == "tools" then
                equal(f.owner.SlicerPendingConsole, beta, "Acknowledgement/reflow cannot reorder a pending door choice")
                local guidance = table.concat(f.owner.chats, "\n", beforeChats + 1)
                assert(guidance:find('console "terminal"', 1, true) and guidance:find("!setEntity", 1, true),
                    "Actual tools acceptance guides explicit console reselection")
                door = f.server.entity("func_door_rotating")
                select(f, console); select(f, door)
                equal(console.SlicerDoor, door); equal(beta.SlicerDoor, nil); equal(door.inputs[1], "Lock")
            end
            local editor = edit(f, console)
            equal(tonumber(editor.delay:GetValue()), preciseDelay, "Saved text keeps the full stored double")
            editor.name:SetText("  Renamed Console  ")
            local delayText = editor.delay:GetValue()
            resize(f, 800, 600, {editor})
            equal(editor.delay:GetValue(), delayText)
            local editRequest = submit(f, editor)
            equal(editRequest.values[3].delay, preciseDelay)
            resize(f, 1024, 600, {editor})
            local editReply = response(f, editor, editRequest, true)
            resize(f, 1280, 720, {editor})
            deliver(f.client, editReply)
            equal(console.SlicerInformation.delay, preciseDelay); equal(console.SlicerDoor, door)
            if door then
                local actions = #door.inputs
                f.owner.target = door
                f.server.fire("PlayerSay", f.owner, "!inspectLink")
                local inspected = f.owner.chats[#f.owner.chats]
                assert(inspected:find("renamed console", 1, true) and inspected:find("current ID #" .. door:GetCreationID(), 1, true),
                    "Inspection reports the same authoritative door after edit and reflow")
                equal(#door.inputs, actions, "Read-only inspection leaves the existing lock unchanged")
            end
            registered(f, console)
            local hacker, started = f.server.player(), 31
            f.server.now = started
            f.server.open(hacker, console)
            deliver(f.client, f.server.lastMessage("ServerSendsEntityInformation"))
            f.client.command("/a[renamed console]")
            equal(f.client.timers.AccessDelay.delay, preciseDelay)
            f.client.fireTimer("AccessDelay")
            f.client.command("/a[renamed console]/{_" .. kind.folder .. "}")
            f.client.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension)
            if kind.timer then f.client.fireTimer(kind.timer) end
            f.server.now = started + preciseDelay * (kind.timer and 2 or 1)
            relay(f.server, hacker, f.client.lastMessage(kind.complete))
            equal(console.removed, true)
            if door then equal(door.inputs[#door.inputs], "Unlock") end
            deliver(f.client, f.server.lastMessage("SlicerCompleted"))
            f.client.assertClosed()
        end)
    end

    for _, outcome in ipairs({"accepted", "rejected", "closed pending"}) do
        test("creator resize and " .. outcome .. " acknowledgements preserve another hack, Commands and original deadline", function()
            local f = fixture()
            local initial = setup(f); initial:fill("Creator setup", "5.5", "Creator file", "server")
            local editorConsole = configured(f, "data")
            local editor = edit(f, editorConsole); editor:fill("Creator edit", "6.5", "Edit file")
            local pendingDoor = configured(f, "tools", 2, "Pending door")
            local active = configured(f, "data", 2, "Active")
            f.server.now = 37
            f.server.open(f.owner, active)
            deliver(f.client, f.server.lastMessage("ServerSendsEntityInformation"))
            local sessions = assert(upvalue(f.server.ENT.AcceptInput, "sessions"))
            local reservation = assert(sessions[f.owner])
            local deadline = reservation.completeAt
            equal(deadline, 41)
            f.client.command("/a[active]")
            local entry, timer = support.entry(f.client), assert(f.client.timers.AccessDelay)
            local help = support.help(f.client, entry)
            entry:SetText("  unrelated draft  ")
            entry:SetCaretPos(7); entry.selectionStart, entry.selectionEnd = 2, 9
            entry:RequestFocus()
            local initialRequest, editRequest = submit(f, initial), submit(f, editor)
            if outcome == "rejected" then initialRequest.values[1][2] = 0; editRequest.values[3].delay = 0 end
            local initialReply = response(f, initial, initialRequest, outcome ~= "rejected")
            local editReply = response(f, editor, editRequest, outcome ~= "rejected")
            resize(f, 640, 480, {initial, editor})
            equal(entry.parent.width, 640); equal(entry.parent.height, 480)
            assert(help.x >= 0 and help.x + help.width <= 640 and help.y + help.height <= 480)
            equal(sessions[f.owner], reservation); equal(reservation.completeAt, deadline)
            equal(f.owner.SlicerPendingConsole, pendingDoor); equal(active.SlicerInformation.inUse, true)
            equal(f.client.timers.AccessDelay, timer); equal(support.live(help), true)
            equal(entry:GetValue(), "  unrelated draft  "); equal(entry.History[1], "/a[active]")
            if outcome == "closed pending" then
                initial.dismiss:DoClick(); editor.dismiss:DoClick()
                relay(f.server, f.owner, f.client.lastMessage("SlicerSetupEditCancel"))
            end
            deliver(f.client, editReply); deliver(f.client, initialReply)
            equal(f.client.timers.AccessDelay, timer); equal(support.live(help), true)
            equal(f.client.lastMessage("playerQuitConsole"), nil)
            equal(sessions[f.owner], reservation); equal(reservation.completeAt, deadline)
            if outcome == "rejected" then pending(initial, false); pending(editor, false) end
            resize(f, 1366, 768, outcome == "rejected" and {initial, editor} or {})
            f.client.fireTimer("AccessDelay")
            f.client.command("/a[active]/{_data}"); f.client.command("/d{_data}/secret.data")
            local download = assert(f.client.timers.DownloadDataFile)
            resize(f, 800, 600, outcome == "rejected" and {initial, editor} or {})
            equal(f.client.timers.DownloadDataFile, download); equal(reservation.completeAt, deadline)
            f.client.fireTimer("DownloadDataFile")
            f.server.now = deadline
            relay(f.server, f.owner, f.client.lastMessage("destroyOnServer"))
            equal(active.removed, true); equal(sessions[f.owner], nil)
            deliver(f.client, f.server.lastMessage("SlicerCompleted"))
            equal(f.owner.SlicerPendingConsole, pendingDoor); equal(editorConsole.removed, nil)
            if outcome == "rejected" then
                -- Session cleanup owns only player pages; creator drafts remain current.
                pending(initial, false); pending(editor, false)
                resize(f, 1024, 600, {initial, editor})
                initial.dismiss:DoClick(); editor.dismiss:DoClick()
            end
            f.client.assertClosed()
        end)
    end

    test("creator reflow cannot grant early completion or transfer another console's door cleanup", function()
        local f = fixture()
        local initial = setup(f); initial:fill("Unrelated draft", "2.", "Untouched", "tools")
        local linked, sibling = configured(f, "tools", 2, "Linked"), configured(f, "tools", 2, "Sibling")
        local door, otherDoor = f.server.entity("func_door_rotating"), f.server.entity("func_door")
        select(f, linked); select(f, door); select(f, sibling); select(f, otherDoor)
        local editor = edit(f, sibling); editor.name:SetText("Renamed sibling")
        local request = submit(f, editor)
        local hacker = f.server.player()
        f.server.now = 50; f.server.open(hacker, linked)
        deliver(f.client, f.server.lastMessage("ServerSendsEntityInformation"))
        local sessions = assert(upvalue(f.server.ENT.AcceptInput, "sessions"))
        local reservation = assert(sessions[hacker]); equal(reservation.completeAt, 52)
        resize(f, 640, 480, {initial, editor})
        equal(linked.SlicerDoor, door); equal(sibling.SlicerDoor, otherDoor)
        f.server.now = 51.99
        f.server.receive("PlayerActivatedDoor", hacker, linked)
        equal(linked.removed, nil); equal(door.inputs[#door.inputs], "Lock")
        equal(otherDoor.inputs[#otherDoor.inputs], "Lock"); equal(sessions[hacker], nil)
        deliver(f.client, f.server.lastMessage("PlayerDied"))
        pending(editor, true); geometry(initial, 640, 480)
        deliver(f.client, response(f, editor, request, true))
        equal(sibling.SlicerDoor, otherDoor); equal(sibling.SlicerInformation.name, "renamed sibling")
        resize(f, 1366, 768, {initial})
        f.server.now = 60; f.server.open(hacker, linked)
        f.server.now = 62; f.server.receive("PlayerActivatedDoor", hacker, linked)
        equal(linked.removed, true); equal(door.inputs[#door.inputs], "Unlock")
        equal(otherDoor.inputs[#otherDoor.inputs], "Lock"); equal(sibling.removed, nil)
        resize(f, 800, 600, {initial})
        initial.dismiss:DoClick()
    end)
end

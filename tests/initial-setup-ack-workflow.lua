-- Initial setup through the addon's real spawn/Use, UI, network, chat, copy
-- and completion callbacks. Only transport, panel rectangles and deferred
-- native cleanup are doubled here; no private form/session state is read.
-- Native Derma/font/focus, packet delivery and physical doors need a game test.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local replyName = "SlicerInitialSetupReply"
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", complete = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", complete = "destroyOnServer"},
        {folder = "tools", extension = "exe", complete = "PlayerActivatedDoor"},
    }
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, owner, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, owner, unpackValues(packet.values))
    end
    local function live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    local function clientAt(width, height, deferredNative)
        local client = gmod.client()
        client.ScrW, client.ScrH = function() return width end, function() return height end
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            function panel:SetSize(w, h) self.width, self.height = w, h end
            function panel:SetPos(x, y) self.x, self.y = x, y end
            function panel:Center()
                self.x, self.y = (width - self.width) / 2, (height - self.height) / 2
            end
            function panel:GetX() return self.x or 0 end
            function panel:GetY() return self.y or 0 end
            if deferredNative and class == "DFrame" then
                -- Delay both callbacks, unlike the ordinary host Close double.
                -- Production must retire synchronously around these methods.
                function panel:Close() self.hidden = true; self.nativeCloseQueued = true end
                function panel:Remove() self.markedForDeletion = true; self.nativeRemoveQueued = true end
            end
            return panel
        end
        return client
    end
    local function formSince(client, first)
        local form, entries = {}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == "Done" then form.done = panel
            elseif panel.class == "DButton" and panel.text == "Set up later" then form.later = panel
            elseif panel.class == "DLabel" then form.status = panel end
        end
        assert(form.frame and form.done and form.later and form.folder, "Missing original setup controls")
        equal(#entries, 3, "Keep the name, delay and filename inputs")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        form.inputs = {form.name, form.delay, form.file}
        form.controls = {form.name, form.delay, form.folder, form.file, form.later, form.done}
        function form:fill(folder, name, delay, file)
            self.name:SetText(name or "  Alpha  ")
            self.delay:SetText(delay or "2.5")
            self.folder.selected = folder or "data"
            self.file:SetText(file or "  Secret  ")
        end
        return form
    end
    local function open(client, packet)
        local first = #client.panels + 1
        deliver(client, packet)
        return formSince(client, first)
    end
    local function fixture(width, height, deferredNative)
        local server, client = gmod.new(), clientAt(width or 640, height or 480, deferredNative)
        local owner = server.player()
        local console = server.console(owner)
        local opening = assert(server.lastMessage("PlayerSpawnedConsole"))
        equal(opening.player, owner); equal(#opening.values, 2, "Existing opening payload stays unchanged")
        return {server = server, client = client, owner = owner, console = console,
            form = open(client, opening), opening = opening}
    end
    local function unlocked(form)
        equal(live(form.frame), true, "Rejected draft remains visible")
        equal(form.done.enabled, true); equal(form.folder.enabled, true)
        for _, input in ipairs(form.inputs) do equal(input.editable, true) end
        equal(form.later.text, "Set up later")
    end
    local function pending(form)
        equal(live(form.frame), true, "Done must retain the visible draft until acknowledgement")
        equal(form.done.enabled, false); equal(form.folder.enabled, false)
        for _, input in ipairs(form.inputs) do equal(input.editable, false) end
        equal(form.later.text, "Close", "Pending dismissal does not promise deferral")
        assert(form.status and live(form.status), "Pending state needs a visible explanation")
        local text = form.status.text:lower()
        assert(text:find("clos", 1, true) and text:find("undo", 1, true),
            "Pending notice must explain that closing cannot undo setup")
    end
    local function submit(session, form, console)
        form, console = form or session.form, console or session.console
        local count = #session.client.messages
        local draft = {form.name:GetValue(), tonumber(form.delay:GetValue()), form.folder:GetSelected(),
            form.file:GetValue(), console:GetName()}
        form.done:DoClick()
        pending(form)
        equal(#session.client.messages, count + 1, "One Done sends only its configuration request")
        local packet = assert(session.client.lastMessage("AdminFinishedCreation"))
        equal(#packet.values, 1); equal(#packet.values[1], 6)
        for i = 1, 5 do equal(packet.values[1][i], draft[i], "Legacy setup field " .. i) end
        local token = packet.values[1][6]
        assert(type(token) == "string" and #token <= 16 and token:match("^[1-9]%d*$"), "Canonical request token")
        assert(tonumber(token) <= 9007199254740991, "Exact bounded token")
        equal(session.client.lastMessage("ServerWaitingForEntity"), nil, "No obsolete pending-selection packet")
        form.done:DoClick()
        equal(#session.client.messages, count + 1, "Repeated pending Done is harmless")
        return packet
    end
    local function response(session, packet, accepted, sender)
        sender = sender or session.owner
        local count = #session.server.messages
        relay(session.server, sender, packet)
        equal(#session.server.messages, count + 1, "A correlated submission receives exactly one reply")
        local reply = assert(session.server.lastMessage(replyName))
        equal(reply.player, sender, "Only the authenticated sender receives this reply")
        equal(#reply.values, 2); equal(reply.values[1], packet.values[1][6])
        equal(reply.values[2].ok, accepted)
        if not accepted then assert(type(reply.values[2].message) == "string" and reply.values[2].message ~= "") end
        return reply
    end
    local function registered(server, console)
        local count = 0
        for _, entry in ipairs(server.returnSpawnedEntities()) do
            if entry.entity == console then
                count = count + 1
                equal(entry.entityName, console:GetName()); equal(entry.information, console.SlicerInformation)
            end
        end
        equal(count, 1, "One first-write registry entry")
    end
    local function chatSince(owner, first)
        local text = {}
        for i = first + 1, #owner.chats do text[#text + 1] = owner.chats[i] end
        return table.concat(text, "\n")
    end
    local function guidance(owner, first, name)
        local text = chatSince(owner, first)
        assert(text:find(name, 1, true), "Guidance must identify the accepted normalized console")
        local firstCommand = assert(text:find("!setEntity", 1, true), "First explicitly select the console")
        local nextCommand = assert(text:find("!setEntity", firstCommand + 1, true), "Then explicitly select its intended door")
        assert(text:sub(1, firstCommand):lower():find("console", 1, true), "Console selection precedes the first command")
        assert(text:sub(firstCommand + 1, nextCommand):lower():find("door", 1, true), "Door selection follows console selection")
        return text
    end
    local function select(server, owner, target)
        owner.target = target
        server.fire("PlayerSay", owner, "!setEntity")
    end
    local function configured(server, owner, folder, name)
        local console = server.console(owner)
        server.receive("AdminFinishedCreation", owner, {name or "Beta", 2, folder or "tools", "Other", console:GetName()})
        assert(console.SlicerInformation, "Legacy five-field setup remains supported")
        return console
    end

    for _, when in ipairs({"before Done", "in flight"}) do
        test("removed Alpha " .. when .. " retains its draft without misdirecting pending Beta", function()
            local session = fixture()
            local server, client, owner, alpha, form = session.server, session.client, session.owner, session.console, session.form
            local linked = configured(server, owner, "tools", "Already Linked")
            local linkedDoor, intendedDoor = server.entity("func_door_rotating"), server.entity("func_door")
            select(server, owner, linked); select(server, owner, linkedDoor)
            local beta = configured(server, owner, "tools", "Beta")
            local betaInfo, linkedInfo = beta.SlicerInformation, linked.SlicerInformation
            form:fill("tools")
            local chats, count = #owner.chats, #server.returnSpawnedEntities()
            if when == "before Done" then alpha:Remove() end
            local packet = submit(session)
            equal(#owner.chats, chats, "Pending tools setup gives no premature linking guidance")
            if when == "in flight" then alpha:Remove() end
            local rejection = response(session, packet, false)
            equal(alpha.SlicerInformation, nil); equal(owner.SlicerPendingConsole, beta)
            equal(beta.SlicerInformation, betaInfo); equal(beta.SlicerDoor, nil)
            equal(linked.SlicerInformation, linkedInfo); equal(linked.SlicerDoor, linkedDoor)
            equal(#server.returnSpawnedEntities(), count)
            equal(#intendedDoor.inputs, 0); equal(#linkedDoor.inputs, 1); equal(linkedDoor.inputs[1], "Lock")
            deliver(client, rejection)
            unlocked(form)
            equal(form.name:GetValue(), "  Alpha  "); equal(form.delay:GetValue(), "2.5")
            equal(form.file:GetValue(), "  Secret  "); equal(form.folder:GetSelected(), "tools")
            equal(form.status.text, rejection.values[2].message, "The actual rejection is visible with the retained draft")
            assert(not chatSince(owner, chats):find("!setEntity", 1, true), "Rejection cannot tell the creator to link Beta")
            equal(owner.SlicerPendingConsole, beta); equal(beta.SlicerDoor, nil); equal(#intendedDoor.inputs, 0)
            local before = #client.messages
            form.later:DoClick()
            equal(#client.messages, before, "Rejected setup dismissal sends no hack quit or cancellation")
        end)
    end

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " initial setup closes on acceptance and completes through ordinary callbacks", function()
            local session = fixture()
            local server, client, owner, console, form = session.server, session.client, session.owner, session.console, session.form
            form:fill(kind.folder)
            local chats = #owner.chats
            local packet = submit(session)
            equal(#owner.chats, chats)
            local accepted = response(session, packet, true)
            pending(form)
            equal(accepted.values[2].name, "alpha"); equal(accepted.values[2].fileType, kind.folder)
            equal(console.SlicerInformation.name, "alpha"); equal(console.SlicerInformation.fileName, "secret")
            equal(console.SlicerInformation.delay, 2.5); equal(console.SlicerInformation.fileType, kind.folder)
            registered(server, console)
            deliver(client, accepted)
            equal(live(form.frame), false)
            local acceptedChats = #owner.chats
            if kind.folder == "tools" then guidance(owner, chats, "alpha") else equal(acceptedChats, chats) end
            deliver(client, accepted); form.done:DoClick(); form.later:DoClick()
            equal(#owner.chats, acceptedChats, "Duplicate acknowledgements cannot repeat success guidance")
            equal(#client.messages, 1, "Retired setup actions send nothing")
            local current = console.SlicerInformation
            local duplicate = response(session, packet, false)
            equal(console.SlicerInformation, current, "A duplicate request cannot overwrite first-write setup")
            deliver(client, duplicate); equal(#owner.chats, acceptedChats)
            registered(server, console)
            local door
            if kind.folder == "tools" then
                door = server.entity("func_door_rotating")
                select(server, owner, console); select(server, owner, door)
                equal(console.SlicerDoor, door); equal(door.inputs[1], "Lock")
            end
            local hacker = server.player()
            server.open(hacker, console); deliver(client, server.lastMessage("ServerSendsEntityInformation"))
            client.command("/a[alpha]")
            equal(client.timers.AccessDelay.delay, 2.5)
            client.fireTimer("AccessDelay"); server.now = 2.5
            client.command("/a[alpha]/{_" .. kind.folder .. "}")
            client.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension)
            if kind.timer then client.fireTimer(kind.timer); server.now = 5 end
            relay(server, hacker, client.lastMessage(kind.complete))
            equal(console.removed, true)
            if door then equal(door.inputs[#door.inputs], "Unlock") end
            deliver(client, server.lastMessage("SlicerCompleted"))
            client.assertClosed()
        end)
    end

    test("accepted Alpha guidance reselects Alpha after pending selection changes to Beta", function()
        local session = fixture()
        local server, client, owner, alpha = session.server, session.client, session.owner, session.console
        local beta = configured(server, owner, "tools", "Beta")
        session.form:fill("tools")
        local request = submit(session)
        local accepted = response(session, request, true)
        equal(owner.SlicerPendingConsole, alpha)
        select(server, owner, beta)
        equal(owner.SlicerPendingConsole, beta)
        local chats = #owner.chats
        deliver(client, accepted)
        guidance(owner, chats, "alpha")
        equal(owner.SlicerPendingConsole, beta, "Client acknowledgement itself never mutates server selection")
        local door = server.entity("func_door_rotating")
        select(server, owner, alpha); select(server, owner, door)
        equal(alpha.SlicerDoor, door); equal(beta.SlicerDoor, nil)
        equal(door.inputs[1], "Lock"); equal(#door.inputs, 1)
    end)

    test("independent initial forms survive reordered and duplicate success replies", function()
        local session = fixture()
        local server, client, owner, alpha = session.server, session.client, session.owner, session.console
        local beta = server.console(owner)
        local betaForm = open(client, server.lastMessage("PlayerSpawnedConsole"))
        session.form:fill("tools", "Alpha"); betaForm:fill("tools", "Beta")
        local alphaRequest, betaRequest = submit(session), submit(session, betaForm, beta)
        assert(alphaRequest.values[1][6] ~= betaRequest.values[1][6], "Simultaneous forms have distinct submission identities")
        local alphaReply = response(session, alphaRequest, true)
        local betaReply = response(session, betaRequest, true)
        local chats = #owner.chats
        deliver(client, betaReply)
        equal(live(betaForm.frame), false); pending(session.form)
        guidance(owner, chats, "beta")
        chats = #owner.chats
        deliver(client, betaReply); equal(#owner.chats, chats); pending(session.form)
        deliver(client, alphaReply)
        equal(live(session.form.frame), false); guidance(owner, chats, "alpha")
        equal(owner.SlicerPendingConsole, beta, "Out-of-order acknowledgements do not reorder server selection")
        registered(server, alpha); registered(server, beta)
    end)

    test("rejection retry ignores stale replies and reads the latest focused draft", function()
        local session = fixture()
        local form, client = session.form, session.client
        form:fill("server", "First draft", "3", "First file")
        local first = submit(session)
        first.values[1][2] = 0 -- Invalid only at the server transport boundary.
        local rejected = response(session, first, false)
        deliver(client, rejected); unlocked(form)
        equal(form.delay:GetValue(), "3", "Server rejection does not rewrite the visible draft")
        form:fill("server", "  Latest name  ", "4.25", "  Latest file  ")
        form.file:RequestFocus() -- No OnLoseFocus is delivered before Done.
        local second = submit(session)
        assert(first.values[1][6] ~= second.values[1][6], "Retry gets a new exact request identity")
        deliver(client, rejected); pending(form)
        local accepted = response(session, second, true)
        deliver(client, accepted)
        equal(live(form.frame), false)
        equal(session.console.SlicerInformation.name, "latest name")
        equal(session.console.SlicerInformation.delay, 4.25)
        equal(session.console.SlicerInformation.fileName, "latest file")
        registered(session.server, session.console)
    end)

    test("repeated Use preserves a pending setup and its immutable submitted packet", function()
        local session = fixture()
        local server, client, form = session.server, session.client, session.form
        form:fill("data")
        local packet = submit(session)
        local count, popups = #client.panels, form.frame.popupCalls
        server.open(session.owner, session.console)
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        equal(#client.panels, count); equal(form.frame.popupCalls, popups + 1)
        pending(form); equal(form.name:GetValue(), "  Alpha  ")
        -- A retained addon callback can still SetText on a readonly native
        -- control; it must not rewrite the already transmitted snapshot.
        form.name:SetText("Changed after submit")
        equal(packet.values[1][1], "  Alpha  ")
        local accepted = response(session, packet, true)
        deliver(client, accepted)
        equal(session.console.SlicerInformation.name, "alpha")
        equal(live(form.frame), false)
    end)

    for _, retirement in ipairs({"Close", "Remove"}) do
        for _, outcome in ipairs({"accept", "reject"}) do
            test("native delayed " .. retirement .. " isolates old " .. outcome .. " replies from a replacement", function()
                local session = fixture(640, 480, true)
                local server, client, owner, console, old = session.server, session.client, session.owner, session.console, session.form
                old:fill("tools", "Old draft")
                local oldRequest = submit(session)
                local savedDone, savedLater = old.done.DoClick, old.later.DoClick
                old.frame[retirement](old.frame)
                assert(old.frame.valid, "Native lifecycle callbacks have not run")
                -- A native hidden frame can be shown again before OnClose.
                -- The synchronous retirement wrapper must still make it inert.
                if retirement == "Close" then old.frame:Show() end
                local count = #client.messages
                savedDone(); savedLater()
                equal(#client.messages, count)
                server.open(owner, console)
                local fresh = open(client, server.lastMessage("PlayerSpawnedConsole"))
                fresh:fill("server", "Replacement draft", "6", "Replacement file")
                local freshRequest = submit(session, fresh)
                if outcome == "reject" then oldRequest.values[1][2] = 0 end
                local oldReply = response(session, oldRequest, outcome == "accept")
                local freshReply = response(session, freshRequest, outcome ~= "accept")
                local chats = #owner.chats
                deliver(client, oldReply)
                pending(fresh)
                equal(#owner.chats, chats, "Retired tools form must not give late success guidance")
                if old.frame.OnClose then old.frame:OnClose() end
                if old.frame.OnRemove then old.frame:OnRemove() end
                savedDone(); savedLater()
                equal(#client.messages, count + 1, "Delayed callbacks cannot send on a replacement")
                deliver(client, freshReply)
                if outcome == "accept" then
                    unlocked(fresh)
                    equal(console.SlicerInformation.name, "old draft", "Closing does not cancel an accepted in-flight commit")
                    equal(fresh.name:GetValue(), "Replacement draft")
                else
                    equal(live(fresh.frame), false)
                    equal(console.SlicerInformation.name, "replacement draft")
                end
                deliver(client, oldReply); equal(#owner.chats, chats)
                registered(server, console)
            end)
        end
    end

    local function pasteUnconfigured(server, original, owner)
        local data = {Name = original:GetName(), SlicerCreator = original.SlicerCreator}
        original:OnEntityCopyTableFinish(data)
        local copy = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        copy:Initialize(); copy:SetName(data.Name); copy.SlicerCreator = data.SlicerCreator
        copy:OnDuplicated(data); copy:PostEntityPaste(owner, copy, {})
        return copy
    end
    for _, path in ipairs({"deferred", "unconfigured copy"}) do
        test(path .. " setup still uses creator Use and acknowledged first-write configuration", function()
            local session = fixture()
            local server, client, oldOwner, original = session.server, session.client, session.owner, session.console
            session.form:fill("tools", "Discarded")
            session.form.later:DoClick()
            equal(#client.messages, 0); equal(original.SlicerInformation, nil)
            if path == "unconfigured copy" then
                session.owner = server.player()
                session.console = pasteUnconfigured(server, original, session.owner)
                assert(session.console:GetName() ~= original:GetName())
                equal(session.console.SlicerCreator, session.owner)
            end
            local count = #server.messages
            server.open(path == "unconfigured copy" and oldOwner or server.player(), session.console)
            equal(#server.messages, count, "Only this console's creator can reopen initial setup")
            session.owner.weapon = nil
            server.open(session.owner, session.console)
            local opening = assert(server.lastMessage("PlayerSpawnedConsole"))
            equal(opening.player, session.owner); equal(opening.values[2], session.console:GetName())
            local fresh = open(client, opening)
            equal(fresh.name:GetValue(), ""); equal(fresh.file:GetValue(), "")
            fresh:fill("data", "Fresh", "2", "Fresh file")
            local packet = submit(session, fresh)
            local accepted = response(session, packet, true)
            equal(live(fresh.frame), true)
            deliver(client, accepted); equal(live(fresh.frame), false)
            equal(session.console.SlicerInformation.name, "fresh")
            if path == "unconfigured copy" then equal(original.SlicerInformation, nil); equal(original.SlicerCreator, oldOwner) end
            registered(server, session.console)
        end)
    end

    for _, outcome in ipairs({"accepted", "rejected", "closed pending"}) do
        test(outcome .. " initial setup preserves an unrelated active hack, countdown and help", function()
            local session = fixture()
            local server, client, owner = session.server, session.client, session.owner
            local beta = configured(server, owner, "tools", "Beta")
            local active = configured(server, owner, "data", "Active")
            server.open(owner, active); deliver(client, server.lastMessage("ServerSendsEntityInformation"))
            client.command("/a[active]")
            local timer = assert(client.timers.AccessDelay)
            local helpButton
            for _, panel in ipairs(client.panels) do
                if live(panel) and panel.class == "DButton" and panel.text == "Commands (/help)" then helpButton = panel end
            end
            assert(helpButton):DoClick()
            local helpFrame
            for _, panel in ipairs(client.panels) do
                if live(panel) and panel.class == "DFrame" and panel ~= session.form.frame then helpFrame = panel end
            end
            assert(helpFrame, "Active command help is open")
            session.form:fill("server")
            local packet = submit(session)
            if outcome == "rejected" then session.console:Remove() end
            local reply = response(session, packet, outcome ~= "rejected")
            if outcome == "closed pending" then session.form.later:DoClick() end
            deliver(client, reply)
            equal(active.SlicerInformation.inUse, true); equal(client.timers.AccessDelay, timer)
            equal(live(helpFrame), true); equal(owner.SlicerPendingConsole, beta)
            equal(client.lastMessage("playerQuitConsole"), nil, "Initial setup never quits another active hack")
            if outcome == "rejected" then unlocked(session.form); session.form.later:DoClick() end
            client.fireTimer("AccessDelay")
            client.command("/a[active]/{_data}"); client.command("/d{_data}/other.data")
            client.fireTimer("DownloadDataFile"); server.now = 4
            relay(server, owner, client.lastMessage("destroyOnServer"))
            equal(active.removed, true, "The unrelated reserved hack still completes")
            equal(owner.SlicerPendingConsole, beta); equal(beta.SlicerDoor, nil)
            deliver(client, server.lastMessage("SlicerCompleted")); client.assertClosed()
        end)
    end

    for _, size in ipairs({{640, 480}, {800, 600}, {1920, 1080}}) do
        test("initial acknowledgement status and original controls fit at " .. size[1] .. "x" .. size[2], function()
            local session = fixture(size[1], size[2])
            local form = session.form
            assert(form.status and form.status.height > 0, "Dedicated visible status area")
            local previous
            for _, panel in ipairs(form.controls) do
                equal(panel.parent, form.frame); assert(live(panel))
                assert(panel.height >= 48, "Original controls retain readable heights")
                assert(panel.width > 0 and panel.width <= 400)
                assert(panel.x >= 20 and panel.x + panel.width <= size[1] - 20)
                assert(panel.y >= 20 and panel.y + panel.height <= size[2] - 20)
                if previous then assert(panel.y >= previous.y + previous.height + 12, "Controls do not overlap") end
                previous = panel
            end
            assert(form.status.y >= form.done.y + form.done.height + 12, "Status does not cover Done")
            assert(form.status.y + form.status.height <= size[2] - 20, "Status fits below all controls")
            assert(form.status.x >= 20 and form.status.x + form.status.width <= size[1] - 20)
            form:fill("server")
            local packet = submit(session)
            packet.values[1][2] = 0
            local rejected = response(session, packet, false)
            deliver(session.client, rejected); unlocked(form)
            equal(form.status.text, rejected.values[2].message)
        end)
    end
end

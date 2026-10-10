-- Exercise the real private chat hook, server reservations and client cleanup.
-- Chat accessibility/privacy, packet timing and brush-door I/O still need GMod.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", message = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", message = "destroyOnServer"},
        {folder = "tools", extension = "exe", message = "PlayerActivatedDoor"},
    }
    local function count(env, name)
        local total = 0
        for _, packet in ipairs(env.messages) do if packet.name == name then total = total + 1 end end
        return total
    end
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, player, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, player, unpackValues(packet.values))
    end
    local function entry(client)
        for index = #client.panels, 1, -1 do
            local panel, live = client.panels[index], true
            local ancestor = panel
            while ancestor do
                if not ancestor.valid or ancestor:IsMarkedForDeletion() or not ancestor:IsVisible() then live = false end
                ancestor = ancestor.parent
            end
            if live and panel.OnEnter then return panel end
        end
        error("Missing live terminal input")
    end
    local function button(page, text)
        for _, child in ipairs(page.children) do
            if child.class == "DButton" and child.text == text then return child end
        end
        error("Missing " .. text .. " button")
    end
    local function open(server, client, player, console)
        local before = count(server, "ServerSendsEntityInformation")
        server.open(player, console)
        equal(count(server, "ServerSendsEntityInformation"), before + 1)
        local packet = server.lastMessage("ServerSendsEntityInformation")
        equal(packet.player, player); equal(packet.values[1], console)
        deliver(client, packet)
    end
    local function link(server, owner, console, class)
        owner.target = console; equal(server.fire("PlayerSay", owner, "!setEntity"), "")
        local door = server.entity(class)
        owner.target = door; equal(server.fire("PlayerSay", owner, "!setEntity"), "")
        equal(console.SlicerDoor, door); equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
        return door
    end
    local function fixture(kind, class)
        local server, client = gmod.new(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local info = assert(server.configure(owner, console, kind.folder, 2))
        local door = kind.folder == "tools" and link(server, owner, console, class or "func_door") or nil
        open(server, client, hacker, console)
        return server, client, owner, hacker, console, info, door
    end
    local function visit(client, stage)
        if stage ~= "login" then
            client.command("/a[terminal]"); client.fireTimer("AccessDelay")
            client.command("/a[terminal]/{_" .. stage .. "}")
        end
        return entry(client)
    end
    local function action(kind)
        return (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension
    end
    local function recover(server, hacker, info)
        local before, chats, otherChats = #server.messages, #hacker.chats, {}
        for _, entity in ipairs(server.entities) do
            if entity:IsPlayer() and entity ~= hacker then otherChats[entity] = #entity.chats end
        end
        local result = server.fire("PlayerSay", hacker, "!quitConsole")
        equal(info.inUse, false, "Chat recovery must release the caller's reservation")
        equal(result, "", "Exact recovery command must remain private")
        equal(#server.messages, before + 1)
        local packet = server.messages[#server.messages]
        equal(packet.name, "PlayerDied"); equal(packet.player, hacker); equal(#packet.values, 0)
        equal(#hacker.chats, chats + 1)
        local notice = hacker.chats[#hacker.chats]
        assert(#notice > 0 and #notice <= 255, "Recovery needs one bounded private notice")
        assert(not notice:find("[%z\1-\31\127]"), "Recovery notice contains control characters")
        for other, prior in pairs(otherChats) do equal(#other.chats, prior, "Recovery leaked another player's chat") end
        return packet
    end
    local function noCompletion(server, client, console, door)
        equal(console.valid, true); equal(console.removed, nil)
        equal(server.lastMessage("SlicerCompleted"), nil)
        equal(client.lastMessage("destroyOnServer"), nil); equal(client.lastMessage("PlayerActivatedDoor"), nil)
        equal(#client.chatMessages, 0)
        if door then equal(#door.inputs, 1); equal(door.inputs[1], "Lock") end
    end
    local function unchanged(tableValue)
        local fields = {}; for key, value in pairs(tableValue) do fields[key] = value end
        return function()
            for key, value in pairs(fields) do equal(tableValue[key], value, "Changed field " .. tostring(key)) end
            for key, value in pairs(tableValue) do equal(value, fields[key], "Added field " .. tostring(key)) end
        end
    end
    -- Read-only state access follows link-reset.lua; no production seam is added.
    local function upvalue(callback, wanted)
        local index = 1
        while true do
            local name, value = debug.getupvalue(callback, index)
            if not name then error("Missing server state: " .. wanted) end
            if name == wanted then return value end
            index = index + 1
        end
    end

    for _, kind in ipairs(kinds) do
        test("chat recovery releases a missing " .. kind.folder .. " page and preserves the console", function()
            local server, client, owner, hacker, console, info, door = fixture(kind)
            local input = visit(client, kind.folder)
            local quit = button(input.parent, "Quit terminal")
            button(input.parent, "Commands (/help)"):DoClick()
            input.parent:Remove(); quit:DoClick()
            equal(count(client, "playerQuitConsole"), 0); equal(info.inUse, true)
            local saved = {info.name, info.delay, info.fileType, info.fileName}
            local entityUnchanged, registryUnchanged = unchanged(console), unchanged(server.returnSpawnedEntities())
            deliver(client, recover(server, hacker, info))
            equal(server.slicerConsoleHasActiveSession(console), false); client.assertClosed()
            entityUnchanged(); registryUnchanged(); equal(console.SlicerInformation, info)
            equal(info.name, saved[1]); equal(info.delay, saved[2]); equal(info.fileType, saved[3]); equal(info.fileName, saved[4])
            server.now = 100
            server.receive("destroyOnServer", hacker, console); server.receive("PlayerActivatedDoor", hacker, console)
            noCompletion(server, client, console, door)
            if door then equal(server.fire("PlayerUse", owner, door), false, "Recovery must retain the registered lock") end
            local nextPlayer = server.player(); open(server, client, nextPlayer, console)
            equal(info.inUse, true)
        end)
    end

    for _, countdown in ipairs({
        {kind = kinds[1], stage = "login", timer = "AccessDelay", think = "printDelay", command = "/a[terminal]"},
        {kind = kinds[1], stage = "data", timer = "DownloadDataFile", think = "downloadDataFile", command = action(kinds[1])},
        {kind = kinds[2], stage = "server", timer = "DownloadServerFile", think = "downloadServerFile", command = action(kinds[2])},
    }) do
        for _, afterThink in ipairs({false, true}) do
            test("chat recovery cancels " .. countdown.timer .. (afterThink and " after" or " before") .. " first Think", function()
                local server, client, _, hacker, console, info, door = fixture(countdown.kind)
                local input = visit(client, countdown.stage)
                client.command(countdown.command)
                local retained = assert(client.timers[countdown.timer]).callback
                local retainedThink = assert(client.hooks.Think[countdown.think])
                if afterThink then client.fire("Think") end
                button(input.parent, "Commands (/help)"):DoClick()
                local quit = button(input.parent, "Quit terminal")
                deliver(client, recover(server, hacker, info)); client.assertClosed()
                retained(); input:OnEnter(); quit:DoClick(); client.fire("Think"); client.assertClosed()
                noCompletion(server, client, console, door)
                local before = #server.messages
                equal(server.fire("PlayerSay", hacker, "!quitConsole"), "")
                equal(#server.messages, before, "Repeated recovery must not send cleanup")
                equal(count(server, "PlayerDied"), 1)
                server.now = 20; open(server, client, hacker, console)
                local current = visit(client, countdown.stage)
                client.command(countdown.command)
                local pending, currentThink = client.timers[countdown.timer], client.hooks.Think[countdown.think]
                local session = upvalue(server.slicerConsoleHasActiveSession, "sessions")[hacker]
                local sessionUnchanged = unchanged(session)
                local sent, events, panels = #client.messages, #client.timerEvents, #client.panels
                retained(); retainedThink(); input:OnEnter(); quit:DoClick()
                equal(#client.messages, sent); equal(#client.timerEvents, events); equal(#client.panels, panels)
                equal(entry(client), current); equal(client.timers[countdown.timer], pending)
                equal(client.hooks.Think[countdown.think], currentThink); sessionUnchanged()
                equal(upvalue(server.slicerConsoleHasActiveSession, "sessions")[hacker], session); equal(info.inUse, true)
                noCompletion(server, client, console, door)
                deliver(client, recover(server, hacker, info)); client.assertClosed()
            end)
        end
    end

    for _, kind in ipairs(kinds) do
        for _, atDeadline in ipairs({false, true}) do
            test("recovered " .. kind.folder .. " restarts its deadline " .. (atDeadline and "at" or "before") .. " completion", function()
                local server, client, _, hacker, console, info, door = fixture(kind, "func_door_rotating")
                server.now = 10; deliver(client, recover(server, hacker, info))
                server.now = 20; open(server, client, hacker, console)
                visit(client, kind.folder); client.command(action(kind))
                if kind.timer then client.fireTimer(kind.timer) end
                local packet = assert(client.lastMessage(kind.message))
                server.now = 20 + 2 * (kind.timer and 2 or 1) - (atDeadline and 0 or 0.001)
                relay(server, hacker, packet)
                equal(info.inUse, false)
                equal(console.removed, atDeadline and true or nil)
                equal(count(server, "SlicerCompleted"), atDeadline and 1 or 0)
                if door then equal(#door.inputs, atDeadline and 2 or 1); equal(door.inputs[#door.inputs], atDeadline and "Unlock" or "Lock") end
                deliver(client, server.lastMessage(atDeadline and "SlicerCompleted" or "PlayerDied")); client.assertClosed()
                equal(#client.chatMessages, atDeadline and 1 or 0)
                local before = #server.messages; relay(server, hacker, packet); equal(#server.messages, before)
            end)
        end
    end

    test("idle and repeated recovery stay private without sending cleanup", function()
        local server, client = gmod.new(), gmod.client()
        local owner, observer = server.player(), server.player()
        server.console(owner); deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        local first, messages, chats = client.panels[1], #server.messages, #owner.chats
        for attempt = 1, 2 do
            equal(server.fire("PlayerSay", owner, "!quitConsole"), "")
            equal(#server.messages, messages); equal(#owner.chats, chats + attempt)
            assert(#owner.chats[#owner.chats] > 0 and #owner.chats[#owner.chats] <= 255)
            equal(first.valid, true, "Idle recovery must preserve unrelated setup")
        end
        equal(#observer.chats, 0); equal(count(server, "PlayerDied"), 0)
    end)

    test("nonparticipant cannot release another hack or receive an own-session hint", function()
        local server, client, owner, hacker, console, info = fixture(kinds[1])
        local before = #server.messages
        server.open(owner, console)
        assert(not owner.chats[#owner.chats]:find("!quitConsole", 1, true), "Another player's busy console must not suggest self recovery")
        equal(server.fire("PlayerSay", owner, "!quitConsole"), "")
        equal(#server.messages, before); equal(info.inUse, true)
        equal(server.slicerConsoleHasActiveSession(console), true)
        server.open(hacker, console)
        assert(hacker.chats[#hacker.chats]:find("!quitConsole", 1, true), "Own reservation must offer recovery")
        local other = server.console(owner); server.configure(owner, other)
        server.open(hacker, other)
        assert(hacker.chats[#hacker.chats]:find("!quitConsole", 1, true), "Own session also blocks a different console")
        equal(other.SlicerInformation.inUse, false)
        visit(client, "data"); client.command(action(kinds[1])); client.fireTimer("DownloadDataFile")
        server.now = 4; relay(server, hacker, client.lastMessage("destroyOnServer"))
        equal(console.removed, true); equal(count(server, "SlicerCompleted"), 1)
        deliver(client, server.lastMessage("SlicerCompleted")); client.assertClosed()
    end)

    test("recovery requires neither an equipped tool nor a target and releases only the caller", function()
        local server, client, owner, hacker, console, info = fixture(kinds[3], "func_door_rotating")
        local other = server.console(owner); server.configure(owner, other)
        local rival = server.player(); server.open(rival, other)
        local session = upvalue(server.slicerConsoleHasActiveSession, "sessions")[rival]
        local sessionUnchanged = unchanged(session)
        hacker.weapon, hacker.target = nil, nil
        hacker.GetActiveWeapon = function() error("Recovery must not query the weapon") end
        hacker.GetEyeTrace = function() error("Recovery must not trace a target") end
        deliver(client, recover(server, hacker, info)); client.assertClosed(); sessionUnchanged()
        equal(upvalue(server.slicerConsoleHasActiveSession, "sessions")[rival], session)
        equal(other.SlicerInformation.inUse, true); equal(console.removed, nil)
        equal(console.SlicerDoor.inputs[#console.SlicerDoor.inputs], "Lock")
    end)

    test("recovery preserves pending links, setup/edit drafts, listing/marker and another session", function()
        local server, client = support.server(), support.client()
        local owner, rival = server.player(), server.player()
        local active, editable, pending = server.console(owner), server.console(owner), server.console(owner)
        server.configure(owner, active); server.configure(owner, editable, "server"); server.configure(owner, pending, "tools")
        local other = server.console(rival); server.configure(rival, other, "tools")
        local door = link(server, rival, other, "func_door")
        server.now = 10; open(server, client, owner, active); server.open(rival, other)
        local function form(packet, editing)
            local first, result, fields = #client.panels + 1, {}, {}; deliver(client, packet)
            for index = first, #client.panels do
                local panel = client.panels[index]
                if panel.class == "DFrame" then result.frame = panel
                elseif panel.class == "DTextEntry" then fields[#fields + 1] = panel
                elseif panel.class == "DComboBox" then result.folder = panel
                elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then result.submit = panel end
            end
            equal(#fields, 3); result.name, result.delay, result.file = fields[1], fields[2], fields[3]
            result.name:SetText(editing and "Edited" or "Deferred"); result.delay:SetText("3"); result.file:SetText("Retained")
            if result.folder then result.folder.selected = "data" end
            return result
        end
        owner.target = editable; server.fire("PlayerSay", owner, "!editConsole")
        local editOpen = server.lastMessage("SlicerSetupEditOpen")
        local editing = form(editOpen, true)
        local deferred = server.console(owner)
        local initial = form(server.lastMessage("PlayerSpawnedConsole"))
        server.fire("PlayerSay", owner, "!listConsoles"); server.fire("PlayerSay", owner, "!locateConsole 2")
        support.deliver(client, server.lastMessage("SlicerConsoleLocation"))
        local marker = client.paint(); assert(marker:find("Location snapshot", 1, true))
        local sessions = upvalue(server.slicerConsoleHasActiveSession, "sessions")
        local otherSession = sessions[rival]
        local sessionUnchanged = unchanged(otherSession)
        local tickets = upvalue(server.retireSlicerSetupEdit, "editTickets")
        local ticketsUnchanged, ticketUnchanged = unchanged(tickets), unchanged(tickets[editable])
        local listings = upvalue(server.hooks.PlayerSay.slicerLocateConsole, "consoleListings")
        local listingsUnchanged, listingUnchanged = unchanged(listings), unchanged(listings[owner])
        local links = upvalue(server.hooks.PlayerUse.isUsingOurObject, "linkedDoors")
        local linksUnchanged, serial = unchanged(links), server.slicerSetupEditSerial
        deliver(client, recover(server, owner, active.SlicerInformation))
        sessionUnchanged(); ticketsUnchanged(); ticketUnchanged(); listingsUnchanged(); listingUnchanged(); linksUnchanged()
        equal(sessions[rival], otherSession); equal(otherSession.completeAt, 12); equal(other.SlicerInformation.inUse, true)
        equal(owner.SlicerPendingConsole, pending); equal(server.slicerSetupEditSerial, serial)
        equal(client.paint(), marker); equal(editing.frame.valid, true); equal(initial.frame.valid, true)
        equal(editing.name:GetValue(), "Edited"); equal(initial.name:GetValue(), "Deferred")
        equal(initial.delay:GetValue(), "3"); equal(initial.file:GetValue(), "Retained"); equal(initial.folder.selected, "data")
        equal(editing.delay:GetValue(), "3"); equal(editing.file:GetValue(), "Retained")
        local before = count(server, "SlicerConsoleLocation"); server.fire("PlayerSay", owner, "!locateConsole 2")
        equal(count(server, "SlicerConsoleLocation"), before + 1)
        editing.submit:DoClick(); relay(server, owner, client.lastMessage("SlicerSetupEditSave"))
        local reply = server.lastMessage("SlicerSetupEditReply"); equal(reply.values[1], editOpen.values[3]); equal(reply.values[2].ok, true)
        deliver(client, reply); equal(editing.frame.valid, false)
        initial.submit:DoClick(); relay(server, owner, client.lastMessage("AdminFinishedCreation"))
        reply = server.lastMessage("SlicerInitialSetupReply"); equal(reply.values[2].ok, true); deliver(client, reply)
        equal(deferred.SlicerInformation.name, "deferred"); equal(owner.SlicerPendingConsole, pending)
        server.now = 12; server.receive("PlayerActivatedDoor", rival, other)
        equal(other.removed, true); equal(#door.inputs, 2); equal(door.inputs[2], "Unlock")
        equal(active.valid, true); equal(active.SlicerInformation.inUse, false)
    end)

    test("recovery matches only exact text from a valid living player", function()
        for _, case in ipairs({
            {text = "!QUITCONSOLE"}, {text = " !quitConsole"}, {text = "!quitConsole "},
            {text = "!quitConsole 1"}, {text = "ordinary chat"},
            {text = "!quitConsole", actor = "invalid"}, {text = "!quitConsole", actor = "nonplayer"},
            {text = "!quitConsole", actor = "dead"}, {text = "!quitConsole", active = true},
        }) do
            local server, _, _, hacker, console, info = fixture(kinds[1])
            local actor = hacker
            if case.actor == "invalid" then hacker.valid = false
            elseif case.actor == "nonplayer" then actor = server.entity("prop_physics")
            elseif case.actor == "dead" then hacker.alive = false end
            local before, chats = #server.messages, #hacker.chats
            local result = server.fire("PlayerSay", actor, case.text)
            equal(result, case.text == "!quitConsole" and "" or nil)
            equal(info.inUse, not case.active)
            equal(server.slicerConsoleHasActiveSession(console), not case.active)
            equal(#server.messages, before + (case.active and 1 or 0))
            equal(#hacker.chats, chats + (case.active and 1 or 0))
        end
    end)
end

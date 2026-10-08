-- Drive the real setup, chat, editor, copy and hacking callbacks through the
-- existing doubles. Link/session/ticket tables are deliberately not inspected
-- or recreated: their authority is checked through later observable actions.
-- Native eye traces, chat recipients, duplicator dispatch and brush-door
-- engine/protection-addon behavior still require a Garry's Mod smoke test.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local function clone(value, seen)
        if type(value) ~= "table" or value.GetCreationID then return value end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local result = {}; seen[value] = result
        for key, item in pairs(value) do result[key] = clone(item, seen) end
        return result
    end
    local function same(actual, expected, label)
        if type(expected) ~= "table" or expected.GetCreationID then
            equal(actual, expected, label)
            return
        end
        equal(type(actual), "table", label)
        for key, value in pairs(expected) do same(actual[key], value, label .. "." .. tostring(key)) end
        for key in pairs(actual) do assert(expected[key] ~= nil, label .. " gained " .. tostring(key)) end
    end
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, actor, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, actor, unpackValues(packet.values))
    end
    local function acceptInitialSetup(server, client, owner, form)
        local packet = assert(client.lastMessage("AdminFinishedCreation"))
        equal(form.frame.valid, true, "Initial setup remains pending until its reply")
        local before = #server.messages
        relay(server, owner, packet)
        equal(#server.messages, before + 1)
        local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(reply.player, owner); equal(reply.values[1], packet.values[1][6])
        equal(reply.values[2].ok, true)
        deliver(client, reply)
        equal(form.frame.valid, false, "Initial setup closes only on matching acceptance")
    end
    local function formSince(client, first, editing)
        local form, entries = {}, {}
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then form.submit = panel end
        end
        equal(#entries, 3, "Existing configuration form fields")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        assert(form.frame and form.submit, "Missing existing configuration form")
        return form
    end
    local function setup(server, client, owner, folder, name, delay)
        local console = server.console(owner)
        local first = #client.panels + 1
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        local form = formSince(client, first)
        form.name:SetText(name or "Terminal")
        form.delay:SetText(tostring(delay or 2))
        form.file:SetText("Secret")
        form.folder.selected = folder or "tools"
        form.submit:DoClick()
        acceptInitialSetup(server, client, owner, form)
        equal(console.SlicerInformation.name, string.lower(name or "Terminal"))
        equal(console.SlicerInformation.fileType, folder or "tools")
        equal(console.SlicerInformation.delay, delay or 2)
        return console
    end
    local function say(server, actor, target, command)
        actor.target = target
        return server.fire("PlayerSay", actor, command)
    end
    local function link(server, owner, console, class)
        local door = server.entity(class or "func_door")
        equal(say(server, owner, console, "!setEntity"), "")
        equal(say(server, owner, door, "!setEntity"), "")
        equal(console.SlicerDoor, door)
        same(door.inputs, {"Lock"}, "Initial link inputs")
        return door
    end
    local function paste(server, source, owner)
        local data = {SlicerInformation = source.SlicerInformation, SlicerCreator = source.SlicerCreator,
            SlicerDoor = source.SlicerDoor, Name = source:GetName()}
        source:OnEntityCopyTableFinish(data)
        local copied = clone(data)
        local console = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        console:Initialize()
        console:SetName(copied.Name)
        console.SlicerInformation, console.SlicerCreator, console.SlicerDoor = copied.SlicerInformation, copied.SlicerCreator, copied.SlicerDoor
        console:OnDuplicated(copied)
        console:PostEntityPaste(owner, console, {})
        equal(console.SlicerCreator, owner); equal(console.SlicerDoor, nil)
        equal(console.SlicerInformation.name, source.SlicerInformation.name)
        assert(console:GetCreationID() ~= source:GetCreationID())
        assert(console.SlicerInformation ~= source.SlicerInformation)
        return console
    end
    local function snapshot(server)
        local state = {messages = clone(server.messages), messageTable = server.messages,
            records = clone(server.returnSpawnedEntities()), recordTable = server.returnSpawnedEntities(),
            serial = server.slicerSetupEditSerial, entities = {}, count = #server.entities,
            receivers = clone(server.receivers), outgoing = server.outgoing}
        for _, ent in ipairs(server.entities) do
            state.entities[ent] = {valid = ent.valid, removed = ent.removed, name = ent:GetName(), id = ent:GetCreationID(),
                creator = ent.SlicerCreator, door = ent.SlicerDoor, pending = ent.SlicerPendingConsole,
                information = ent.SlicerInformation, fields = clone(ent.SlicerInformation),
                inputs = clone(ent.inputs), chats = clone(ent.chats), weapon = ent.weapon, alive = ent.alive}
        end
        return state
    end
    local function unchanged(server, before, actor, expectedChats)
        equal(server.messages, before.messageTable); same(server.messages, before.messages, "Inspection packets")
        equal(server.returnSpawnedEntities(), before.recordTable)
        same(server.returnSpawnedEntities(), before.records, "Configuration records")
        equal(server.slicerSetupEditSerial, before.serial, "Inspection must not issue an edit ticket")
        equal(server.outgoing, before.outgoing); same(server.receivers, before.receivers, "Receivers")
        equal(#server.entities, before.count, "Inspection entity count")
        for ent, saved in pairs(before.entities) do
            equal(ent.valid, saved.valid); equal(ent.removed, saved.removed)
            equal(ent:GetName(), saved.name); equal(ent:GetCreationID(), saved.id)
            equal(ent.SlicerCreator, saved.creator); equal(ent.SlicerDoor, saved.door)
            equal(ent.SlicerPendingConsole, saved.pending, "Inspection preserves each creator's pending selection")
            equal(ent.SlicerInformation, saved.information, "Inspection cannot replace configuration")
            same(ent.SlicerInformation, saved.fields, "Saved configuration")
            same(ent.inputs, saved.inputs, "Inspection door inputs")
            equal(ent.weapon, saved.weapon); equal(ent.alive, saved.alive)
            if ent == actor then
                equal(#ent.chats, #saved.chats + expectedChats, "Private inspection response count")
                for i, text in ipairs(saved.chats) do equal(ent.chats[i], text) end
            else same(ent.chats, saved.chats, "Other player's chat") end
        end
    end
    local function inspect(server, actor, target)
        actor.target = target
        local before = snapshot(server)
        equal(server.fire("PlayerSay", actor, "!inspectLink"), "", "Exact inspection command must be consumed")
        unchanged(server, before, actor, 1)
        local text = actor.chats[#actor.chats]
        assert(#text <= 255, "Inspection exceeds ChatPrint's byte limit")
        assert(not text:find("[%z\1-\31\127]"), "Inspection must be one readable chat line")
        return text
    end
    local function contains(text, part)
        assert(text:lower():find(part:lower(), 1, true), "Expected '" .. part .. "' in: " .. text)
    end
    local function identity(text, console)
        contains(text, console.SlicerInformation.name)
        assert(text:find("#" .. console:GetCreationID() .. "%f[%D]"), "Missing current console creation ID: " .. text)
    end
    local function registered(text, console, door)
        identity(text, console); contains(text, "registered link")
        contains(text, door:GetClass())
        assert(text:find("#" .. door:GetCreationID() .. "%f[%D]"), "Missing current door creation ID: " .. text)
        assert(not text:lower():find("cannot", 1, true), "Expected a confirmed relationship: " .. text)
    end
    local function private(text, console)
        assert(not text:find(console.SlicerInformation.name, 1, true), "Foreign configured name leaked")
        assert(not text:find("#" .. console:GetCreationID() .. "%f[%D]"), "Foreign console identity leaked")
    end
    local function openHack(server, client, actor, console)
        local before = #server.messages
        server.open(actor, console)
        equal(#server.messages, before + 1, "Existing Use must open one hack")
        local packet = server.lastMessage("ServerSendsEntityInformation")
        equal(packet.player, actor); equal(packet.values[1], console)
        equal(packet.values[3].inUse, false)
        deliver(client, packet)
    end
    local function completion(client, console)
        local name = console.SlicerInformation.name
        client.command("/a[" .. name .. "]")
        client.fireTimer("AccessDelay")
        client.command("/a[" .. name .. "]/{_tools}")
        client.command("/r{_tools}/" .. console.SlicerInformation.fileName .. ".exe")
        client.assertClosed()
        return assert(client.lastMessage("PlayerActivatedDoor"))
    end

    test("inspection distinguishes two actual independent links from both endpoints", function()
        local server, client = gmod.new(), gmod.client()
        local owner, outsider = server.player(), server.player()
        local first = setup(server, client, owner, "tools", "Alpha")
        local firstDoor = link(server, owner, first, "func_door")
        local second = setup(server, client, owner, "tools", "Beta")
        local secondDoor = link(server, owner, second, "func_door_rotating")
        local pending = setup(server, client, owner, "tools", "Next")
        local otherPending = setup(server, client, outsider, "tools", "Other")
        owner.weapon = nil
        for _, pair in ipairs({{first, firstDoor}, {second, secondDoor}}) do
            for _, target in ipairs(pair) do
                local text = inspect(server, owner, target)
                registered(text, pair[1], pair[2])
                assert(not text:find(pair[1] == first and "beta" or "alpha", 1, true))
                private(inspect(server, outsider, target), pair[1])
            end
        end
        equal(owner.SlicerPendingConsole, pending); equal(outsider.SlicerPendingConsole, otherPending)
        local nextDoor = server.entity("func_door")
        equal(say(server, owner, nextDoor, "!setEntity"), "")
        equal(pending.SlicerDoor, nextDoor, "Inspection must leave the next real link aimed at its selected console")
        equal(first.SlicerDoor, firstDoor); equal(second.SlicerDoor, secondDoor)
    end)

    test("inspection during deferred setup leaves the actual setup form usable", function()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local pending = setup(server, client, owner, "tools", "Pending")
        local console = server.console(owner)
        local first = #client.panels + 1
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        local form = formSince(client, first)
        contains(inspect(server, owner, console), "setup")
        equal(owner.SlicerPendingConsole, pending)
        form.name:SetText("Configured after inspection"); form.delay:SetText("2"); form.file:SetText("Secret")
        form.folder.selected = "tools"; form.submit:DoClick()
        acceptInitialSetup(server, client, owner, form)
        contains(inspect(server, owner, console), "never")
        local door = link(server, owner, console, "func_door_rotating")
        registered(inspect(server, owner, door), console, door)
    end)

    for _, folder in ipairs({"data", "server"}) do
        test("inspection leaves an open " .. folder .. " editor's original ticket usable", function()
            local server, client = gmod.new(), gmod.client()
            local owner, hacker = server.player(), server.player()
            local editable = setup(server, client, owner, folder, "Editable")
            local linked = setup(server, client, owner, "tools", "Busy")
            local door = link(server, owner, linked, "func_door_rotating")
            local pending = setup(server, client, owner, "tools", "Pending")
            say(server, owner, editable, "!editConsole")
            local packet = assert(server.lastMessage("SlicerSetupEditOpen"))
            local token, first = packet.values[3], #client.panels + 1
            deliver(client, packet)
            local form = formSince(client, first, true)
            server.now = 10; server.open(hacker, linked)
            owner.weapon = nil
            for _ = 1, 3 do
                contains(inspect(server, owner, editable), "configured for " .. folder .. "; door linking is for tools consoles")
                registered(inspect(server, owner, linked), linked, door)
                registered(inspect(server, owner, door), linked, door)
            end
            equal(form.frame.valid, true, "Inspection must leave the original editor open")
            form.name:SetText("Saved after inspection"); form.delay:SetText("3.75"); form.file:SetText("New file")
            form.submit:DoClick()
            local save = assert(client.lastMessage("SlicerSetupEditSave"))
            equal(save.values[2], token, "The existing form must retain its ticket")
            relay(server, owner, save)
            local reply = assert(server.lastMessage("SlicerSetupEditReply"))
            equal(reply.values[1], token); equal(reply.values[2].ok, true)
            deliver(client, reply); equal(form.frame.valid, false)
            equal(editable.SlicerInformation.name, "saved after inspection")
            equal(editable.SlicerInformation.delay, 3.75)
            equal(editable.SlicerInformation.fileType, folder)
            equal(owner.SlicerPendingConsole, pending)
            equal(linked.SlicerInformation.inUse, true, "Saving another editor cannot release the inspected hack")
            server.now = 12; server.receive("PlayerActivatedDoor", hacker, linked)
            equal(linked.removed, true); same(door.inputs, {"Lock", "Unlock"}, "Original hack completion")
        end)
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test(class .. " repeated inspection preserves quit, rejection and the original completion deadline", function()
            local server, setupClient, hackClient = gmod.new(), gmod.client(), gmod.client()
            local owner, rival = server.player(), server.player()
            local console = setup(server, setupClient, owner, "tools", "Terminal")
            local door = link(server, owner, console, class)
            local other = setup(server, setupClient, owner, "tools", "Other link")
            local otherDoor = link(server, owner, other, class)
            local duplicate = paste(server, console, owner)
            server.now = 20; openHack(server, hackClient, owner, console)
            server.now = 20.5
            registered(inspect(server, owner, console), console, door)
            registered(inspect(server, owner, door), console, door)
            hackClient.command("/q[terminal]")
            relay(server, owner, hackClient.lastMessage("playerQuitConsole"))
            equal(console.SlicerInformation.inUse, false); same(door.inputs, {"Lock"}, "Quit inputs")
            server.receive("PlayerActivatedDoor", owner, console)
            equal(console.removed, nil, "Inspection does not grant completion authority after quit")

            server.now = 30; openHack(server, hackClient, owner, console)
            server.now = 31
            registered(inspect(server, owner, console), console, door)
            registered(inspect(server, owner, door), console, door)
            local before = #server.messages
            server.open(rival, console); server.open(owner, other)
            equal(#server.messages, before, "Both original reservation boundaries must remain active")
            server.now = 31.999
            relay(server, owner, completion(hackClient, console))
            equal(console.removed, nil); equal(console.SlicerInformation.inUse, false)
            same(door.inputs, {"Lock"}, "Early completion inputs")
            equal(server.lastMessage("SlicerCompleted"), nil)
            equal(server.lastMessage("PlayerDied").player, owner)

            server.now = 40; openHack(server, hackClient, owner, console)
            for _, now in ipairs({40.5, 41, 41.999, 42}) do
                server.now = now
                registered(inspect(server, owner, console), console, door)
                registered(inspect(server, owner, door), console, door)
            end
            local request = completion(hackClient, console)
            relay(server, owner, request)
            equal(console.removed, true, "Inspection must not postpone the original exact deadline")
            same(door.inputs, {"Lock", "Unlock"}, "Accepted completion inputs")
            same(otherDoor.inputs, {"Lock"}, "Independent link inputs")
            equal(other.removed, nil); equal(duplicate.removed, nil); equal(duplicate.SlicerDoor, nil)
            local accepted = assert(server.lastMessage("SlicerCompleted"))
            equal(accepted.player, owner); equal(accepted.values[1], "terminal")
            deliver(hackClient, accepted); equal(#hackClient.chatMessages, 1); hackClient.assertClosed()
            local count = #server.messages
            relay(server, owner, request)
            equal(#server.messages, count, "Repeated completion is still ignored")
            same(door.inputs, {"Lock", "Unlock"}, "Stale completion inputs")
            contains(inspect(server, owner, duplicate), "never")
            registered(inspect(server, owner, otherDoor), other, otherDoor)
        end)
    end

    for _, sameOwner in ipairs({true, false}) do
        for _, sourceFirst in ipairs({true, false}) do
            test("inspected same-name copies isolate cleanup for " .. (sameOwner and "same" or "different") .. " owners, " .. (sourceFirst and "source" or "copy") .. " first", function()
                local server, client = gmod.new(), gmod.client()
                local owner, copier = server.player(), server.player()
                if sameOwner then copier = owner end
                local source = setup(server, client, owner, "tools", "Shared name")
                local door = link(server, owner, source, "func_door_rotating")
                registered(inspect(server, owner, source), source, door)
                local copy = paste(server, source, copier)
                local text = inspect(server, copier, copy)
                identity(text, copy); contains(text, "never")
                registered(inspect(server, owner, door), source, door)
                if not sameOwner then
                    private(inspect(server, copier, source), source)
                    private(inspect(server, copier, door), source)
                    private(inspect(server, owner, copy), copy)
                end
                if sourceFirst then
                    source:Remove()
                    same(door.inputs, {"Lock", "Unlock"}, "Source cleanup inputs")
                    equal(copy.valid, true); equal(copy.SlicerDoor, nil)
                    identity(inspect(server, copier, copy), copy)
                    private(inspect(server, owner, door), source)
                    copy:Remove()
                else
                    copy:Remove()
                    same(door.inputs, {"Lock"}, "Copy cleanup inputs")
                    registered(inspect(server, owner, door), source, door)
                    source:Remove()
                end
                same(door.inputs, {"Lock", "Unlock"}, "Final cleanup inputs")
            end)
        end
    end

    test("inspection of a removed former door preserves the non-relinkable pointer", function()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local source = setup(server, client, owner, "tools", "Former link")
        local door = link(server, owner, source)
        local pending = setup(server, client, owner, "tools", "Pending")
        door:Remove()
        local text = inspect(server, owner, source)
        identity(text, source); contains(text, "no longer available")
        assert(not text:find("!setEntity", 1, true), "A removed door must not invite relinking")
        private(inspect(server, owner, door), source)
        say(server, owner, source, "!setEntity")
        equal(owner.SlicerPendingConsole, pending); equal(source.SlicerDoor, door)
        source:Remove(); same(door.inputs, {"Lock"}, "Removed door inputs")
    end)

    test("inspection cannot repair a mismatched reverse pointer or steal another live link", function()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local first = setup(server, client, owner, "tools", "First")
        local firstDoor = link(server, owner, first, "func_door")
        local second = setup(server, client, owner, "tools", "Second")
        local secondDoor = link(server, owner, second, "func_door_rotating")
        first.SlicerDoor = secondDoor -- A legacy/external inconsistent pointer is not authority.
        contains(inspect(server, owner, first), "no registered link can be confirmed")
        private(inspect(server, owner, firstDoor), first)
        registered(inspect(server, owner, secondDoor), second, secondDoor)
        first:Remove()
        same(firstDoor.inputs, {"Lock"}, "Stale first registry cleanup")
        same(secondDoor.inputs, {"Lock"}, "Other console's door cleanup")
        private(inspect(server, owner, firstDoor), first)
        registered(inspect(server, owner, second), second, secondDoor)
        second:Remove(); same(secondDoor.inputs, {"Lock", "Unlock"}, "Only its registered owner unlocks")
    end)

    test("inspection after entity reload does not recreate the empty link registry", function()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local source = setup(server, client, owner, "tools", "Surviving pointer")
        local door = link(server, owner, source, "func_door_rotating")
        local copy = paste(server, source, owner)
        registered(inspect(server, owner, door), source, door)
        server.include("entities/consoleent/init.lua")
        for _ = 1, 3 do
            local text = inspect(server, owner, source)
            identity(text, source); contains(text, "no registered link can be confirmed")
            private(inspect(server, owner, door), source)
            contains(inspect(server, owner, copy), "never")
        end
        equal(server.fire("PlayerUse", owner, door), nil, "Inspection must not restore the door hook's old registration")
        equal(source.SlicerDoor, door); equal(copy.SlicerDoor, nil)
        copy:Remove(); source:Remove()
        same(door.inputs, {"Lock"}, "A surviving pointer alone must not acquire cleanup authority")
    end)
end

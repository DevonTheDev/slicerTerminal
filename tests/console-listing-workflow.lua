-- Exercise the real setup, chat, editor, copy and hacking callbacks. Private
-- session, edit-ticket and door-registry tables are never recreated or read:
-- their authority is checked through the next observable action after listing.
-- Native chat addons, eye traces, duplicator dispatch and brush-door behavior
-- still need a Garry's Mod smoke test.
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
    local function formSince(client, first, editing)
        local form, entries = {}, {}
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then form.submit = panel
            elseif panel.class == "DButton" and panel.text == "Set up later" then form.later = panel end
        end
        equal(#entries, 3, "Existing configuration form fields")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        assert(form.frame and form.submit, "Missing existing configuration form")
        function form:fill(folder, name, delay, file)
            self.name:SetText(name or "Terminal")
            self.delay:SetText(tostring(delay or 2))
            self.file:SetText(file or "Secret")
            if not editing then self.folder.selected = folder or "tools" end
        end
        return form
    end
    local function openForm(client, packet, editing)
        local first = #client.panels + 1
        deliver(client, packet)
        return formSince(client, first, editing)
    end
    local function acceptSetup(server, client, owner, form)
        local request = assert(client.lastMessage("AdminFinishedCreation"))
        equal(form.frame.valid, true, "Initial submission stays pending until its matching reply")
        relay(server, owner, request)
        local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(reply.player, owner); equal(reply.values[1], request.values[1][6])
        equal(reply.values[2].ok, true)
        deliver(client, reply); equal(form.frame.valid, false)
        return request
    end
    local function setup(server, client, owner, folder, name, delay)
        local console = server.console(owner)
        local form = openForm(client, server.lastMessage("PlayerSpawnedConsole"))
        form:fill(folder, name, delay); form.submit:DoClick()
        acceptSetup(server, client, owner, form)
        equal(console.SlicerInformation.name, string.lower(name or "Terminal"))
        equal(console.SlicerInformation.fileType, folder or "tools")
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
        equal(console.SlicerDoor, door); same(door.inputs, {"Lock"}, "Initial link inputs")
        return door
    end
    local function paste(server, source, owner)
        local data = {SlicerInformation = source.SlicerInformation, SlicerCreator = source.SlicerCreator,
            SlicerDoor = source.SlicerDoor, Name = source:GetName()}
        source:OnEntityCopyTableFinish(data)
        local copied = clone(data)
        local console = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        console:Initialize(); console:SetName(copied.Name)
        console.SlicerInformation, console.SlicerCreator, console.SlicerDoor = copied.SlicerInformation, copied.SlicerCreator, copied.SlicerDoor
        console:OnDuplicated(copied); console:PostEntityPaste(owner, console, {})
        equal(console.SlicerCreator, owner); equal(console.SlicerDoor, nil)
        assert(console:GetName() ~= source:GetName(), "Paste has its own internal console identity")
        assert(console:GetCreationID() ~= source:GetCreationID())
        if source.SlicerInformation then
            equal(console.SlicerInformation.name, source.SlicerInformation.name)
            assert(console.SlicerInformation ~= source.SlicerInformation)
        else equal(console.SlicerInformation, nil) end
        return console
    end
    local function snapshot(server)
        local state = {messages = clone(server.messages), messageTable = server.messages,
            records = clone(server.returnSpawnedEntities()), recordTable = server.returnSpawnedEntities(),
            serial = server.slicerSetupEditSerial, entities = {}, count = #server.entities,
            receivers = clone(server.receivers), outgoing = server.outgoing, now = server.now}
        for _, ent in ipairs(server.entities) do
            state.entities[ent] = {valid = ent.valid, removed = ent.removed, name = ent:GetName(), id = ent:GetCreationID(),
                creator = ent.SlicerCreator, door = ent.SlicerDoor, pending = ent.SlicerPendingConsole,
                information = ent.SlicerInformation, fields = clone(ent.SlicerInformation),
                inputs = clone(ent.inputs), chats = clone(ent.chats), weapon = ent.weapon, alive = ent.alive,
                target = ent.target}
        end
        return state
    end
    local function unchanged(server, before, actor)
        equal(server.messages, before.messageTable); same(server.messages, before.messages, "Listing packets")
        equal(server.returnSpawnedEntities(), before.recordTable)
        same(server.returnSpawnedEntities(), before.records, "Configuration records")
        equal(server.slicerSetupEditSerial, before.serial, "Listing cannot issue an edit ticket")
        equal(server.outgoing, before.outgoing); same(server.receivers, before.receivers, "Receivers")
        equal(server.now, before.now); equal(#server.entities, before.count, "Listing entity count")
        for ent, saved in pairs(before.entities) do
            equal(ent.valid, saved.valid); equal(ent.removed, saved.removed)
            equal(ent:GetName(), saved.name); equal(ent:GetCreationID(), saved.id)
            equal(ent.SlicerCreator, saved.creator); equal(ent.SlicerDoor, saved.door)
            equal(ent.SlicerPendingConsole, saved.pending, "Listing preserves each creator's selection")
            equal(ent.SlicerInformation, saved.information, "Listing cannot replace saved configuration")
            same(ent.SlicerInformation, saved.fields, "Saved configuration")
            same(ent.inputs, saved.inputs, "Door inputs")
            equal(ent.weapon, saved.weapon); equal(ent.alive, saved.alive); equal(ent.target, saved.target)
            if ent == actor then
                assert(#ent.chats > #saved.chats, "Listing needs a private response")
                for i, text in ipairs(saved.chats) do equal(ent.chats[i], text) end
            else same(ent.chats, saved.chats, "Other player's chat") end
        end
    end
    local function listing(server, actor, page)
        local before = snapshot(server)
        local trace, weapon = actor.GetEyeTrace, actor.GetActiveWeapon
        actor.GetEyeTrace = function() error("Inventory must not trace a target") end
        actor.GetActiveWeapon = function() error("Inventory must not ask for a weapon") end
        local ok, result = pcall(server.fire, "PlayerSay", actor, "!listConsoles" .. (page and " " .. page or ""))
        actor.GetEyeTrace, actor.GetActiveWeapon = trace, weapon
        assert(ok, result)
        equal(result, "", "Exact console-listing command must be consumed")
        unchanged(server, before, actor)
        local lines, rows = {}, {}
        for i = #before.entities[actor].chats + 1, #actor.chats do
            local line = actor.chats[i]
            assert(type(line) == "string" and #line <= 255, "Listing respects ChatPrint's byte limit")
            assert(not line:find("[%z\1-\31\127]"), "Listing is readable one-line chat")
            lines[#lines + 1] = line
            if line:match("^[1-5]%. Console.- %(current ID #%d+%)") then rows[#rows + 1] = line end
        end
        assert(#rows <= 5, "At most five console rows per page")
        return rows, table.concat(lines, "\n")
    end
    local function contains(text, part)
        assert(text:lower():find(part:lower(), 1, true), "Expected '" .. part .. "' in: " .. text)
    end
    local function rowFor(rows, console)
        for _, text in ipairs(rows) do
            if text:match("^[1-5]%. Console.- %(current ID #" .. console:GetCreationID() .. "%)") then return text end
        end
        error("Missing current console #" .. console:GetCreationID() .. " in inventory: " .. table.concat(rows, " | "))
    end
    local function absent(rows, console)
        for _, text in ipairs(rows) do
            assert(not text:match("^[1-5]%. Console.- %(current ID #" .. console:GetCreationID() .. "%)"), "Unexpected foreign/removed console row")
        end
    end
    local function registered(rows, console, door)
        local text = rowFor(rows, console)
        contains(text, console.SlicerInformation.name); contains(text, "registered link")
        contains(text, door:GetClass()); contains(text, "#" .. door:GetCreationID() .. ")")
        return text
    end
    local function openHack(server, client, actor, console)
        local before = #server.messages
        server.open(actor, console); equal(#server.messages, before + 1, "Ordinary Use must reserve one hack")
        local packet = assert(server.lastMessage("ServerSendsEntityInformation"))
        equal(packet.player, actor); equal(packet.values[1], console); equal(packet.values[3].inUse, false)
        deliver(client, packet)
    end
    local function completion(client, console)
        local information = console.SlicerInformation
        client.command("/a[" .. information.name .. "]"); client.fireTimer("AccessDelay")
        client.command("/a[" .. information.name .. "]/{_tools}")
        client.command("/r{_tools}/" .. information.fileName .. ".exe")
        client.assertClosed()
        return assert(client.lastMessage("PlayerActivatedDoor"))
    end

    test("inventory discovers a deferred draft and preserves its first-write setup acceptance", function()
        local server, client = gmod.new(), gmod.client()
        local owner, foreign = server.player(), server.player()
        local pending = setup(server, client, owner, "tools", "Pending")
        local console = server.console(owner)
        local form = openForm(client, server.lastMessage("PlayerSpawnedConsole"))
        local other = server.console(foreign)
        form:fill("tools", "Deferred draft"); form.later:DoClick()
        owner.weapon = nil
        local rows = listing(server, owner)
        equal(#rows, 2); contains(rowFor(rows, console), "needs setup"); absent(rows, other)
        equal(console.SlicerInformation, nil); equal(owner.SlicerPendingConsole, pending)
        equal(#server.returnSpawnedEntities(), 1, "Deferred discovery must not depend on the configured-record list")
        server.open(owner, console)
        local fresh = openForm(client, server.lastMessage("PlayerSpawnedConsole"))
        equal(fresh.name:GetValue(), "", "Deferral discarded the old draft")
        fresh:fill("data", "Discovered later", 3); fresh.submit:DoClick()
        local request = assert(client.lastMessage("AdminFinishedCreation"))
        rows = listing(server, owner)
        contains(rowFor(rows, console), "needs setup"); equal(fresh.frame.valid, true)
        equal(client.lastMessage("AdminFinishedCreation"), request, "Listing cannot rewrite the submitted setup packet")
        acceptSetup(server, client, owner, fresh)
        rows = listing(server, owner)
        contains(rowFor(rows, console), "discovered later"); contains(rowFor(rows, console), "configured for data")
        equal(owner.SlicerPendingConsole, pending, "Data setup/listing leaves the earlier tools selection intact")
        owner.weapon = server.entity("weapon_hacking")
        local door = server.entity("func_door_rotating")
        equal(say(server, owner, door, "!setEntity"), ""); equal(pending.SlicerDoor, door)
        equal(console.SlicerDoor, nil); same(door.inputs, {"Lock"}, "Pending selection remains authoritative")
    end)

    test("inventory discovers an unconfigured paste under its actual creator before creator Use", function()
        local server, client = gmod.new(), gmod.client()
        local owner, copier = server.player(), server.player()
        local source = server.console(owner)
        local draft = openForm(client, server.lastMessage("PlayerSpawnedConsole")); draft.later:DoClick()
        local copy = paste(server, source, copier)
        copier.weapon = nil
        local rows = listing(server, copier)
        equal(#rows, 1); contains(rowFor(rows, copy), "needs setup"); absent(rows, source)
        rows = listing(server, owner); equal(#rows, 1); rowFor(rows, source); absent(rows, copy)
        local count = #server.messages
        server.open(owner, copy); equal(#server.messages, count, "Listing grants no creator authority over the foreign paste")
        server.open(copier, copy)
        local form = openForm(client, server.lastMessage("PlayerSpawnedConsole"))
        form:fill("server", "Copied configuration"); form.submit:DoClick()
        listing(server, copier); acceptSetup(server, client, copier, form)
        rows = listing(server, copier)
        contains(rowFor(rows, copy), "copied configuration"); contains(rowFor(rows, copy), "configured for server")
        equal(source.SlicerInformation, nil); equal(source.SlicerCreator, owner)
    end)

    test("inventory pages actual configured, copied, deferred and busy consoles without changing selection", function()
        local server, client, hackClient = gmod.new(), gmod.client(), gmod.client()
        local owner, hacker, foreign = server.player(), server.player(), server.player()
        local source = setup(server, client, owner, "tools", "Shared name")
        local door = link(server, owner, source)
        local copy = paste(server, source, owner)
        local deferred = server.console(owner)
        local form = openForm(client, server.lastMessage("PlayerSpawnedConsole")); form.later:DoClick()
        local fourth = setup(server, client, owner, "data", "Fourth")
        local fifth = setup(server, client, owner, "server", "Fifth")
        local sixth = setup(server, client, owner, "tools", "Sixth")
        local selected = setup(server, client, owner, "tools", "Selected")
        local other = setup(server, client, foreign, "tools", "Foreign secret")
        server.now = 10; openHack(server, hackClient, hacker, source)
        local consoles = {source, copy, deferred, fourth, fifth, sixth, selected}
        local rows, text = listing(server, owner)
        equal(#rows, 5); contains(text, "!listConsoles 2")
        for i = 1, 5 do rowFor({rows[i]}, consoles[i]) end
        absent(rows, other); registered(rows, source, door); contains(rowFor(rows, copy), "never")
        local last = listing(server, owner, 2); equal(#last, 2)
        rowFor({last[1]}, sixth); rowFor({last[2]}, selected); absent(last, other)
        equal(owner.SlicerPendingConsole, selected); equal(source.SlicerInformation.inUse, true)
        equal(hackClient.lastMessage("playerQuitConsole"), nil)
        local nextDoor = server.entity("func_door_rotating")
        equal(say(server, owner, nextDoor, "!setEntity"), ""); equal(selected.SlicerDoor, nextDoor)
        equal(source.SlicerDoor, door); equal(copy.SlicerDoor, nil)
        deferred:Remove()
        rows = listing(server, owner); equal(#rows, 5)
        rowFor({rows[3]}, fourth); rowFor({rows[5]}, sixth); absent(rows, deferred)
        last = listing(server, owner, 2); equal(#last, 1); rowFor(last, selected)
        server.now = 12; relay(server, hacker, completion(hackClient, source))
        equal(source.removed, true); same(door.inputs, {"Lock", "Unlock"}, "Original busy session remains usable")
        same(nextDoor.inputs, {"Lock"}, "Selected console's independent door")
    end)

    for _, folder in ipairs({"data", "server"}) do
        test("inventory preserves an in-flight " .. folder .. " edit ticket and shows the accepted rename", function()
            local server, client, hackClient = gmod.new(), gmod.client(), gmod.client()
            local owner, hacker = server.player(), server.player()
            local editable = setup(server, client, owner, folder, "Before rename")
            local active = setup(server, client, owner, "tools", "Active")
            local door = link(server, owner, active, "func_door_rotating")
            local pending = setup(server, client, owner, "tools", "Pending")
            equal(say(server, owner, editable, "!editConsole"), "")
            local opening = assert(server.lastMessage("SlicerSetupEditOpen"))
            local form = openForm(client, opening, true)
            server.now = 10; openHack(server, hackClient, hacker, active)
            local rows = listing(server, owner)
            contains(rowFor(rows, editable), "before rename"); registered(rows, active, door)
            form:fill(folder, "Saved after listing", 3.75, "New file"); form.submit:DoClick()
            local save = assert(client.lastMessage("SlicerSetupEditSave"))
            equal(save.values[2], opening.values[3], "Original server ticket is used")
            server.now = 11.5; rows = listing(server, owner)
            contains(rowFor(rows, editable), "before rename"); equal(form.frame.valid, true)
            equal(client.lastMessage("SlicerSetupEditSave"), save)
            relay(server, owner, save)
            local reply = assert(server.lastMessage("SlicerSetupEditReply"))
            equal(reply.values[1], opening.values[3]); equal(reply.values[2].ok, true)
            deliver(client, reply); equal(form.frame.valid, false)
            rows = listing(server, owner)
            contains(rowFor(rows, editable), "saved after listing"); contains(rowFor(rows, editable), "configured for " .. folder)
            equal(editable.SlicerInformation.delay, 3.75); equal(editable.SlicerInformation.fileName, "new file")
            equal(owner.SlicerPendingConsole, pending); equal(active.SlicerInformation.inUse, true)
            server.now = 12; relay(server, hacker, completion(hackClient, active))
            equal(active.removed, true); same(door.inputs, {"Lock", "Unlock"}, "Unrelated original deadline remains authoritative")
        end)
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test(class .. " inventory during a hack preserves quit, early rejection, retry and the exact deadline", function()
            local server, client, hackClient = gmod.new(), gmod.client(), gmod.client()
            local owner, rival = server.player(), server.player()
            local console = setup(server, client, owner, "tools", "Terminal")
            local door = link(server, owner, console, class)
            local other = setup(server, client, owner, "tools", "Other link")
            local otherDoor = link(server, owner, other, class)
            local copy = paste(server, console, owner)
            server.now = 20; openHack(server, hackClient, owner, console)
            hackClient.command("/a[terminal]")
            local timer = assert(hackClient.timers.AccessDelay)
            server.now = 20.5; registered(listing(server, owner), console, door)
            equal(hackClient.timers.AccessDelay, timer, "Inventory leaves the actual login timer intact")
            hackClient.command("/q[terminal]"); relay(server, owner, hackClient.lastMessage("playerQuitConsole"))
            equal(console.SlicerInformation.inUse, false); same(door.inputs, {"Lock"}, "Quit inputs")
            server.receive("PlayerActivatedDoor", owner, console)
            equal(console.removed, nil, "Listing grants no completion authority after quit")

            server.now = 30; openHack(server, hackClient, owner, console)
            server.now = 31; registered(listing(server, owner), console, door)
            local before = #server.messages
            server.open(rival, console); server.open(owner, other)
            equal(#server.messages, before, "Listing preserves both reservation boundaries")
            server.now = 31.999; relay(server, owner, completion(hackClient, console))
            equal(console.removed, nil); equal(console.SlicerInformation.inUse, false)
            same(door.inputs, {"Lock"}, "Early completion inputs")
            equal(server.lastMessage("SlicerCompleted"), nil); equal(server.lastMessage("PlayerDied").player, owner)

            server.now = 40; openHack(server, hackClient, owner, console)
            for _, now in ipairs({40.5, 41, 41.999, 42}) do
                server.now = now
                local rows = listing(server, owner)
                registered(rows, console, door); registered(rows, other, otherDoor); contains(rowFor(rows, copy), "never")
            end
            local request = completion(hackClient, console); relay(server, owner, request)
            equal(console.removed, true, "Repeated listing cannot postpone the original exact deadline")
            same(door.inputs, {"Lock", "Unlock"}, "Accepted completion inputs")
            same(otherDoor.inputs, {"Lock"}, "Independent link inputs")
            equal(other.removed, nil); equal(copy.removed, nil); equal(copy.SlicerDoor, nil)
            local accepted = assert(server.lastMessage("SlicerCompleted"))
            equal(accepted.player, owner); deliver(hackClient, accepted); hackClient.assertClosed()
            local count = #server.messages; relay(server, owner, request)
            equal(#server.messages, count, "Repeated completion remains ignored")
            local rows = listing(server, owner); equal(#rows, 2); absent(rows, console)
            contains(rowFor(rows, copy), "never"); registered(rows, other, otherDoor)
        end)
    end

    for _, sameOwner in ipairs({true, false}) do
        for _, sourceFirst in ipairs({true, false}) do
            test("inventory of same-name pastes preserves " .. (sameOwner and "same" or "different") .. " owner cleanup, " .. (sourceFirst and "source" or "copy") .. " first", function()
                local server, client = gmod.new(), gmod.client()
                local owner, copier = server.player(), server.player()
                if sameOwner then copier = owner end
                local source = setup(server, client, owner, "tools", "Shared name")
                local door = link(server, owner, source, "func_door_rotating")
                local copy = paste(server, source, copier)
                local rows = listing(server, owner)
                registered(rows, source, door); equal(#rows, sameOwner and 2 or 1)
                if sameOwner then contains(rowFor(rows, copy), "never") else absent(rows, copy) end
                rows = listing(server, copier)
                contains(rowFor(rows, copy), "shared name"); contains(rowFor(rows, copy), "never")
                if not sameOwner then equal(#rows, 1); absent(rows, source) end
                if sourceFirst then
                    source:Remove(); same(door.inputs, {"Lock", "Unlock"}, "Source cleanup inputs")
                    rows = listing(server, copier); rowFor(rows, copy); absent(rows, source)
                    equal(copy.valid, true); equal(copy.SlicerDoor, nil); copy:Remove()
                else
                    copy:Remove(); same(door.inputs, {"Lock"}, "Copy cleanup inputs")
                    rows = listing(server, owner); registered(rows, source, door); absent(rows, copy)
                    source:Remove()
                end
                same(door.inputs, {"Lock", "Unlock"}, "Only source ownership unlocks its door")
                rows = listing(server, owner); equal(#rows, 0)
                if not sameOwner then rows = listing(server, copier); equal(#rows, 0) end
            end)
        end
    end
end

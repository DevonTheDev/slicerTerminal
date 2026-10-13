-- Relay the actual client setup, creator commands, hack UI and server deadline.
-- Fire records are requests only; native brush-door behavior remains untested.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, actor, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, actor, unpackValues(packet.values))
    end
    local function say(server, actor, target, command)
        actor.target = target
        return server.fire("PlayerSay", actor, command)
    end
    local function formSince(client, first)
        local form, entries = {}, {}
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == "Done" then form.submit = panel end
        end
        equal(#entries, 3)
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        assert(form.frame and form.submit)
        return form
    end
    local function setup(server, client, owner)
        local console, first = server.console(owner), #client.panels + 1
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        local form = formSince(client, first)
        form.name:SetText("Corrected"); form.delay:SetText("3.5"); form.file:SetText("Secret")
        form.folder.selected = "tools"; form.submit:DoClick()
        equal(form.frame.valid, true)
        relay(server, owner, client.lastMessage("AdminFinishedCreation"))
        local accepted = server.lastMessage("SlicerInitialSetupReply")
        equal(accepted.player, owner); equal(accepted.values[2].ok, true)
        deliver(client, accepted); equal(form.frame.valid, false)
        return console
    end

    for _, listed in ipairs({false, true}) do
    for _, classes in ipairs({{"func_door", "func_door_rotating"}, {"func_door_rotating", "func_door"}}) do
        test((listed and "listed nearest " or "") .. "actual configured console corrects live " .. classes[1] .. " to " .. classes[2] .. " and completes", function()
            local server, client = gmod.new(), gmod.client()
            local owner, hacker = server.player(), server.player()
            local console = setup(server, client, owner)
            local info, identity = console.SlicerInformation, console:GetName()
            local registration = server.returnSpawnedEntities()[1]
            local oldDoor, newDoor = server.entity(classes[1]), server.entity(classes[2])
            equal(say(server, owner, oldDoor, "!setEntity"), "")
            equal(console.SlicerDoor, oldDoor); equal(oldDoor.inputs[1], "Lock")
            if listed then
                function owner:GetPos() return {x = 0, y = 0, z = 0} end
                function console:GetPos() return {x = 1, y = 0, z = 0} end
                equal(server.fire("PlayerSay", owner, "!nearConsoles 1 linked"), "")
                equal(server.slicerListedConsole(owner, 1), console)
                function owner:GetEyeTrace() error("Listed correction must not read an eye target") end
                function owner:GetActiveWeapon() error("Listed correction must not read a weapon") end
            end
            equal(say(server, owner, console, listed and "!unlinkConsole 1" or "!unlinkConsole"), "")
            equal(console.valid, true); equal(console:GetName(), identity)
            equal(console.SlicerInformation, info); equal(registration.information, info)
            equal(server.returnSpawnedEntities()[1], registration)
            equal(console.SlicerDoor, nil); equal(#oldDoor.inputs, 2); equal(oldDoor.inputs[2], "Unlock")
            equal(server.fire("PlayerUse", hacker, oldDoor), nil)
            if listed then
                assert(owner.chats[#owner.chats]:find("old link cleared; Unlock sent. If still unlinked, !listConsoles; find it; !setEntity <row>", 1, true))
                equal(server.fire("PlayerSay", owner, "!listConsoles"), "")
                equal(server.slicerListedConsole(owner, 1), console, "Identify the intended console on the fresh page before selecting it")
            else
                equal(say(server, owner, console, "!inspectLink"), "")
                assert(owner.chats[#owner.chats]:find("has no door link", 1, true))
            end
            equal(say(server, owner, console, listed and "!setEntity 1" or "!setEntity"), "")
            if listed then
                function owner:GetEyeTrace() return {Entity = self.target} end
            end
            equal(say(server, owner, newDoor, "!setEntity"), "")
            equal(console.SlicerDoor, newDoor); equal(newDoor.inputs[1], "Lock")
            equal(server.fire("PlayerUse", hacker, newDoor), false)
            equal(server.fire("PlayerUse", hacker, oldDoor), nil)
            server.now = 10; server.open(hacker, console)
            deliver(client, server.lastMessage("ServerSendsEntityInformation"))
            client.command("/a[corrected]"); client.fireTimer("AccessDelay")
            client.command("/a[corrected]/{_tools}"); client.command("/r{_tools}/secret.exe")
            client.assertClosed()
            local completion = client.lastMessage("PlayerActivatedDoor")
            equal(completion.values[1], console)
            -- A refused unlink during this session must leave its original
            -- deadline and association intact, including the legacy false flag.
            server.updateInUse(identity, false)
            equal(say(server, owner, console, listed and "!unlinkConsole 1" or "!unlinkConsole"), "")
            equal(console.SlicerDoor, newDoor); equal(#newDoor.inputs, 1)
            equal(server.slicerConsoleHasActiveSession(console), true)
            hacker.target = oldDoor
            server.now = 13.5; relay(server, hacker, completion)
            equal(console.removed, true); equal(#newDoor.inputs, 2); equal(newDoor.inputs[2], "Unlock")
            equal(#oldDoor.inputs, 2); equal(#server.returnSpawnedEntities(), 0)
            local accepted = server.lastMessage("SlicerCompleted")
            equal(accepted.player, hacker); deliver(client, accepted)
            equal(#client.chatMessages, 1)
            local count = #server.messages
            relay(server, hacker, completion)
            equal(#server.messages, count); equal(#oldDoor.inputs, 2); equal(#newDoor.inputs, 2)
        end)
    end
    end
end

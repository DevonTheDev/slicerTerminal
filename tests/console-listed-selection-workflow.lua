-- Real setup UI, chat, edit, client hacking and authenticated completion callbacks.
-- Native wire delivery and brush-door movement remain outside these doubles.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local function setup(server, client, owner, console, name, folder)
        local first = #client.panels + 1
        client.receive("PlayerSpawnedConsole", nil, owner, console:GetName())
        local entries, choice, done, frame = {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then choice = panel
            elseif panel.class == "DButton" and panel.text == "Done" then done = panel
            elseif panel.class == "DFrame" then frame = panel end
        end
        entries[1]:SetText(name)
        entries[2]:SetText("2")
        entries[3]:SetText("secret")
        choice.selected = folder or "tools"
        done:DoClick()
        local packet = assert(client.lastMessage("AdminFinishedCreation"))
        equal(frame.valid, true, "Setup stays open while its request is pending")
        equal(done.enabled, true); equal(done.text, "Check setup result")
        local before = #server.messages
        server.receive(packet.name, owner, unpackValues(packet.values))
        equal(#server.messages, before + 1)
        local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(reply.player, owner); equal(reply.values[1], packet.values[1][6])
        equal(reply.values[2].ok, true)
        equal(frame.valid, true, "Server commit alone cannot close the client")
        client.receive(reply.name, nil, unpackValues(reply.values))
        equal(frame.valid, false, "Matching acceptance closes setup")
        equal(console.SlicerInformation.name, string.lower(name), "Server accepted setup")
        return console.SlicerInformation, packet.values[1]
    end


    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function deliver(client, packet) client.receive(packet.name, nil, unpackValues(packet.values)) end
    local function relay(server, player, packet) server.receive(packet.name, player, unpackValues(packet.values)) end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test("listed selection completes " .. class .. " setup edit retry and independent hacking workflows", function()
            local server, client, hackClient = gmod.new(), gmod.client(), gmod.client()
            local owner, hacker, otherHacker = server.player(), server.player(), server.player()
            local alpha, beta = server.console(owner), server.console(owner)
            local alphaInfo, fields = setup(server, client, owner, alpha, "Alpha")
            setup(server, client, owner, beta, "Beta")
            equal(owner.SlicerPendingConsole, beta)
            owner.target = alpha; equal(say(server, owner, "!editConsole"), "")
            local token = server.lastMessage("SlicerSetupEditOpen").values[3]
            local active = server.console(owner)
            setup(server, client, owner, active, "Active", "data")
            server.open(otherHacker, active)
            equal(server.slicerConsoleHasActiveSession(active), true)
            -- Another session starts at zero and must still finish at its original deadline.
            equal(say(server, owner, "!listConsoles 1 unlinked"), "")
            owner.GetEyeTrace = function() error("Listed selection must not target by eye") end
            local packets = #server.messages
            equal(say(server, owner, "!setEntity 1"), "")
            equal(owner.SlicerPendingConsole, alpha); equal(#server.messages, packets)
            equal(alpha.SlicerInformation, alphaInfo); equal(alpha.SlicerDoor, nil)
            server.open(hacker, alpha)
            equal(server.slicerConsoleHasActiveSession(alpha), false, "Unlinked tools cannot start hacking")
            equal(#server.messages, packets)
            equal(owner.SlicerPendingConsole, alpha)
            equal(say(server, owner, "!editConsole 1"), "")
            equal(server.lastMessage("SlicerSetupEditOpen").values[3], token, "Selection retains the existing edit ticket")
            server.receive("SlicerInitialSetupStatusRequest", owner, fields)
            equal(server.lastMessage("SlicerInitialSetupStatusReply").values[2].confirmed, true)
            equal(owner.SlicerPendingConsole, alpha, "Setup recovery cannot replace explicit selection")
            server.now = 3.99
            equal(say(server, owner, "!setEntity 1"), "")
            server.now = 4
            server.receive("destroyOnServer", otherHacker, active)
            equal(active.removed, true, "Selection did not renew the original session deadline")
            equal(server.lastMessage("SlicerCompleted").player, otherHacker)
            server.now = 60
            equal(say(server, owner, "!setEntity 2"), "")
            equal(owner.SlicerPendingConsole, alpha, "Expired lease cannot replace accepted pending selection")
            owner.GetEyeTrace = function(self) return {Entity = self.target} end
            local claimed = server.entity(class)
            owner.target = beta; say(server, owner, "!setEntity")
            owner.target = claimed; say(server, owner, "!setEntity")
            equal(beta.SlicerDoor, claimed)
            -- Refresh only to select Alpha again; later invalid relisting cannot revoke it.
            equal(say(server, owner, "!listConsoles"), "")
            equal(say(server, owner, "!setEntity 1"), "")
            equal(say(server, owner, "!listConsoles 0"), "")
            for _, target in ipairs({server.entity("prop_physics"), claimed}) do
                owner.target = target; say(server, owner, "!setEntity")
                equal(owner.SlicerPendingConsole, alpha); equal(alpha.SlicerDoor, nil)
            end
            local door = server.entity(class)
            owner.target = door; equal(say(server, owner, "!setEntity"), "")
            equal(alpha.SlicerDoor, door); equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
            equal(owner.SlicerPendingConsole, nil); equal(server.fire("PlayerUse", hacker, door), false)
            equal(say(server, owner, "!listConsoles"), "")
            equal(say(server, owner, "!setEntity 1"), "")
            equal(owner.SlicerPendingConsole, nil, "Linked terminal cannot be selected again")
            server.receive("SlicerSetupEditSave", owner, alpha, token, {name = "renamed", delay = 2, fileName = "secret"})
            equal(server.lastMessage("SlicerSetupEditReply").values[2].ok, true, "Original editor still saves after selection and linking")
            equal(alpha.SlicerDoor, door)
            server.open(hacker, alpha)
            local opened = assert(server.lastMessage("ServerSendsEntityInformation"))
            equal(opened.player, hacker); equal(opened.values[1], alpha)
            deliver(hackClient, opened)
            hackClient.command("/a[renamed]")
            equal(hackClient.timers.AccessDelay.delay, 2)
            hackClient.fireTimer("AccessDelay")
            hackClient.command("/a[renamed]/{_tools}")
            hackClient.command("/r{_tools}/secret.exe")
            local completed = assert(hackClient.lastMessage("PlayerActivatedDoor"))
            equal(completed.values[1], alpha)
            server.now = 62; relay(server, hacker, completed)
            equal(alpha.removed, true); equal(beta.removed, nil)
            equal(#door.inputs, 2); equal(door.inputs[2], "Unlock"); equal(#claimed.inputs, 1)
            local accepted = assert(server.lastMessage("SlicerCompleted"))
            equal(accepted.player, hacker); deliver(hackClient, accepted); hackClient.assertClosed()
        end)
    end
end

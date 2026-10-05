return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack

    -- Use the real setup form and relay its packet to the real authenticated
    -- receiver. Only GMod's engine, transport and panels are synthetic.
    local function setup(server, client, owner, console, name, folder)
        local first = #client.panels + 1
        client.receive("PlayerSpawnedConsole", nil, owner, console:GetName())
        local entries, choice, done, frame = {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then choice = panel
            elseif panel.class == "DButton" then done = panel
            elseif panel.class == "DFrame" then frame = panel end
        end
        entries[1]:SetText(name)
        entries[2]:SetText("2")
        entries[3]:SetText("secret")
        choice.selected = folder or "tools"
        done:DoClick()
        local packet = assert(client.lastMessage("AdminFinishedCreation"))
        server.receive(packet.name, owner, unpackValues(packet.values))
        equal(frame.valid, false, "Setup closed")
        equal(console.SlicerInformation.name, string.lower(name), "Server accepted setup")
        return console.SlicerInformation
    end

    local function fixture()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local alpha, beta = server.console(owner), server.console(owner)
        setup(server, client, owner, alpha, "Alpha")
        equal(owner.SlicerPendingConsole, alpha, "First setup selects Alpha")
        setup(server, client, owner, beta, "Beta")
        equal(owner.SlicerPendingConsole, beta, "Newest setup still selects Beta")
        return server, client, owner, alpha, beta
    end

    local function command(server, owner, target)
        owner.target = target
        return server.fire("PlayerSay", owner, "!setEntity")
    end

    local function contains(value, expected, message)
        assert(value and value:find(expected, 1, true), message or ("Missing feedback: " .. expected))
    end

    local function lastChat(owner)
        return owner.chats[#owner.chats]
    end

    -- Observe production state at the API boundary so refusal tests catch a
    -- released session, edited setup, door input or consumed terminal too.
    local function unchanged(server)
        local entities, messages, entries = {}, #server.messages, #server.returnSpawnedEntities()
        for _, entity in ipairs(server.entities) do
            local info = entity.SlicerInformation
            local state = {
                entity = entity, valid = entity.valid, removed = entity.removed,
                creator = entity.SlicerCreator, door = entity.SlicerDoor,
                info = info, inputs = #entity.inputs,
            }
            if info then
                state.values = {}
                for key, value in pairs(info) do state.values[key] = value end
            end
            entities[#entities + 1] = state
        end
        return function()
            equal(#server.messages, messages, "No network/session message")
            equal(#server.returnSpawnedEntities(), entries, "No setup added or removed")
            for _, state in ipairs(entities) do
                local entity = state.entity
                equal(entity.valid, state.valid, "Entity validity unchanged")
                equal(entity.removed, state.removed, "No terminal consumed")
                equal(entity.SlicerCreator, state.creator, "Creator unchanged")
                equal(entity.SlicerDoor, state.door, "Door assignment unchanged")
                equal(entity.SlicerInformation, state.info, "Configuration identity unchanged")
                equal(#entity.inputs, state.inputs, "No door input")
                if state.info then
                    for key, value in pairs(state.values) do equal(state.info[key], value, "Configuration " .. key) end
                    for key, value in pairs(state.info) do equal(value, state.values[key], "No added configuration field") end
                end
            end
        end
    end

    for _, alphaFirst in ipairs({true, false}) do
        test("same creator can reselect and link Alpha/Beta " .. (alphaFirst and "oldest first" or "newest first"), function()
            local server, _, owner, alpha, beta = fixture()
            local first, second = alphaFirst and alpha or beta, alphaFirst and beta or alpha
            local door1, door2 = server.entity("func_door"), server.entity("func_door")
            local noEffects = unchanged(server)
            equal(command(server, owner, first), "", "Selection is handled privately")
            equal(owner.SlicerPendingConsole, first, "Looked-at terminal selected")
            contains(lastChat(owner), first.SlicerInformation.name, "Selection names the terminal")
            contains(lastChat(owner), "!setEntity", "Selection explains the next command")
            contains(lastChat(owner), "door", "Selection explains the next target")
            noEffects()
            command(server, owner, door1)
            equal(first.SlicerDoor, door1)
            equal(owner.SlicerPendingConsole, nil)
            command(server, owner, second)
            equal(owner.SlicerPendingConsole, second, "Earlier terminal remains recoverable")
            command(server, owner, door2)
            equal(second.SlicerDoor, door2)
            equal(door1.inputs[1], "Lock"); equal(#door1.inputs, 1)
            equal(door2.inputs[1], "Lock"); equal(#door2.inputs, 1)
        end)
    end

    test("deleting the newest pending terminal allows explicit recovery of the older one", function()
        local server, _, owner, alpha, beta = fixture()
        beta:Remove()
        equal(owner.SlicerPendingConsole, nil)
        command(server, owner, alpha)
        equal(owner.SlicerPendingConsole, alpha)
        local door = server.entity("func_door")
        command(server, owner, door)
        equal(alpha.SlicerDoor, door)
    end)

    test("newest setup still links directly without explicit reselection", function()
        local server, _, owner, alpha, beta = fixture()
        local door = server.entity("func_door")
        command(server, owner, door)
        equal(beta.SlicerDoor, door)
        equal(alpha.SlicerDoor, nil)
        equal(owner.SlicerPendingConsole, nil)
    end)

    test("an invalid door preserves the selected terminal and explains retry", function()
        local server, _, owner, alpha = fixture()
        command(server, owner, alpha)
        local prop = server.entity("prop_physics")
        local noEffects = unchanged(server)
        command(server, owner, prop)
        equal(owner.SlicerPendingConsole, alpha)
        contains(lastChat(owner), "!setEntity", "Invalid door gives retry instructions")
        noEffects()
        local door = server.entity("func_door")
        command(server, owner, door)
        equal(alpha.SlicerDoor, door)
    end)

    test("separate creators select and link only their own pending terminals", function()
        local server, client, owner, alpha, beta = fixture()
        local other = server.player()
        local gamma = server.console(other)
        setup(server, client, other, gamma, "Gamma")
        command(server, owner, alpha)
        command(server, other, gamma)
        equal(owner.SlicerPendingConsole, alpha)
        equal(other.SlicerPendingConsole, gamma)
        local da, dg = server.entity("func_door"), server.entity("func_door")
        command(server, other, dg); command(server, owner, da)
        equal(alpha.SlicerDoor, da); equal(gamma.SlicerDoor, dg)
        equal(beta.SlicerDoor, nil)
    end)

    local invalidations = {
        {name = "wrong creator", change = function(server, console) console.SlicerCreator = server.player() end},
        {name = "data console", change = function(_, console) console.SlicerInformation.fileType = "data" end},
        {name = "server console", change = function(_, console) console.SlicerInformation.fileType = "server" end},
        {name = "unconfigured console", change = function(_, console) console.SlicerInformation = nil end},
        {name = "removed console", change = function(_, console) console:Remove() end},
        {name = "prior live door", change = function(server, console) console.SlicerDoor = server.entity("func_door") end},
        {name = "prior removed door", change = function(server, console)
            console.SlicerDoor = server.entity("func_door"); console.SlicerDoor:Remove()
        end},
        {name = "in-use console", change = function(_, console) console.SlicerInformation.inUse = true end},
        {name = "wrong entity class", change = function(_, console) console.class = "prop_physics" end},
    }

    for _, invalid in ipairs(invalidations) do
        test("rejecting selection of " .. invalid.name .. " preserves a valid pending terminal", function()
            local server, _, owner, alpha, beta = fixture()
            invalid.change(server, alpha)
            local noEffects = unchanged(server)
            local chats = #owner.chats
            command(server, owner, alpha)
            equal(owner.SlicerPendingConsole, beta, "Valid pending selection survives")
            equal(#owner.chats, chats + 1, "Refusal is explained")
            noEffects()
            local door = server.entity("func_door")
            command(server, owner, door)
            equal(beta.SlicerDoor, door, "Valid pending terminal can still be linked")
        end)

        test("final door link rechecks " .. invalid.name .. " after selection", function()
            local server, _, owner, _, beta = fixture()
            command(server, owner, beta)
            equal(owner.SlicerPendingConsole, beta, "Initial eligible selection succeeds")
            invalid.change(server, beta)
            local door = server.entity("func_door")
            local pending = owner.SlicerPendingConsole
            local noEffects = unchanged(server)
            command(server, owner, door)
            noEffects()
            equal(owner.SlicerPendingConsole, pending, "Rejected link does not choose a replacement")
            contains(lastChat(owner), "!setEntity", "Stale selection gives recovery instructions")
            contains(lastChat(owner), "select", "Recovery requires explicit selection")
        end)
    end

    test("already-claimed doors preserve selection and ownership until a valid retry", function()
        local server, _, owner, alpha, beta = fixture()
        local claimed, available = server.entity("func_door"), server.entity("func_door")
        command(server, owner, claimed)
        command(server, owner, alpha)
        local noEffects = unchanged(server)
        command(server, owner, claimed)
        equal(owner.SlicerPendingConsole, alpha)
        contains(lastChat(owner), "already linked", "Claimed door gets a refusal")
        noEffects()
        command(server, owner, available)
        equal(alpha.SlicerDoor, available); equal(beta.SlicerDoor, claimed)
        equal(server.fire("PlayerUse", owner, claimed), false)
        equal(server.fire("PlayerUse", owner, available), false)
    end)

    for _, targetKind in ipairs({"door", "no target"}) do
        test("empty pending state explains explicit selection when looking at " .. targetKind, function()
            local server = gmod.new()
            local owner = server.player()
            local target = targetKind == "door" and server.entity("func_door") or nil
            local noEffects = unchanged(server)
            command(server, owner, target)
            equal(owner.SlicerPendingConsole, nil)
            contains(lastChat(owner), "!setEntity")
            contains(lastChat(owner), "select")
            noEffects()
        end)
    end

    test("an ineligible console with no pending choice still explains explicit selection", function()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local console = server.console(owner)
        setup(server, client, owner, console, "Data", "data")
        local noEffects = unchanged(server)
        command(server, owner, console)
        equal(owner.SlicerPendingConsole, nil)
        contains(lastChat(owner), "!setEntity")
        contains(lastChat(owner), "select")
        noEffects()
    end)

    test("Use, repeated setup and legacy packets never become selection paths", function()
        local server, client, owner, alpha, beta = fixture()
        local noEffects = unchanged(server)
        server.open(owner, alpha)
        equal(owner.SlicerPendingConsole, beta, "Use cannot select Alpha")
        contains(lastChat(owner), "!setEntity", "Creator sees explicit recovery instructions")
        noEffects()
        local attacker = server.player()
        server.open(attacker, alpha)
        equal(attacker.SlicerPendingConsole, nil)
        equal(owner.SlicerPendingConsole, beta)
        server.receive("ServerWaitingForEntity", attacker, owner, alpha)
        server.receive("ServerWaitingForEntity", owner, owner, alpha)
        server.receive("AdminFinishedCreation", owner, {"Changed", 1, "tools", "changed", alpha:GetName()})
        equal(owner.SlicerPendingConsole, beta)
        equal(alpha.SlicerInformation.name, "alpha")
        equal(alpha.SlicerInformation.delay, 2)
        equal(alpha.SlicerInformation.inUse, false)
        equal(client.lastMessage("PlayerActivatedDoor"), nil)
    end)

    for _, removeDoor in ipairs({false, true}) do
        test("an active hack cannot be redirected after its door is " .. (removeDoor and "removed" or "linked"), function()
            local server, _, owner, alpha, beta = fixture()
            local oldDoor, newDoor = server.entity("func_door"), server.entity("func_door")
            command(server, owner, oldDoor) -- Beta is automatically selected.
            local hacker = server.player()
            server.open(hacker, beta)
            equal(beta.SlicerInformation.inUse, true)
            if removeDoor then oldDoor:Remove() end
            command(server, owner, alpha)
            local noEffects = unchanged(server)
            command(server, owner, beta)
            equal(owner.SlicerPendingConsole, alpha, "Busy/prior assignment cannot replace Alpha")
            noEffects()
            -- Simulate stale pending state from outside the selector: the final
            -- link must independently refuse to redirect the active session.
            owner.SlicerPendingConsole = beta
            noEffects = unchanged(server)
            command(server, owner, newDoor)
            noEffects()
            equal(beta.SlicerDoor, oldDoor)
            equal(beta.SlicerInformation.inUse, true, "Refusal cannot release the hack")
            server.now = 2
            server.receive("PlayerActivatedDoor", hacker, beta)
            if removeDoor then equal(beta.removed, nil) else equal(beta.removed, true) end
            equal(beta.SlicerInformation.inUse, false)
            equal(#newDoor.inputs, 0, "No redirected unlock")
            equal(server.lastMessage("SlicerCompleted") ~= nil, not removeDoor)
        end)
    end

    test("reselected tools retain minimum timing, tool checks and independent completion", function()
        local server, client, owner, alpha, beta = fixture()
        local da, db = server.entity("func_door"), server.entity("func_door")
        command(server, owner, db)
        command(server, owner, alpha); command(server, owner, da)
        equal(alpha.SlicerDoor, da, "Explicit selection links Alpha before hacking")
        local hacker = server.player()
        server.open(hacker, alpha)
        server.receive("PlayerActivatedDoor", hacker, alpha)
        equal(alpha.removed, nil, "Early completion is refused")
        equal(alpha.SlicerInformation.inUse, false, "Early request releases only that session")
        server.open(hacker, alpha)
        local opening = server.lastMessage("ServerSendsEntityInformation")
        client.receive(opening.name, nil, unpackValues(opening.values))
        client.command("/a[alpha]")
        client.fireTimer("AccessDelay")
        client.command("/a[alpha]/{_tools}")
        client.command("/r{_tools}/secret.exe")
        local completion = assert(client.lastMessage("PlayerActivatedDoor"))
        server.now = 2
        local weapon = hacker.weapon
        hacker.weapon = nil
        server.receive(completion.name, hacker, unpackValues(completion.values))
        equal(alpha.removed, nil, "Missing tool is refused")
        equal(alpha.SlicerInformation.inUse, false)
        equal(server.lastMessage("SlicerCompleted"), nil)
        hacker.weapon = weapon
        server.open(hacker, alpha)
        opening = server.lastMessage("ServerSendsEntityInformation")
        client.receive(opening.name, nil, unpackValues(opening.values))
        client.command("/a[alpha]"); client.fireTimer("AccessDelay")
        client.command("/a[alpha]/{_tools}"); client.command("/r{_tools}/secret.exe")
        completion = client.lastMessage("PlayerActivatedDoor")
        server.now = 4
        server.receive(completion.name, hacker, unpackValues(completion.values))
        equal(alpha.removed, true); equal(beta.removed, nil)
        equal(da.inputs[#da.inputs], "Unlock")
        equal(db.inputs[#db.inputs], "Lock")
        local accepted = assert(server.lastMessage("SlicerCompleted"))
        client.receive(accepted.name, nil, unpackValues(accepted.values))
        equal(#client.chatMessages, 1, "Only accepted completion announces success")
        client.assertClosed()
        equal(server.fire("PlayerUse", owner, da), nil)
        equal(server.fire("PlayerUse", owner, db), false)
    end)

    test("unrelated chat cannot select or link a terminal", function()
        local server, _, owner, alpha, beta = fixture()
        owner.target = alpha
        local noEffects, chats = unchanged(server), #owner.chats
        equal(server.fire("PlayerSay", owner, "hello"), nil)
        equal(owner.SlicerPendingConsole, beta)
        equal(#owner.chats, chats)
        noEffects()
    end)
end

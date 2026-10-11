-- Real client/server callbacks; host doubles do not certify native networking/UI.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local requestName, replyName = "SlicerInitialSetupStatusRequest", "SlicerInitialSetupStatusReply"
    local function count(env, name)
        local n = 0
        for _, packet in ipairs(env.messages) do if packet.name == name then n = n + 1 end end
        return n
    end
    local function copy(values)
        local result = {}
        for key, value in pairs(values) do result[key] = value end
        return result
    end
    local function deliver(client, packet)
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function open(client, owner, console, folder)
        local first = #client.panels + 1
        client.receive("PlayerSpawnedConsole", nil, owner, console:GetName())
        local form, entries = {}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DLabel" then form.status = panel
            elseif panel.text == "Done" then form.done = panel
            elseif panel.text == "Set up later" then form.close = panel end
        end
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        form.name:SetText(" Alpha "); form.delay:SetText("2.5000000001"); form.file:SetText(" Secret ")
        form.folder.selected = folder or "data"
        return form
    end
    local function fixture(folder)
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local console = server.console(owner)
        return server, client, owner, console, open(client, owner, console, folder)
    end
    local function submit(client, form)
        form.done:DoClick()
        return assert(client.lastMessage("AdminFinishedCreation"))
    end
    local function accept(server, owner, packet)
        server.receive("AdminFinishedCreation", owner, packet.values[1])
        local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(reply.values[2].ok, true)
        return reply
    end
    local function locked(form)
        equal(form.frame.valid, true)
        equal(form.name.editable, false); equal(form.delay.editable, false); equal(form.file.editable, false)
        equal(form.folder.enabled, false); equal(form.close.text, "Close")
        equal(form.done.text, "Check setup result", "Pending setup exposes the explicit read-only check")
        equal(form.done.enabled, true)
    end
    local function query(server, owner, fields)
        server.receive(requestName, owner, fields)
        local reply = assert(server.lastMessage(replyName))
        equal(reply.player, owner); equal(reply.values[1], fields[6])
        return reply
    end
    local function check(server, client, owner, form)
        local n = count(client, requestName)
        form.done:DoClick()
        equal(count(client, requestName), n + 1)
        return query(server, owner, client.lastMessage(requestName).values[1])
    end

    for _, folder in ipairs({"data", "server", "tools"}) do
        test("dropped " .. folder .. " initial acknowledgement is recovered without setup replay", function()
            local server, client, owner, console, form = fixture(folder)
            local original = submit(client, form)
            accept(server, owner, original) -- Deliberately drop this genuine reply.
            equal(console.SlicerInformation.name, "alpha")
            equal(#server.returnSpawnedEntities(), 1)
            locked(form)
            local info, selected = console.SlicerInformation, owner.SlicerPendingConsole
            local reply = check(server, client, owner, form)
            equal(reply.values[2].confirmed, true)
            deliver(client, reply)
            equal(form.frame.valid, false)
            equal(console.SlicerInformation, info); equal(owner.SlicerPendingConsole, selected)
            equal(#server.returnSpawnedEntities(), 1)
            equal(count(client, "AdminFinishedCreation"), 1)
            local chats = #owner.chats
            deliver(client, reply); form.done:DoClick()
            equal(#owner.chats, chats); equal(count(client, requestName), 1)
        end)
    end

    test("status is exact for all five raw inputs and authenticated owner/token", function()
        local server, client, owner, console, form = fixture()
        local original = submit(client, form)
        accept(server, owner, original)
        local fields = original.values[1]
        local info, registry = console.SlicerInformation, server.returnSpawnedEntities()[1]
        for _, change in ipairs({{1, "alpha"}, {1, " Alpha"}, {2, 2.5}, {3, "server"},
            {4, "secret"}, {5, "another"}, {6, "9007199254740991"}}) do
            local wrong = copy(fields); wrong[change[1]] = change[2]
            local result = query(server, owner, wrong).values[2]
            equal(result.confirmed, false); equal(result.name, nil); equal(result.fileType, nil)
        end
        local other = server.player()
        equal(query(server, other, fields).values[2].confirmed, false)
        equal(query(server, owner, fields).values[2].confirmed, true)
        equal(console.SlicerInformation, info); equal(server.returnSpawnedEntities()[1], registry)
        equal(count(server, "SlicerInitialSetupReply"), 1)
    end)

    test("query shape validation never mutates or leaks saved settings", function()
        local server, client, owner, console, form = fixture()
        local original = submit(client, form); accept(server, owner, original)
        local fields, info = original.values[1], console.SlicerInformation
        for _, change in ipairs({{1, false}, {1, string.rep("n", 129)}, {2, "2"}, {2, 0}, {2, math.huge},
            {2, 0/0}, {3, {}}, {4, " "}, {4, string.rep("f", 129)}, {5, {}}, {5, string.rep("x", 257)}}) do
            local bad = copy(fields); bad[change[1]] = change[2]
            local result = query(server, owner, bad).values[2]
            equal(result.confirmed, false); equal(result.name, nil); equal(result.fileType, nil)
        end
        local before = #server.messages
        for _, token in ipairs({false, {}, "", "0", "01", "-1", "1.0", "9007199254740992"}) do
            local bad = copy(fields); bad[6] = token
            server.receive(requestName, owner, bad)
        end
        for _, bad in ipairs({false, "bad", {}}) do server.receive(requestName, owner, bad) end
        server.receive(requestName, nil, fields)
        server.receive(requestName, server.entity("prop_physics"), fields)
        equal(#server.messages, before); equal(console.SlicerInformation, info)
        equal(#server.returnSpawnedEntities(), 1)
    end)

    test("maximum token and receipt identity bound preserve initial admission", function()
        for _, length in ipairs({256, 257}) do
            local server = gmod.new(); local owner = server.player(); local console = server.console(owner)
            console:SetName(string.rep("x", length))
            local fields = {"Alpha", 2.5, "data", "File", console:GetName(), "9007199254740991"}
            server.receive("AdminFinishedCreation", owner, fields)
            equal(server.lastMessage("SlicerInitialSetupReply").values[2].ok, true)
            equal(console.SlicerInformation.name, "alpha")
            equal(query(server, owner, fields).values[2].confirmed, length == 256)
        end
    end)

    test("multiple usable player/token receipts stay ambiguous before field matching", function()
        local server, client, owner, console, form = fixture()
        local original = submit(client, form); accept(server, owner, original)
        local beta = server.console(owner)
        local second = copy(original.values[1]); second[1], second[5] = "Beta", beta:GetName()
        server.receive("AdminFinishedCreation", owner, second)
        equal(server.lastMessage("SlicerInitialSetupReply").values[2].ok, true)
        equal(query(server, owner, original.values[1]).values[2].confirmed, false)
        equal(query(server, owner, second).values[2].confirmed, false)
        beta:Remove()
        equal(query(server, owner, original.values[1]).values[2].confirmed, true)
        -- Identical raw identities on distinct configured consoles are also ambiguous.
        beta = server.console(owner); beta:SetName(console:GetName())
        server.receive("AdminFinishedCreation", owner, original.values[1])
        equal(query(server, owner, original.values[1]).values[2].confirmed, false)
    end)

    test("receipt snapshots and replies never alias request or callback tables", function()
        local server, client, owner, console, form = fixture("tools")
        local original = submit(client, form); local fields = copy(original.values[1])
        fields.extra = {large = string.rep("x", 1024)}
        local send = server.net.Send
        local observed = false
        server.net.Send = function(ply)
            local outgoing = server.outgoing
            send(ply)
            if outgoing.name == "SlicerInitialSetupReply" and outgoing.values[2].ok then
                -- A first success callback sees receipt, registry and selection committed.
                equal(console.SlicerInformation.name, "alpha"); equal(owner.SlicerPendingConsole, console)
                equal(#server.returnSpawnedEntities(), 1)
                equal(query(server, owner, fields).values[2].confirmed, true)
                observed = true
            end
        end
        server.receive("AdminFinishedCreation", owner, fields)
        equal(observed, true)
        fields[1], fields[4], fields.extra = "changed", "changed", nil
        local result = query(server, owner, original.values[1]).values[2]
        equal(result.name, "alpha"); equal(result.extra, nil); equal(result.fields, nil)
        result.name, result.fileType, result.confirmed = "mutated", "server", false
        local second = query(server, owner, original.values[1]).values[2]
        equal(second.confirmed, true); equal(second.name, "alpha"); equal(second.fileType, "tools")
    end)

    test("legacy acceptance and duplicate rejection do not invent or replace a receipt", function()
        local server, client, owner, console, form = fixture()
        local original = submit(client, form); local fields = copy(original.values[1])
        fields[6] = nil
        server.receive("AdminFinishedCreation", owner, fields)
        equal(query(server, owner, original.values[1]).values[2].confirmed, false)
        console = server.console(owner)
        fields[5], fields[6] = console:GetName(), "23"
        server.receive("AdminFinishedCreation", owner, fields)
        local wrong = copy(fields); wrong[1], wrong[6] = "wrong", "24"
        server.receive("AdminFinishedCreation", owner, wrong)
        equal(server.lastMessage("SlicerInitialSetupReply").values[2].ok, false)
        equal(query(server, owner, fields).values[2].confirmed, true)
        equal(query(server, owner, wrong).values[2].confirmed, false)
        -- A tokenless out-of-band first-write cannot replace historical evidence.
        console.SlicerInformation = nil; wrong[6] = nil
        server.receive("AdminFinishedCreation", owner, wrong)
        equal(query(server, owner, fields).values[2].confirmed, true)
    end)

    test("a later distinct correlated first-write replaces the single receipt", function()
        local server, client, owner, console, form = fixture()
        local original = submit(client, form); accept(server, owner, original)
        local later = copy(original.values[1]); later[1], later[6] = "Later", "81"
        console.SlicerInformation = nil
        server.receive("AdminFinishedCreation", owner, later)
        equal(query(server, owner, original.values[1]).values[2].confirmed, false)
        equal(query(server, owner, later).values[2].confirmed, true)
    end)

    for _, lifetime in ipairs({"remove", "owner", "creation ID", "entity index", "class", "disconnect", "copy reset", "reinclude"}) do
        test("receipt retirement for " .. lifetime .. " keeps original form locked", function()
            local server, client, owner, console, form = fixture()
            local original = submit(client, form); accept(server, owner, original)
            if lifetime == "remove" then console:Remove()
            elseif lifetime == "owner" then console.SlicerCreator = server.player()
            elseif lifetime == "creation ID" then console.id = console.id + 1
            elseif lifetime == "entity index" then console.EntIndex = function() return -1 end
            elseif lifetime == "class" then console.class = "prop_physics"
            elseif lifetime == "disconnect" then server.fire("PlayerDisconnected", owner)
            elseif lifetime == "copy reset" then console:OnDuplicated()
            else server.include("autorun/server/sv_config.lua") end
            local result = check(server, client, owner, form)
            equal(result.values[2].confirmed, false); deliver(client, result); locked(form)
            assert(form.status.text:find("may already have been accepted", 1, true))
            equal(count(client, "AdminFinishedCreation"), 1)
            if lifetime == "owner" then
                console.SlicerCreator = owner
                equal(query(server, owner, original.values[1]).values[2].confirmed, false, "Pruned owner receipt cannot return")
            elseif lifetime == "disconnect" then
                equal(query(server, owner, original.values[1]).values[2].confirmed, false, "Same player reference cannot reconnect into receipt")
            end
        end)
    end

    test("pasted copy and recycled entity indices cannot acquire original receipt", function()
        local server, client, owner, console, form = fixture()
        local original = submit(client, form); accept(server, owner, original)
        local pasted = server.console(owner)
        pasted.SlicerInformation = console.SlicerInformation; pasted:OnDuplicated(); pasted:PostEntityPaste(owner)
        local fields = copy(original.values[1]); fields[5] = pasted:GetName()
        equal(query(server, owner, fields).values[2].confirmed, false)
        equal(query(server, owner, original.values[1]).values[2].confirmed, true)
        local index, creation = console:EntIndex(), console:GetCreationID()
        console:Remove()
        local recycled = server.console(owner); recycled:SetName(original.values[1][5])
        recycled.EntIndex = function() return index end; recycled.id = creation
        recycled.SlicerInformation = pasted.SlicerInformation
        equal(query(server, owner, original.values[1]).values[2].confirmed, false)
    end)

    test("saved edits preserve historical acceptance without claiming current settings", function()
        local server, client, owner, console, form = fixture("tools")
        local original = submit(client, form); accept(server, owner, original)
        owner.target = console; server.fire("PlayerSay", owner, "!editConsole")
        local edit = assert(server.lastMessage("SlicerSetupEditOpen"))
        server.receive("SlicerSetupEditSave", owner, console, edit.values[3], {name = "Renamed", delay = 99, fileName = "Changed"})
        equal(server.lastMessage("SlicerSetupEditReply").values[2].ok, true)
        local info = console.SlicerInformation
        local result = check(server, client, owner, form)
        equal(result.values[2].name, "alpha"); deliver(client, result)
        equal(console.SlicerInformation, info); equal(info.name, "renamed"); equal(info.delay, 99)
        assert(table.concat(owner.chats, "\n"):find("saved settings may have changed", 1, true))
    end)

    test("unknown original can later arrive or reject without unlocking on status", function()
        local server, client, owner, console, form = fixture()
        local original = submit(client, form)
        deliver(client, check(server, client, owner, form)); locked(form)
        equal(console.SlicerInformation, nil)
        accept(server, owner, original)
        client.now = 2
        deliver(client, check(server, client, owner, form)); equal(form.frame.valid, false)
        local rejected = open(client, owner, server.console(owner))
        local packet = submit(client, rejected)
        packet.values[1][5] = "missing"
        server.receive("AdminFinishedCreation", owner, packet.values[1])
        local rejection = server.lastMessage("SlicerInitialSetupReply")
        deliver(client, check(server, client, owner, rejected)); locked(rejected)
        deliver(client, rejection)
        equal(rejected.name.editable, true); equal(rejected.done.text, "Done")
        equal(rejected.close.text, "Set up later")
        local oldToken = packet.values[1][6]
        local nextPacket = submit(client, rejected)
        assert(nextPacket.values[1][6] ~= oldToken)
        client.receive(replyName, nil, oldToken, {confirmed = true, name = "alpha", fileType = "data"})
        locked(rejected)
    end)

    test("manual checks retain frozen fields and token with cooldown but no automatic traffic", function()
        local server, client, owner, _, form = fixture()
        local original = submit(client, form); accept(server, owner, original)
        local events = #client.timerEvents
        form.name:SetText("Changed locally"); form.delay:SetText("999"); form.file:SetText("Different")
        form.folder.selected = "tools"
        local result = check(server, client, owner, form)
        for i = 1, 6 do equal(client.lastMessage(requestName).values[1][i], original.values[1][i]) end
        equal(result.values[2].confirmed, true) -- Deliberately lose status reply too.
        form.done:DoClick(); client.now = 1.999; form.done:DoClick()
        equal(count(client, requestName), 1)
        client.now = 2; form.done:DoClick(); equal(count(client, requestName), 2)
        client.now = 200; client.fire("Think")
        equal(count(client, requestName), 2); equal(count(client, "AdminFinishedCreation"), 1)
        equal(#client.timerEvents, events)
        deliver(client, result); equal(form.frame.valid, false)
    end)

    test("older server query-start failure leaves pending setup recoverable by its original reply", function()
        local server, client, owner, _, form = fixture()
        local original = submit(client, form); local accepted = accept(server, owner, original)
        local start, attempts = client.net.Start, 0
        client.net.Start = function(name)
            if name == requestName then attempts = attempts + 1; error("unpooled network string") end
            return start(name)
        end
        form.done:DoClick(); locked(form)
        equal(attempts, 1); equal(count(client, requestName), 0); equal(count(client, "AdminFinishedCreation"), 1)
        assert(form.status.text:find("unavailable on this server", 1, true))
        form.done:DoClick(); equal(attempts, 1)
        client.now = 2; form.done:DoClick(); equal(attempts, 2)
        deliver(client, accepted); equal(form.frame.valid, false)
    end)

    test("reentrant query clicks and synchronous replies respect exact ownership", function()
        local server, client, owner, _, form = fixture()
        local original = submit(client, form); accept(server, owner, original)
        local send = client.net.SendToServer
        client.net.SendToServer = function()
            local outgoing = client.outgoing
            form.done:DoClick()
            send()
            if outgoing.name == requestName then deliver(client, query(server, owner, outgoing.values[1])) end
        end
        form.done:DoClick()
        equal(count(client, requestName), 1); equal(count(client, "AdminFinishedCreation"), 1)
        equal(form.frame.valid, false)
    end)

    for _, outcome in ipairs({"accept", "reject", "close and replace"}) do
        test("initial synchronous " .. outcome .. " cannot enable a stale Check action", function()
            local server, client, owner, console, form = fixture()
            local send, replacement = client.net.SendToServer
            client.net.SendToServer = function()
                local outgoing = client.outgoing
                equal(form.done.enabled, false); equal(form.done.text, "Done")
                form.done:DoClick(); equal(count(client, requestName), 0)
                send()
                if outcome == "accept" then deliver(client, accept(server, owner, outgoing))
                elseif outcome == "reject" then
                    client.receive("SlicerInitialSetupReply", nil, outgoing.values[1][6], {ok = false, message = "Rejected"})
                else form.close:DoClick(); replacement = open(client, owner, console) end
            end
            submit(client, form)
            equal(count(client, "AdminFinishedCreation"), 1); equal(count(client, requestName), 0)
            if outcome == "reject" then equal(form.done.text, "Done"); equal(form.name.editable, true)
            elseif replacement then equal(replacement.done.text, "Done"); equal(replacement.name.editable, true)
            else equal(form.frame.valid, false) end
        end)
    end

    for _, invalid in ipairs({false, "bad", {}, {confirmed = "true"}, {confirmed = true},
        {confirmed = true, name = "", fileType = "data"}, {confirmed = true, name = string.rep("x", 129), fileType = "data"},
        {confirmed = true, name = "alpha", fileType = "tools"}}) do
        test("malformed status response cannot resolve a pending form " .. tostring(invalid), function()
            local server, client, owner, _, form = fixture()
            local original = submit(client, form); local accepted = accept(server, owner, original)
            client.receive(replyName, nil, original.values[1][6], invalid); locked(form)
            client.receive(replyName, nil, "unknown", {confirmed = true, name = "alpha", fileType = "data"}); locked(form)
            deliver(client, accepted); equal(form.frame.valid, false)
        end)
    end

    for _, retirement in ipairs({"Close", "Remove", "Hide"}) do
        test("status cannot revive " .. retirement .. " or resolve its replacement", function()
            local server, client, owner, console, old = fixture("tools")
            local original = submit(client, old); accept(server, owner, original)
            local result = check(server, client, owner, old)
            client.deferPanelRemoval = true
            old.frame[retirement](old.frame)
            local fresh = open(client, owner, console, "tools")
            local nextPacket = submit(client, fresh)
            local before, chats = #client.messages, #owner.chats
            deliver(client, result); old.done:DoClick(); old.close:DoClick()
            old.frame:OnClose(); old.frame:OnRemove()
            equal(#client.messages, before); equal(#owner.chats, chats); locked(fresh)
            server.receive("AdminFinishedCreation", owner, nextPacket.values[1])
            deliver(client, server.lastMessage("SlicerInitialSetupReply"))
            equal(fresh.done.text, "Done"); equal(fresh.name.editable, true)
        end)
    end

    test("pending recovery survives client reinclude, death and respawn", function()
        local server, client, owner, _, form = fixture()
        local original = submit(client, form); accept(server, owner, original)
        client.include("entities/consoleent/cl_init.lua")
        owner.alive = false; server.fire("PlayerDeath", owner)
        form.done:DoClick(); equal(count(client, requestName), 0); locked(form)
        owner.alive = true
        local result = check(server, client, owner, form)
        equal(result.values[2].confirmed, true); deliver(client, result); equal(form.frame.valid, false)
    end)

    test("two simultaneous forms handle reordered status and original acknowledgements", function()
        local server, client, owner, _, alpha = fixture("tools")
        local betaConsole = server.console(owner); local beta = open(client, owner, betaConsole, "server")
        beta.name:SetText("Beta")
        local a, b = submit(client, alpha), submit(client, beta)
        local aAck = accept(server, owner, a); accept(server, owner, b)
        local aStatus, bStatus = check(server, client, owner, alpha), check(server, client, owner, beta)
        deliver(client, bStatus); equal(beta.frame.valid, false); locked(alpha)
        deliver(client, aAck); equal(alpha.frame.valid, false)
        local chats = #owner.chats
        deliver(client, aStatus); deliver(client, bStatus)
        equal(#owner.chats, chats); equal(count(client, "AdminFinishedCreation"), 2)
    end)

    test("tools recovery preserves Beta selection, links and unrelated hacking deadline", function()
        local server, client, owner, alpha, form = fixture("tools")
        local original = submit(client, form); accept(server, owner, original)
        local linked = server.console(owner); server.configure(owner, linked, "tools", 4)
        local door = server.entity("func_door_rotating")
        owner.target = door; server.fire("PlayerSay", owner, "!setEntity")
        local hacker = server.player(); server.open(hacker, linked)
        local hackPacket = server.lastMessage("ServerSendsEntityInformation")
        local beta = server.console(owner); server.configure(owner, beta, "tools")
        local selected, info, record = owner.SlicerPendingConsole, linked.SlicerInformation, server.returnSpawnedEntities()[2]
        deliver(client, hackPacket); client.command("/a[terminal]")
        local timer = client.timers.AccessDelay
        local result = check(server, client, owner, form); deliver(client, result)
        equal(owner.SlicerPendingConsole, selected); equal(selected, beta)
        equal(linked.SlicerInformation, info); equal(server.returnSpawnedEntities()[2], record)
        equal(info.inUse, true); equal(client.timers.AccessDelay, timer); equal(linked.SlicerDoor, door)
        equal(#door.inputs, 1); equal(door.inputs[1], "Lock"); equal(alpha.SlicerDoor, nil)
        local guidance = table.concat(owner.chats, "\n")
        assert(guidance:find("accepted earlier", 1, true)); assert(guidance:find("!cancelLink", 1, true))
        local consoleFirst = assert(guidance:find("!setEntity", 1, true))
        assert(guidance:find("intended door", consoleFirst, true))
        -- The original four-second tools deadline is neither released nor extended.
        server.now = 4; server.receive("PlayerActivatedDoor", hacker, linked)
        equal(linked.removed, true); equal(door.inputs[2], "Unlock")
        equal(owner.SlicerPendingConsole, beta)
    end)

    test("historical tools guidance sanitizes maximum names and fits each chat packet", function()
        local server, client, owner, _, form = fixture("tools")
        form.name:SetText(string.rep("N", 120) .. "\0\1\31\127zzzz")
        local original = submit(client, form); accept(server, owner, original)
        local before = #owner.chats
        deliver(client, check(server, client, owner, form))
        equal(#owner.chats, before + 3)
        for i = before + 1, #owner.chats do
            assert(#owner.chats[i] <= 255); assert(not owner.chats[i]:find("[%z\1-\31\127]"))
        end
    end)
end

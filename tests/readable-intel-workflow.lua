-- Actual server/client callbacks with explicit transport delivery or loss.
-- This models addon authority and state transitions; it does not qualify native
-- multiplayer recipient routing, Duplicator export, UTF-8 rendering or lifecycle.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local secret = "INTEL_ONLY: Report to Gate 7\nDo not change CASE."
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile"},
    }
    local function wire(env)
        env.net.WriteBool = env.net.WriteBool or env.net.WriteString
        env.net.ReadBool = env.net.ReadBool or env.net.ReadString
        return env
    end
    local function fixture(folder)
        local env = wire(gmod.new())
        local owner, hacker, stranger = env.player(), env.player(), env.player()
        local console = env.console(owner)
        env.configure(owner, console, folder or "data")
        assert(env.slicerIntel, "Missing server intel API")
        if folder ~= "tools" then assert(env.slicerIntel.SetBody(console, secret)) end
        return env, owner, hacker, stranger, console
    end
    local function packets(env, name, first)
        local found = {}
        for index = first or 1, #env.messages do
            if env.messages[index].name == name then found[#found + 1] = env.messages[index] end
        end
        return found
    end
    local function intel(packet, ply, body, recovery)
        assert(packet, "Missing private intel packet")
        equal(packet.name, "SlicerIntel"); equal(packet.player, ply); equal(#packet.values, 6)
        for index = 1, 5 do equal(type(packet.values[index]), "string") end
        equal(packet.values[5], body); equal(packet.values[6], recovery)
        return packet.values[1]
    end
    local function read(env, ply)
        env.now = env.now + 1
        local before = #env.messages
        equal(env.fire("PlayerSay", ply, "!readIntel"), "")
        local sent = packets(env, "SlicerIntel", before + 1)
        assert(#sent <= 1, "Recovery sends at most one record")
        return sent[1]
    end
    local function finish(env, ply, console, message)
        local before = #env.messages
        env.open(ply, console)
        env.now = env.now + console.SlicerInformation.delay * (message == "PlayerActivatedDoor" and 1 or 2)
        env.receive(message or "destroyOnServer", ply, console)
        return packets(env, "SlicerIntel", before + 1)[1]
    end
    local function addConsole(env, owner, folder, body)
        local console = env.console(owner)
        env.configure(owner, console, folder or "data")
        if body then assert(env.slicerIntel.SetBody(console, body)) end
        return console
    end
    local function deliver(client, packet)
        assert(packet, "Missing packet to relay")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    local function reader(client, body)
        local found, count
        count = 0
        for _, panel in ipairs(client.panels) do
            if live(panel) and panel.class == "DTextEntry" and panel:GetValue() == body then
                found, count = panel, count + 1
            end
        end
        equal(count, 1, "One current reader renders the exact literal body")
        equal(found.editable, false); equal(found.OnEnter, nil)
        local frame = found
        while frame.parent do frame = frame.parent end
        return found, frame
    end
    local function editor(env, client, owner, console)
        owner.target = console
        local sent = #env.messages
        equal(env.fire("PlayerSay", owner, "!editConsole"), "")
        equal(#env.messages, sent + 1)
        local packet, first = env.messages[#env.messages], #client.panels + 1
        equal(packet.name, "SlicerSetupEditOpen"); equal(packet.player, owner)
        deliver(client, packet)
        local form, entries = {packet = packet}, {}
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DButton" and panel:GetValue() == "Save changes" then form.save = panel
            elseif panel.class == "DButton" and panel:GetValue() == "Cancel" then form.cancel = panel end
        end
        equal(#entries, 4, "Data/server editor exposes metadata and optional intel")
        form.name, form.delay, form.fileName, form.body = entries[1], entries[2], entries[3], entries[4]
        assert(form.frame and form.save and form.cancel)
        return form
    end
    local function commandEntry(client)
        for index = #client.panels, 1, -1 do
            local panel = client.panels[index]
            if live(panel) and panel.class == "DTextEntry" and panel.OnEnter then return panel end
        end
        error("No live terminal command input")
    end
    local function noBody(value, seen)
        if type(value) == "string" then assert(not value:find("INTEL_ONLY", 1, true), "Intel leaked into public/copied data")
        elseif type(value) == "table" then
            if value.GetCreationID then return end -- Entity references are modeled, not recursively exported.
            seen = seen or {}; if seen[value] then return end; seen[value] = true
            for key, item in pairs(value) do noBody(key, seen); noBody(item, seen) end
        end
    end

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " actual download delivers ordinary success then one private literal reader", function()
            local env, _, hacker, stranger, console = fixture(kind.folder)
            local client = wire(gmod.client())
            env.open(hacker, console)
            local opening = assert(env.lastMessage("ServerSendsEntityInformation"))
            noBody(opening.values); deliver(client, opening)
            client.command("/a[terminal]"); client.fireTimer("AccessDelay")
            client.command("/a[terminal]/{_" .. kind.folder .. "}")
            client.command("/d{_" .. kind.folder .. "}/secret." .. kind.extension)
            client.fireTimer(kind.timer)
            client.assertClosed()
            local submitted = assert(client.lastMessage("destroyOnServer"))
            env.now = 4
            local before = #env.messages
            env.receive(submitted.name, hacker, unpackValues(submitted.values))
            equal(console.removed, true); equal(env.slicerIntel.GetBody(console), "")
            equal(#env.messages, before + 2)
            local completed, awarded = env.messages[before + 1], env.messages[before + 2]
            equal(completed.name, "SlicerCompleted"); equal(completed.player, hacker)
            equal(#completed.values, 4)
            equal(completed.values[1], "terminal"); equal(completed.values[2], "secret")
            equal(completed.values[3], kind.folder); equal(completed.values[4], hacker:GetName())
            intel(awarded, hacker, secret, false)
            equal(awarded.values[2], "terminal"); equal(awarded.values[3], "secret"); equal(awarded.values[4], kind.folder)
            deliver(client, completed); equal(#client.chatMessages, 1)
            deliver(client, awarded); reader(client, secret)
            noBody(client.chatMessages); equal(#stranger.chats, 0)
            local sent, announced, panels = #client.messages, #client.chatMessages, #client.panels
            deliver(client, awarded)
            reader(client, secret); equal(#client.messages, sent); equal(#client.chatMessages, announced)
            equal(#client.panels, panels, "Duplicate transport cannot create another reader")
        end)
    end

    test("lost intel edit reply is recovered by ordinary close and reopen without undoing the accepted save", function()
        local env, owner, _, _, console = fixture()
        local client = wire(gmod.client())
        local form = editor(env, client, owner, console)
        local raw = "  New CASE-sensitive clue\r\nSecond line\r\tFinal  "
        local canonical = "  New CASE-sensitive clue\nSecond line\n\tFinal  "
        form.name:SetText(" Saved Console "); form.delay:SetText("2.5")
        form.fileName:SetText(" Next Clue "); form.body:SetText(raw)
        form.save:DoClick()
        local request = assert(client.lastMessage("SlicerSetupEditSave"))
        equal(request.values[3].intelBody, canonical)
        for _, input in ipairs({form.name, form.delay, form.fileName, form.body}) do equal(input.editable, false) end
        equal(form.save:IsEnabled(), false); equal(form.cancel:GetValue(), "Close")
        env.receive(request.name, owner, unpackValues(request.values))
        local lostReply = assert(env.lastMessage("SlicerSetupEditReply"))
        equal(lostReply.values[2].ok, true)
        equal(console.SlicerInformation.name, "saved console"); equal(console.SlicerInformation.delay, 2.5)
        equal(console.SlicerInformation.fileName, "next clue"); equal(env.slicerIntel.GetBody(console), canonical)
        equal(live(form.frame), true, "The undelivered reply cannot close the client form")
        form.cancel:DoClick()
        local cancellation = assert(client.lastMessage("SlicerSetupEditCancel"))
        env.receive(cancellation.name, owner, unpackValues(cancellation.values))
        equal(live(form.frame), false); equal(env.slicerIntel.GetBody(console), canonical)
        local reopened = editor(env, client, owner, console)
        assert(reopened.packet.values[3] ~= form.packet.values[3], "Accepted edit ticket cannot be revived")
        equal(reopened.packet.values[4].intelBody, canonical)
        equal(reopened.name:GetValue(), "saved console"); equal(tonumber(reopened.delay:GetValue()), 2.5)
        equal(reopened.fileName:GetValue(), "next clue"); equal(reopened.body:GetValue(), canonical)
        deliver(client, lostReply)
        equal(live(reopened.frame), true, "A delayed old reply cannot close the fresh editor")
        equal(reopened.body.editable, true); equal(reopened.body:GetValue(), canonical)
        equal(#packets(client, "SlicerSetupEditSave"), 1, "Readback needs no save retry or new receipt protocol")
    end)

    test("reader close and recovery preserve a live terminal draft, history and tool through ordinary death cleanup", function()
        local env, owner, hacker, _, first = fixture()
        local awarded = finish(env, hacker, first)
        local client = wire(gmod.client())
        deliver(client, awarded)
        local _, firstReader = reader(client, secret)
        local active = addConsole(env, owner, "server")
        env.open(hacker, active)
        deliver(client, assert(env.lastMessage("ServerSendsEntityInformation")))
        equal(live(firstReader), true, "Opening the terminal must preserve the separate reader")
        client.command("invalid-on-purpose")
        local input = commandEntry(client)
        input:SetText("/a[unfinished draft")
        input.HistoryPos = 1
        local history, historyText = input.History, table.concat(input.History, "\n")
        local sent, historyCalls, tool = #client.messages, #client.historyCalls, hacker:GetActiveWeapon()
        firstReader:Close()
        equal(commandEntry(client), input); equal(input:GetValue(), "/a[unfinished draft")
        deliver(client, read(env, hacker))
        local _, reopened = reader(client, secret)
        assert(reopened ~= firstReader)
        equal(commandEntry(client), input); equal(input:GetValue(), "/a[unfinished draft")
        equal(input.History, history); equal(table.concat(input.History, "\n"), historyText)
        equal(input.HistoryPos, 1); equal(#client.historyCalls, historyCalls)
        equal(#client.messages, sent); equal(hacker:GetActiveWeapon(), tool)
        equal(active.SlicerInformation.inUse, true); equal(active.removed, nil)
        equal(#packets(client, "playerQuitConsole"), 0); equal(#packets(client, "destroyOnServer"), 0)
        hacker.alive = false; env.fire("PlayerDeath", hacker)
        deliver(client, assert(env.lastMessage("PlayerDied")))
        equal(live(input), false); equal(active.SlicerInformation.inUse, false)
        equal(active.removed, nil); equal(live(reopened), true)
        local recovered = read(env, hacker)
        equal(intel(recovered, hacker, secret, true), awarded.values[1])
        deliver(client, recovered); reader(client, secret)
        equal(#client.messages, sent); equal(#packets(env, "SlicerCompleted"), 1)
        equal(hacker:GetActiveWeapon(), tool)
    end)

    test("accepted award is recoverable inside OnRemove and retains captured metadata after it changes", function()
        local env, _, hacker, _, console = fixture()
        local remove, recovered = console.OnRemove
        console.OnRemove = function(self)
            equal(env.slicerIntel.GetBody(self), secret)
            equal(env.fire("PlayerSay", hacker, "!readIntel"), "")
            recovered = assert(env.lastMessage("SlicerIntel"))
            intel(recovered, hacker, secret, true)
            self.SlicerInformation.name, self.SlicerInformation.fileName = "Changed during removal", "Changed file"
            remove(self)
        end
        local awarded = finish(env, hacker, console)
        assert(recovered, "Player record must exist before OnRemove")
        local initial = packets(env, "SlicerIntel")
        equal(#initial, 2)
        awarded = initial[2]
        intel(awarded, hacker, secret, false)
        equal(awarded.values[1], recovered.values[1]); equal(awarded.values[2], "terminal")
        equal(awarded.values[3], "secret"); equal(awarded.values[4], "data")
        local completed = assert(env.lastMessage("SlicerCompleted"))
        equal(#completed.values, 4); equal(completed.values[1], "terminal")
        equal(completed.values[2], "secret"); equal(completed.values[3], "data")
        equal(completed.values[4], hacker:GetName())
        equal(env.slicerIntel.GetBody(console), "")
        local later = read(env, hacker)
        equal(intel(later, hacker, secret, true), awarded.values[1]); equal(later.values[2], "terminal")
    end)

    test("dropped initial and recovery packets keep the award available without replaying completion", function()
        local env, _, hacker, _, console = fixture()
        local send, dropped = env.net.Send, 0
        env.net.Send = function(ply)
            if env.outgoing.name == "SlicerIntel" then
                dropped = dropped + 1; env.outgoing = nil
            else send(ply) end
        end
        equal(finish(env, hacker, console), nil); equal(dropped, 1); equal(console.removed, true)
        equal(read(env, hacker), nil); equal(dropped, 2)
        env.net.Send = send
        local recovered = read(env, hacker)
        intel(recovered, hacker, secret, true)
        equal(#packets(env, "SlicerCompleted"), 1)
        equal(console.SlicerInformation.inUse, false)
        local client = wire(gmod.client())
        deliver(client, recovered)
        local _, frame = reader(client, secret)
        frame:Close()
        deliver(client, read(env, hacker)); reader(client, secret)
        equal(#client.messages, 0, "Reading must not send a completion, quit or reward request")
        equal(#packets(env, "SlicerCompleted"), 1)
    end)

    test("dead and respawned downloader recovers without a tool while another player receives no record", function()
        local env, _, hacker, stranger, console = fixture()
        local first = finish(env, hacker, console)
        hacker.alive, hacker.weapon = false, nil
        env.fire("PlayerDeath", hacker)
        equal(intel(read(env, hacker), hacker, secret, true), first.values[1])
        hacker.alive = true; env.fire("PlayerSpawn", hacker)
        equal(intel(read(env, hacker), hacker, secret, true), first.values[1])
        local before = #stranger.chats
        equal(read(env, stranger), nil)
        assert(#stranger.chats == before + 1 and stranger.chats[#stranger.chats]:lower():find("no mission intel", 1, true))
        noBody(stranger.chats)
        equal(#packets(env, "SlicerCompleted"), 1)
    end)

    test("readIntel accepts no target or award argument and rate limits each sender independently", function()
        local env, _, hacker, stranger, console = fixture()
        local awarded = finish(env, hacker, console)
        local before, requestedAt = #env.messages, env.now
        env.fire("PlayerSay", hacker, "!readIntel")
        equal(#env.messages, before + 1)
        env.now = requestedAt + 0.999
        env.fire("PlayerSay", hacker, "!readIntel")
        equal(#env.messages, before + 1)
        local strangerChats = #stranger.chats
        env.fire("PlayerSay", stranger, "!readIntel")
        equal(#stranger.chats, strangerChats + 1, "Another player's throttle is independent")
        env.now = requestedAt + 1
        env.fire("PlayerSay", hacker, "!readIntel")
        equal(#env.messages, before + 2)
        for _, command in ipairs({"!readIntel " .. awarded.values[1], "!readIntel " .. hacker:SteamID64(),
            "!readIntel 1", "!readIntel secret.data"}) do
            env.now = env.now + 1
            local count = #env.messages
            equal(env.fire("PlayerSay", stranger, command), "")
            equal(#env.messages, count, "Client text cannot select another player's record")
        end
        noBody(stranger.chats)
        env.now = env.now + 1
        local count = #env.messages
        for _, command in ipairs({"!readintel", "!ReadIntel", " !readIntel"}) do
            equal(env.fire("PlayerSay", hacker, command), nil)
        end
        equal(#env.messages, count)
    end)

    for _, reason in ipairs({"no session", "wrong sender", "early", "wrong type", "lost tool", "dead", "quit", "manual removal",
        "console generation", "console index", "player generation", "player index"}) do
        test("rejected intel completion after " .. reason .. " neither awards nor consumes a live console", function()
            local env, _, hacker, stranger, console = fixture()
            if reason ~= "no session" then env.open(hacker, console) end
            env.now = reason == "early" and 0 or 4
            if reason == "lost tool" then hacker.weapon = nil
            elseif reason == "dead" then hacker.alive = false; env.fire("PlayerDeath", hacker)
            elseif reason == "quit" then env.receive("playerQuitConsole", hacker)
            elseif reason == "manual removal" then console:Remove()
            elseif reason:find("generation", 1, true) or reason:find("index", 1, true) then
                local target = reason:find("player", 1, true) and hacker or console
                local key = reason:find("index", 1, true) and "EntIndex" or "GetCreationID"
                local original = target[key]
                target[key] = function(self) return original(self) + 1000 end
            end
            env.receive(reason == "wrong type" and "PlayerActivatedDoor" or "destroyOnServer",
                reason == "wrong sender" and stranger or hacker, console)
            equal(#packets(env, "SlicerCompleted"), 0); equal(#packets(env, "SlicerIntel"), 0)
            equal(console.removed, reason == "manual removal" and true or nil)
            equal(read(env, hacker), nil); equal(read(env, stranger), nil)
            if reason == "wrong sender" then equal(console.SlicerInformation.inUse, true) end
        end)
    end

    test("duplicate completion packets cannot award twice or replace the captured record", function()
        local env, _, hacker, stranger, console = fixture()
        local awarded = finish(env, hacker, console)
        local count = #env.messages
        env.receive("destroyOnServer", hacker, console)
        env.receive("destroyOnServer", stranger, console)
        env.receive("PlayerActivatedDoor", hacker, console)
        equal(#env.messages, count); equal(#packets(env, "SlicerCompleted"), 1)
        equal(intel(read(env, hacker), hacker, secret, true), awarded.values[1])
    end)

    test("newer nonblank intel replaces the latest pointer and display while prior awards stay saved", function()
        local env, owner, hacker, _, first = fixture()
        local older = finish(env, hacker, first) -- Intentionally never delivered to a client.
        local second = addConsole(env, owner, "server", "New mission intel")
        local newer = finish(env, hacker, second)
        assert(tonumber(newer.values[1]) > tonumber(older.values[1]))
        equal(intel(read(env, hacker), hacker, "New mission intel", true), newer.values[1])
        local metadata = addConsole(env, owner, "data")
        equal(finish(env, hacker, metadata), nil); equal(metadata.removed, true)
        local tools = addConsole(env, owner, "tools")
        local door = env.entity("func_door")
        owner.target = tools; env.fire("PlayerSay", owner, "!setEntity")
        owner.target = door; env.fire("PlayerSay", owner, "!setEntity")
        equal(finish(env, hacker, tools, "PlayerActivatedDoor"), nil)
        equal(tools.removed, true); equal(door.inputs[#door.inputs], "Unlock")
        equal(intel(read(env, hacker), hacker, "New mission intel", true), newer.values[1])
        equal(#packets(env, "SlicerCompleted"), 4)
        local client = wire(gmod.client())
        deliver(client, newer); deliver(client, older); reader(client, "New mission intel")
    end)

    for _, event in ipairs({"PlayerDisconnected", "PlayerInitialSpawn"}) do
        test(event .. " clears only that connection record and throttle", function()
            local env, owner, hacker, stranger, console = fixture()
            finish(env, hacker, console)
            local other = addConsole(env, owner, "data", "Other player's clue")
            local otherAward = finish(env, stranger, other)
            read(env, hacker)
            env.fire(event, hacker)
            local before = #hacker.chats
            env.fire("PlayerSay", hacker, "!readIntel")
            equal(#hacker.chats, before + 1, "A reset connection does not inherit the old throttle")
            noBody(hacker.chats)
            equal(intel(read(env, stranger), stranger, "Other player's clue", true), otherAward.values[1])
        end)
    end

    for _, identity in ipairs({"creation ID", "entity index", "new wrapper"}) do
        test("reused player " .. identity .. " cannot recover a prior connection record", function()
            local env, _, hacker, _, console = fixture()
            finish(env, hacker, console)
            local actor = hacker
            if identity == "new wrapper" then
                actor = env.player()
                actor.GetCreationID = function() return hacker:GetCreationID() end
                actor.EntIndex = function() return hacker:EntIndex() end
                actor.SteamID64 = function() return hacker:SteamID64() end
            else
                local key = identity == "creation ID" and "GetCreationID" or "EntIndex"
                local original = hacker[key]
                hacker[key] = function(self) return original(self) + 1000 end
            end
            equal(read(env, actor), nil); noBody(actor.chats)
        end)
    end

    test("reinclude retains the current award and strictly increasing IDs without sharing into a new map", function()
        local env, owner, hacker, _, console = fixture()
        local original = finish(env, hacker, console)
        for _, path in ipairs({"autorun/server/sv_slicer_intel.lua", "autorun/server/sv_config.lua",
            "entities/consoleent/init.lua"}) do env.include(path) end
        equal(intel(read(env, hacker), hacker, secret, true), original.values[1])
        local nextConsole = addConsole(env, owner, "data", "Later clue")
        local newer = finish(env, hacker, nextConsole)
        assert(tonumber(newer.values[1]) > tonumber(original.values[1]))
        local fresh, _, freshHacker = fixture()
        equal(freshHacker:GetCreationID(), hacker:GetCreationID())
        equal(read(fresh, freshHacker), nil)
    end)

    test("last exact award serial succeeds and exhaustion preserves the last record and remaining console", function()
        local env, owner, hacker, _, console = fixture()
        local award = env.slicerIntel.Award
        local serialIndex
        -- The only private access in this suite injects an otherwise infeasible
        -- numeric boundary into this isolated fixture, never a production hook.
        for index = 1, 40 do
            local name = debug.getupvalue(award, index)
            if not name then break end
            if name == "awardSerial" then serialIndex = index; break end
        end
        assert(serialIndex, "Missing award serial boundary fixture")
        equal(debug.setupvalue(award, serialIndex, 9007199254740990), "awardSerial")
        local last = finish(env, hacker, console)
        equal(intel(last, hacker, secret, false), "9007199254740991")
        local remaining = addConsole(env, owner, "data", "Cannot wrap")
        equal(finish(env, hacker, remaining), nil)
        equal(remaining.removed, nil); equal(remaining.SlicerInformation.inUse, false)
        equal(env.slicerIntel.GetBody(remaining), "Cannot wrap")
        equal(#packets(env, "SlicerCompleted"), 1)
        equal(intel(read(env, hacker), hacker, secret, true), last.values[1])
        env.include("autorun/server/sv_slicer_intel.lua")
        equal(finish(env, hacker, remaining), nil); equal(remaining.removed, nil)
        equal(intel(read(env, hacker), hacker, secret, true), last.values[1])
    end)

    for _, kind in ipairs(kinds) do
        for _, busy in ipairs({false, true}) do
            for _, creatorCopies in ipairs({false, true}) do
                test(kind.folder .. " " .. (busy and "busy" or "idle") .. " duplication by " ..
                    (creatorCopies and "creator" or "other player") .. " omits body visibly without changing original", function()
                    local env, owner, hacker, stranger, original = fixture(kind.folder)
                    local actor = creatorCopies and owner or stranger
                    if busy then env.open(hacker, original) end
                    -- The generic copy sees every entity Lua field. Functions
                    -- and entity references stand in for native opaque values.
                    local data = {}
                    for key, value in pairs(original) do
                        if type(value) ~= "function" then data[key] = value end
                    end
                    original:OnEntityCopyTableFinish(data)
                    noBody(data); equal(data.SlicerCreator, nil); equal(data.SlicerDoor, nil)
                    equal(env.slicerIntel.GetBody(original), secret)
                    local pasted = setmetatable(env.entity("consoleent"), {__index = env.ENT})
                    pasted:Initialize()
                    pasted.SlicerInformation = env.table.Copy(data.SlicerInformation)
                    pasted:OnDuplicated(data)
                    equal(env.slicerIntel.GetBody(pasted), "")
                    local before = #actor.chats
                    pasted:PostEntityPaste(actor, pasted, {})
                    equal(pasted.SlicerCreator, actor); equal(env.slicerIntel.GetBody(pasted), "")
                    equal(pasted.SlicerInformation.fileType, kind.folder)
                    equal(pasted.SlicerInformation.inUse, false)
                    assert(#actor.chats > before, "Data/server paste must disclose the omitted intel")
                    local feedback = table.concat(actor.chats, "\n", before + 1)
                    assert(feedback:lower():find("no mission intel", 1, true))
                    assert(feedback:find("!editConsole", 1, true))
                    equal(env.slicerIntel.GetBody(original), secret)
                    equal(original.SlicerInformation.inUse, busy)
                    equal(finish(env, actor, pasted), nil); equal(pasted.removed, true)
                    equal(env.slicerIntel.GetBody(original), secret)
                    if busy then
                        env.now = env.now + 4; env.receive("destroyOnServer", hacker, original)
                        intel(env.lastMessage("SlicerIntel"), hacker, secret, false)
                    end
                end)
            end
        end
    end
end

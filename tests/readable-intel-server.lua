-- Actual validator, edit/chat handlers and entity callbacks with the GMod host
-- substitutions. Source-only draft: native codec, userdata and export behavior
-- need separate evidence. No closure state or test-only production hook is used.
return function(gmod, test, equal)
    local secret = "INTEL_ONLY: Meet Commander Rook at Gate 7\nKeep CASE and  two spaces."
    local function fixture(folder)
        local env = gmod.new()
        env.net.WriteBool = env.net.WriteBool or env.net.WriteString
        env.net.ReadBool = env.net.ReadBool or env.net.ReadString
        local owner, other = env.player(), env.player()
        local console = env.console(owner)
        local info = assert(env.configure(owner, console, folder or "data"))
        assert(env.slicerIntel, "Missing server intel API")
        return env, owner, other, console, info
    end
    local function edit(env, owner, console)
        owner.target = console
        local before = #env.messages
        equal(env.fire("PlayerSay", owner, "!editConsole"), "")
        equal(#env.messages, before + 1)
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerSetupEditOpen"); equal(packet.player, owner)
        equal(#packet.values, 4); equal(packet.values[1], console); equal(packet.values[2], owner)
        return packet.values[3], packet.values[4]
    end
    local function save(env, owner, console, token, body, omit)
        local fields = {name = " Updated Console ", delay = 3, fileName = " Mission Clue "}
        if not omit then fields.intelBody = body end
        local before = #env.messages
        env.receive("SlicerSetupEditSave", owner, console, token, fields)
        assert(#env.messages > before, "An edit must receive a fresh reply")
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerSetupEditReply"); equal(packet.player, owner)
        equal(packet.values[1], token); equal(#packet.values, 2)
        return packet.values[2]
    end
    local function noSecret(value, seen)
        if type(value) == "string" then
            assert(not value:find("INTEL_ONLY", 1, true), "Private body escaped its authorized channel")
        elseif type(value) == "table" then
            if value.GetCreationID then return end -- A WriteEntity reference does not serialize its Lua fields.
            seen = seen or {}
            if seen[value] then return end
            seen[value] = true
            for key, item in pairs(value) do noSecret(key, seen); noSecret(item, seen) end
        end
    end
    local function noEntityBody(entity)
        for key, value in pairs(entity) do
            noSecret(key)
            if type(value) ~= "function" then noSecret(value) end
        end
    end
    local function publicFields(info)
        local count, allowed = 0, {name = true, delay = true, fileType = true, fileName = true, inUse = true}
        for key in pairs(info) do assert(allowed[key], "Unexpected public field " .. tostring(key)); count = count + 1 end
        equal(count, 5)
    end

    test("intel normalizer preserves literal nonblank text and canonicalizes line endings", function()
        local env = fixture()
        equal(env.normalizeSlicerIntel(" Keep CASE\r\n\tNext\rLast  "), " Keep CASE\n\tNext\nLast  ")
        equal(env.normalizeSlicerIntel("<b>literal</b> https://example.invalid !quitConsole"),
            "<b>literal</b> https://example.invalid !quitConsole")
        equal(env.normalizeSlicerIntel(" \t\r\n\r "), "")
        equal(env.normalizeSlicerIntel(""), "")
        equal(env.normalizeSlicerIntel("\194\160"), "\194\160", "Non-ASCII whitespace remains nonblank text")
        equal(env.normalizeSlicerIntel("\195\169\226\130\172\240\159\154\128"), "\195\169\226\130\172\240\159\154\128")
    end)

    test("intel byte boundary is measured after newline normalization without truncation", function()
        local env = fixture()
        equal(env.normalizeSlicerIntel(string.rep("x", 4096)), string.rep("x", 4096))
        equal(env.normalizeSlicerIntel(string.rep("\195\169", 2048)), string.rep("\195\169", 2048))
        equal(env.normalizeSlicerIntel(string.rep("x\r\n", 2048)), string.rep("x\n", 2048))
        for _, value in ipairs({string.rep("x", 4097), string.rep("\195\169", 2048) .. "x"}) do
            local normalized, problem = env.normalizeSlicerIntel(value)
            equal(normalized, nil); assert(type(problem) == "string" and problem:find("4096", 1, true))
        end
    end)

    local invalidText = {
        {"number", 12}, {"boolean", false}, {"table", {}},
        {"NUL", "a\0b"}, {"C0 escape", "a\27b"}, {"C0 backspace", "a\8b"},
        {"DEL", "a\127b"}, {"C1 low", "a\194\128b"}, {"C1 high", "a\194\159b"},
        {"isolated continuation", "a\128b"}, {"missing continuation", "\226\130"},
        {"invalid continuation", "\226x\172"}, {"overlong ASCII", "\192\175"},
        {"overlong three-byte", "\224\128\175"}, {"surrogate", "\237\160\128"},
        {"out of Unicode range", "\244\144\128\128"}, {"five-byte prefix", "\248\128\128\128\128"},
    }
    for _, bad in ipairs(invalidText) do
        test("intel validator rejects " .. bad[1] .. " with a usable error", function()
            local env = fixture()
            local value, problem = env.normalizeSlicerIntel(bad[2])
            equal(value, nil); assert(type(problem) == "string" and #problem > 0)
        end)
    end

    test("intel award identity accepts only canonical bounded positive decimal strings", function()
        local env = fixture()
        for _, value in ipairs({"1", "42", "9007199254740991"}) do equal(env.validSlicerIntelAward(value), true) end
        for _, value in ipairs({"", "0", "01", "-1", "+1", "1.0", "1e2", " 1", "1 ",
            "9007199254740992", "10000000000000000", "1\0", 1, false, {}}) do
            assert(not env.validSlicerIntelAward(value), "Invalid award identity was accepted: " .. tostring(value))
        end
        assert(not env.validSlicerIntelAward(nil))
    end)

    for _, folder in ipairs({"data", "server"}) do
        test(folder .. " creator-only intel round trip preserves omitted fields and clears explicit blank", function()
            local env, owner, _, console = fixture(folder)
            owner.weapon = nil
            local token, payload = edit(env, owner, console)
            equal(payload.intelBody, "")
            equal(save(env, owner, console, token, (secret:gsub("\n", "\r\n"))).ok, true)
            equal(env.slicerIntel.GetBody(console), secret)
            publicFields(console.SlicerInformation)
            token, payload = edit(env, owner, console)
            equal(payload.intelBody, secret)
            payload.intelBody = "Locally changed prefill"
            equal(env.slicerIntel.GetBody(console), secret)
            equal(save(env, owner, console, token, nil, true).ok, true)
            equal(env.slicerIntel.GetBody(console), secret, "A legacy edit preserves intel")
            token = edit(env, owner, console)
            equal(save(env, owner, console, token, " \t\r\n ").ok, true)
            equal(env.slicerIntel.GetBody(console), "")
            token, payload = edit(env, owner, console)
            equal(payload.intelBody, "")
            equal(save(env, owner, console, token, secret).ok, true)
            equal(save(env, owner, console, edit(env, owner, console), "").ok, true)
            equal(env.slicerIntel.GetBody(console), "")
        end)
    end

    for _, bad in ipairs({{"oversize", string.rep("x", 4097)}, {"control", "bad\0body"},
        {"invalid UTF-8", "bad\128"}, {"nonstring", {}}, {"boolean", false}}) do
        test("invalid " .. bad[1] .. " intel cannot partially commit metadata or retire the valid ticket", function()
            local env, owner, _, console, info = fixture()
            env.slicerIntel.SetBody(console, secret)
            local token = edit(env, owner, console)
            local reply = save(env, owner, console, token, bad[2])
            equal(reply.ok, false); assert(type(reply.message) == "string" and #reply.message > 0)
            equal(console.SlicerInformation, info); equal(info.name, "terminal")
            equal(env.slicerIntel.GetBody(console), secret)
            equal(edit(env, owner, console), token)
            equal(save(env, owner, console, token, "Corrected body").ok, true)
            equal(console.SlicerInformation.name, "updated console")
            equal(env.slicerIntel.GetBody(console), "Corrected body")
        end)
    end

    test("invalid metadata cannot partially replace a valid intel body", function()
        local env, owner, _, console, info = fixture()
        env.slicerIntel.SetBody(console, secret)
        local token = edit(env, owner, console)
        env.receive("SlicerSetupEditSave", owner, console, token,
            {name = "", delay = 2, fileName = "new", intelBody = "Replacement"})
        equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, false)
        equal(console.SlicerInformation, info); equal(env.slicerIntel.GetBody(console), secret)
        equal(save(env, owner, console, token, "Replacement").ok, true)
    end)

    test("stranger cannot open, save or cancel a creator's intel ticket", function()
        local env, owner, stranger, console, info = fixture()
        env.slicerIntel.SetBody(console, secret)
        local token = edit(env, owner, console)
        local before = #env.messages
        stranger.target = console; env.fire("PlayerSay", stranger, "!editConsole")
        equal(#env.messages, before); noSecret(stranger.chats)
        equal(save(env, stranger, console, token, "Stolen").ok, false)
        noSecret(env.messages[#env.messages].values)
        env.receive("SlicerSetupEditCancel", stranger, console, token)
        equal(console.SlicerInformation, info); equal(env.slicerIntel.GetBody(console), secret)
        equal(edit(env, owner, console), token)
        equal(save(env, owner, console, token, "Owner update").ok, true)
    end)

    for _, reason in ipairs({"body", "metadata", "creator", "console generation", "console index", "player generation", "player index"}) do
        test("intel edit rejects stale " .. reason .. " and cannot revive after restoration", function()
            local env, owner, other, console, info = fixture()
            env.slicerIntel.SetBody(console, secret)
            local token = edit(env, owner, console)
            local restore, expected = nil, secret
            if reason == "body" then
                env.slicerIntel.SetBody(console, "Changed body"); expected = "Changed body"
                restore = function() env.slicerIntel.SetBody(console, secret) end
            elseif reason == "metadata" then info.name = "external"; restore = function() info.name = "terminal" end
            elseif reason == "creator" then console.SlicerCreator = other; restore = function() console.SlicerCreator = owner end
            else
                local target = reason:find("player", 1, true) and owner or console
                local key = reason:find("index", 1, true) and "EntIndex" or "GetCreationID"
                local original = target[key]
                target[key] = function(self) return original(self) + 1000 end
                restore = function() target[key] = original end
                if target == console then expected = "" end
            end
            local reply = save(env, owner, console, token, "Forged replacement")
            equal(reply.ok, false); assert(reply.message:find("!editConsole", 1, true))
            equal(console.SlicerInformation, info); equal(env.slicerIntel.GetBody(console), expected)
            restore()
            equal(save(env, owner, console, token, "Forged replacement").ok, false)
            equal(console.SlicerInformation, info)
        end)
    end

    for _, ending in ipairs({"quit", "death", "early completion", "accepted completion"}) do
        test("intel ticket retired by Use stays stale through " .. ending, function()
            local env, owner, hacker, console, info = fixture()
            env.slicerIntel.SetBody(console, secret)
            local token = edit(env, owner, console)
            env.open(hacker, console)
            if ending == "quit" then env.receive("playerQuitConsole", hacker)
            elseif ending == "death" then hacker.alive = false; env.fire("PlayerDeath", hacker)
            else
                env.now = ending == "accepted completion" and 4 or 0
                env.receive("destroyOnServer", hacker, console)
            end
            equal(save(env, owner, console, token, "Late clue").ok, false)
            equal(console.SlicerInformation, info)
            equal(env.slicerIntel.GetBody(console), ending == "accepted completion" and "" or secret)
            if ending == "accepted completion" then equal(env.lastMessage("SlicerIntel").values[5], secret) end
        end)
    end

    for _, interleave in ipairs({"body changes", "session opens", "ticket cancels"}) do
        test("final intel save check rejects when " .. interleave .. " during normalization", function()
            local env, owner, hacker, console, info = fixture()
            env.slicerIntel.SetBody(console, secret)
            local token = edit(env, owner, console)
            local normalize, fired = env.normalizeSlicerInformation, false
            -- Model synchronous third-party behavior at an existing public
            -- function boundary; no private map or production test hook.
            env.normalizeSlicerInformation = function(fields)
                local normalized = normalize(fields)
                if not fired and type(fields) == "table" and fields.name == " Updated Console " then
                    fired = true
                    if interleave == "body changes" then env.slicerIntel.SetBody(console, "Intervening body")
                    elseif interleave == "session opens" then env.open(hacker, console)
                    else env.receive("SlicerSetupEditCancel", owner, console, token) end
                end
                return normalized
            end
            equal(save(env, owner, console, token, "Replacement").ok, false)
            assert(fired, "The interleaving must reach actual submission validation")
            equal(console.SlicerInformation, info)
            equal(env.slicerIntel.GetBody(console), interleave == "body changes" and "Intervening body" or secret)
            if interleave == "session opens" then equal(info.inUse, true) end
        end)
    end

    test("reentrant replacement edit survives rejection of the older save and remains usable", function()
        local env, owner, _, console, info = fixture()
        env.slicerIntel.SetBody(console, secret)
        local original = edit(env, owner, console)
        local normalize, replacement, fired = env.normalizeSlicerInformation, nil, false
        env.normalizeSlicerInformation = function(fields)
            local normalized = normalize(fields)
            if not fired and type(fields) == "table" and fields.name == " Updated Console " then
                fired = true
                env.receive("SlicerSetupEditCancel", owner, console, original)
                replacement = edit(env, owner, console)
            end
            return normalized
        end
        equal(save(env, owner, console, original, "Old submitted body").ok, false)
        assert(fired and replacement and replacement ~= original)
        equal(console.SlicerInformation, info); equal(env.slicerIntel.GetBody(console), secret)
        equal(edit(env, owner, console), replacement, "Rejecting an old save must not retire the new ticket")
        equal(save(env, owner, console, replacement, "Current replacement body").ok, true)
        equal(console.SlicerInformation.name, "updated console")
        equal(env.slicerIntel.GetBody(console), "Current replacement body")
    end)

    test("tools editor has no intel payload and cannot be made intel-bearing by a forged field", function()
        local env, owner, _, console = fixture("tools")
        local token, payload = edit(env, owner, console)
        equal(payload.intelBody, nil)
        save(env, owner, console, token, secret)
        equal(env.slicerIntel.GetBody(console), "")
        publicFields(console.SlicerInformation)
    end)

    test("private body is absent from entities, registries, public Use, catalogue, inspection and help", function()
        local env, owner, hacker, console = fixture()
        env.slicerIntel.SetBody(console, secret)
        noEntityBody(console); noSecret(env.returnSpawnedEntities())
        publicFields(console.SlicerInformation)
        for _, command in ipairs({"!listConsoles", "!inspectConsole 1", "!findConsoles 1 terminal",
            "!findConsoleFiles 1 secret", "!slicerHelp", "!slicerHelp browse", "!slicerHelp setup", "!slicerHelp hacking"}) do
            env.fire("PlayerSay", owner, command)
        end
        noSecret(owner.chats); noSecret(hacker.chats)
        local before = #owner.chats
        env.fire("PlayerSay", owner, "!findConsoleFiles 1 INTEL_ONLY")
        assert(#owner.chats > before)
        for index = before + 1, #owner.chats do
            assert(not owner.chats[index]:find("1. ", 1, true), "Body text must not create a file-search match")
        end
        env.open(hacker, console)
        local packet = assert(env.lastMessage("ServerSendsEntityInformation"))
        equal(packet.player, hacker); publicFields(packet.values[3]); noSecret(packet.values)
        for _, message in ipairs(env.messages) do noSecret(message.values) end
    end)

    test("Use explicitly allowlists public settings even when foreign server code adds nested fields", function()
        local env, _, hacker, console, info = fixture()
        env.slicerIntel.SetBody(console, secret)
        info.unrelated = {intelBody = secret}
        env.open(hacker, console)
        local packet = assert(env.lastMessage("ServerSendsEntityInformation"))
        publicFields(packet.values[3]); noSecret(packet.values[3])
        equal(info.unrelated.intelBody, secret, "Serializing must not mutate unrelated source fields")
    end)

    test("author body survives creator disconnect and repeated includes, then clears on removal", function()
        local env, owner, _, console = fixture()
        env.slicerIntel.SetBody(console, secret)
        env.fire("PlayerDisconnected", owner)
        equal(env.slicerIntel.GetBody(console), secret)
        for _, path in ipairs({"autorun/server/sv_slicer_intel.lua", "autorun/server/sv_config.lua",
            "entities/consoleent/init.lua"}) do
            env.include(path); equal(env.slicerIntel.GetBody(console), secret)
        end
        console:Remove()
        equal(env.slicerIntel.GetBody(console), "")
        console.valid = true -- Reusing a wrapper cannot revive an entry removed by OnRemove.
        equal(env.slicerIntel.GetBody(console), "")
    end)

    test("fresh server environment starts without another map's authored body", function()
        local first, _, _, original = fixture()
        first.slicerIntel.SetBody(original, secret)
        local second, _, _, nextConsole = fixture()
        equal(nextConsole:GetCreationID(), original:GetCreationID())
        equal(nextConsole:EntIndex(), original:EntIndex())
        equal(second.slicerIntel.GetBody(nextConsole), "")
        equal(first.slicerIntel.GetBody(original), secret)
    end)
end

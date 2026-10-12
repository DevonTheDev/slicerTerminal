-- Exercise actual PlayerSay handlers; native chat visibility still needs GMod.
return function(gmod, test, equal)
    local topics = {
        {command = "!slicerHelp", fragments = {"!slicerHelp browse", "!slicerHelp setup", "!slicerHelp links", "!slicerHelp hacking"}},
        {command = "!slicerHelp browse", fragments = {"!listConsoles", "!findConsoles", "!nearConsoles", "!locateConsole", "60 seconds", "setup", "unconfirmed", "reserved"}},
        {command = "!slicerHelp setup", fragments = {"!setupConsole", "!editConsole", "creator", "Use"}},
        {command = "!slicerHelp links", fragments = {"!setEntity", "!cancelLink", "!inspectLink", "!resetLink", "!unlinkConsole", "creator", "func_door_rotating"}},
        {command = "!slicerHelp hacking", fragments = {"Hacking Tool", "Use", "/help", "!quitConsole", "living"}},
    }
    local function reply(env, player, command)
        local before, packets = #player.chats, #env.messages
        equal(env.fire("PlayerSay", player, command), "", "Help command must be consumed privately")
        equal(#env.messages, packets, "Help must not send network messages")
        local lines = {}
        for index = before + 1, #player.chats do
            local line = player.chats[index]
            assert(type(line) == "string" and #line > 0 and #line <= 240, "Help line exceeds the private chat budget")
            assert(not line:find("[%z\1-\31\127]"), "Help line contains controls")
            lines[#lines + 1] = line
        end
        assert(#lines > 0 and #lines <= 10, "Help needs a bounded nonempty reply")
        return table.concat(lines, "\n")
    end
    local function forbidden() error("Static help accessed game state or authority") end

    for _, topic in ipairs(topics) do
        test("private command directory serves " .. topic.command .. " without creator or admin access", function()
            local env, player, other = gmod.new()
            player, other = env.player(), env.player()
            local foreign = env.console(other); assert(env.configure(other, foreign, "tools"))
            foreign.SlicerInformation.name = "PRIVATE_OTHER_CONSOLE"
            player.weapon = nil
            player.IsAdmin, player.IsSuperAdmin, player.Alive = forbidden, forbidden, forbidden
            player.GetEyeTrace, player.GetActiveWeapon, player.WorldSpaceCenter = forbidden, forbidden, forbidden
            env.ents.FindByClass, env.returnSpawnedEntities, env.normalizeSlicerInformation = forbidden, forbidden, forbidden
            local others = #other.chats
            local text = reply(env, player, topic.command)
            for _, fragment in ipairs(topic.fragments) do
                assert(text:find(fragment, 1, true), "Missing command-directory guidance: " .. fragment)
            end
            assert(not text:find("PRIVATE_OTHER_CONSOLE", 1, true))
            equal(#other.chats, others, "Help must reply only to its requester")
        end)
    end

    test("dead players receive the same fixed help and nonplayers receive no reply", function()
        local env = gmod.new()
        local player = env.player()
        for _, topic in ipairs(topics) do
            player.alive = true; local living = reply(env, player, topic.command)
            player.alive = false; equal(reply(env, player, topic.command), living)
        end
        local invalid, nonplayer = env.player(), env.entity("prop_physics")
        invalid.valid = false; nonplayer.ChatPrint = forbidden
        for _, command in ipairs({"!slicerHelp", "!slicerHelp browse", "!slicerHelp unknown"}) do
            equal(env.fire("PlayerSay", nil, command), "")
            equal(env.fire("PlayerSay", invalid, command), "")
            equal(env.fire("PlayerSay", nonplayer, command), "")
        end
        equal(#invalid.chats, 0)
    end)

    test("recognized malformed help gets one fixed usage line without echoing input", function()
        local env = gmod.new()
        local player = env.player()
        local usage
        for _, command in ipairs({"!slicerHelp ", "!slicerHelp  browse", "!slicerHelp browse ",
            "!slicerHelp BROWSE", "!slicerHelp browse extra", "!slicerHelp unknown", "!slicerHelp\tbrowse",
            "!slicerHelp\nbrowse", "!slicerHelp\rbrowse", "!slicerHelp\vbrowse", "!slicerHelp\fbrowse",
            "!slicerHelp \0", "!slicerHelp \255", "!slicerHelp " .. string.rep("PRIVATE_INPUT", 10000)}) do
            local before = #player.chats
            local text = reply(env, player, command)
            equal(#player.chats, before + 1, "Malformed help has one fixed usage line")
            assert(text:find("Usage:", 1, true)); assert(not text:find("PRIVATE_INPUT", 1, true))
            usage = usage or text; equal(text, usage)
        end
    end)

    test("help near matches remain ordinary chat under forward and reverse hook order", function()
        local env = gmod.new()
        local player = env.player()
        local names = {}; for name in pairs(env.hooks.PlayerSay) do names[#names + 1] = name end
        table.sort(names)
        local function ordered(command, reverse)
            for step = 1, #names do
                local index = reverse and (#names - step + 1) or step
                local result = env.hooks.PlayerSay[names[index]](player, command)
                if result ~= nil then return result end
            end
        end
        for _, reverse in ipairs({false, true}) do
            for _, command in ipairs({"hello", "!consoleHelp", "!slicerhelp", "!SlicerHelp", "!slicerHelpMore",
                "!slicerHelpbrowse", " !slicerHelp", "!slicerHelp!", "!slicerHelp\0", "!slicerHelp\194\160browse"}) do
                local chats, packets = #player.chats, #env.messages
                equal(ordered(command, reverse), nil, "Near-match chat must not be consumed")
                equal(#player.chats, chats); equal(#env.messages, packets)
            end
            local before = #player.chats
            equal(ordered("!slicerHelp browse", reverse), "")
            assert(#player.chats > before, "Recognized help must work independently of existing hook order")
        end
    end)

    test("help neither replaces nor renews exact listed rows, even while the requester is dead", function()
        local env = gmod.new()
        local player = env.player()
        local first, second = env.console(player), env.console(player)
        equal(env.fire("PlayerSay", player, "!listConsoles"), "")
        equal(env.slicerListedConsole(player, 1), first); equal(env.slicerListedConsole(player, 2), second)
        env.now = 59
        for _, topic in ipairs(topics) do reply(env, player, topic.command) end
        reply(env, player, "!slicerHelp invalid")
        player.alive = false; reply(env, player, "!slicerHelp browse"); player.alive = true
        equal(env.slicerListedConsole(player, 1), first); equal(env.slicerListedConsole(player, 2), second)
        env.now = 60
        reply(env, player, "!slicerHelp browse")
        equal(env.slicerListedConsole(player, 1), nil, "The original row lease must expire at 60 seconds")
    end)

    test("existing recovery hook ignores non-string nonmatches without touching requester methods", function()
        local env = gmod.new()
        local hook = env.hooks.PlayerSay.slicerQuitConsole
        env.IsValid = forbidden
        local function unchanged(value)
            local ok, result = pcall(hook, nil, value)
            equal(ok, true, "A non-string nonmatch must not throw")
            equal(result, nil, "The existing recovery hook must leave nonmatches unclaimed")
        end
        unchanged(nil)
        for _, value in ipairs({false, true, 0, 42, {}, function() end}) do unchanged(value) end
    end)

    local function failureFixture()
        local env = gmod.new()
        local owner, other = env.player(), env.player()
        local selected, active = env.console(owner), env.console(other)
        local information = assert(env.configure(owner, selected, "tools", 2))
        assert(env.configure(other, active, "data", 2))
        owner.target = selected; equal(env.fire("PlayerSay", owner, "!editConsole"), "")
        local edit = env.lastMessage("SlicerSetupEditOpen")
        env.now = 10; env.open(owner, active)
        equal(env.fire("PlayerSay", owner, "!listConsoles"), "")
        local packets, serial = #env.messages, env.slicerSetupEditSerial
        env.now = 11
        local function preserved()
            equal(#env.messages, packets); equal(env.slicerSetupEditSerial, serial)
            equal(selected.SlicerInformation, information); equal(information.inUse, false)
            equal(owner.SlicerPendingConsole, selected); equal(active.SlicerInformation.inUse, true)
            equal(env.slicerListedConsole(owner, 1), selected)
            env.receive("SlicerSetupEditSave", owner, selected, edit.values[3], {name = "After help", delay = 2, fileName = "secret"})
            equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true, "Help failure must preserve existing edit authority")
            env.now = 14; env.receive("destroyOnServer", owner, active)
            equal(active.removed, true, "Help failure must preserve the original hacking deadline")
            env.now = 70; equal(env.slicerListedConsole(owner, 1), nil, "Help failure must not renew the original row lease")
        end
        return env, owner, preserved
    end

    test("recognized help consumes admission exceptions without replying or changing authority", function()
        for _, method in ipairs({"IsValid", "IsPlayer"}) do
            local env, owner, preserved = failureFixture()
            local original = method == "IsValid" and env.IsValid or owner.IsPlayer
            local replies = #owner.chats
            if method == "IsValid" then env.IsValid = forbidden else owner.IsPlayer = forbidden end
            local ok, result = pcall(env.fire, "PlayerSay", owner, "!slicerHelp browse")
            if method == "IsValid" then env.IsValid = original else owner.IsPlayer = original end
            equal(ok, true, "Recognized help must contain admission exceptions")
            equal(result, "", "A recognized help failure must still be consumed privately")
            equal(#owner.chats, replies); preserved()
        end
    end)

    test("recognized help consumes reply exceptions and stops later lines without changing authority", function()
        for _, failAt in ipairs({1, 2}) do
            local env, owner, preserved = failureFixture()
            local original, calls, before = owner.ChatPrint, 0, #owner.chats
            function owner:ChatPrint(message)
                calls = calls + 1
                if calls == failAt then error("Reply unavailable") end
                original(self, message)
            end
            local ok, result = pcall(env.fire, "PlayerSay", owner, "!slicerHelp browse")
            owner.ChatPrint = original
            equal(ok, true, "Recognized help must contain reply exceptions")
            equal(result, "", "A failed private reply must never publish the recognized command")
            equal(calls, failAt, "No further lines may be attempted after a failed reply")
            equal(#owner.chats, before + failAt - 1); preserved()
        end
    end)
end

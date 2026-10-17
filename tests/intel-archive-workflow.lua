-- Six modeled private server/client flows. The closed legacy cyber
-- Start/Cancel-to-new-Use route is intentionally absent from these fixtures.
return function(gmod, test, equal)
    local H = dofile("tests/intel-archive-support.lua")(gmod, equal)
    local unpackValues = table.unpack or unpack
    local function authored(env, owner, folder, body)
        local console = H.add(env, owner, nil, folder)
        owner.target = console; env.fire("PlayerSay", owner, "!editConsole")
        local ticket = assert(env.lastMessage("SlicerSetupEditOpen")).values[3]
        env.receive("SlicerSetupEditSave", owner, console, ticket,
            {name = "terminal", delay = 2, fileName = "secret", intelBody = body})
        equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true)
        return console
    end
    local function currentLatest(client)
        return H.savedButton(client).parent
    end
    local function latestBody(client)
        for _, panel in ipairs(currentLatest(client).children) do
            if panel.class == "DTextEntry" then return panel.text end
        end
        error("Missing latest body")
    end
    local function tools(env, owner, player)
        local console, door = H.add(env, owner, nil, "tools"), env.entity("func_door")
        owner.target = console; env.fire("PlayerSay", owner, "!setEntity")
        owner.target = door; env.fire("PlayerSay", owner, "!setEntity")
        equal(H.finish(env, player, console, "PlayerActivatedDoor"), nil)
        equal(console.removed, true); equal(door.inputs[#door.inputs], "Unlock")
    end

    test("W1 two authored data/server completions retain older intel while bare readIntel reads latest", function()
        local env, owner, player = H.fixture(); local client = H.client()
        local first, second = authored(env, owner, "data", "First authored clue"), authored(env, owner, "server", "Second authored clue")
        local older = assert(H.finish(env, player, first)); H.deliver(client, older)
        local newer = assert(H.finish(env, player, second)); H.deliver(client, newer)
        equal(first.removed, true); equal(second.removed, true); equal(latestBody(client), "Second authored clue")
        env.fire("PlayerSay", player, "!readIntel")
        local recovered = env.lastMessage("SlicerIntel")
        equal(recovered.values[1], newer.values[1]); equal(recovered.values[6], true)
        local view, request = H.open(client); local list = H.roundtrip(env, player, client, request)
        equal(list.count, 2); equal(view.selector:GetOptionData(2), older.values[1])
        view.selector:ChooseOptionID(2); H.roundtrip(env, player, client, H.lastRequest(client))
        equal(view.body.text, "First authored clue"); equal(latestBody(client), "Second authored clue")
        equal(#H.packets(env, "SlicerCompleted"), 2)
    end)

    test("W2 a dropped first delivery is recoverable privately after a newer completion", function()
        local env, owner, player, stranger = H.fixture(); local client, otherClient = H.client(), H.client()
        local first = H.award(env, owner, player, "Dropped first clue") -- Intentionally not delivered.
        local second = H.award(env, owner, player, "Newer clue"); H.deliver(client, second)
        local view, request = H.open(client); H.roundtrip(env, player, client, request)
        equal(view.selector:GetOptionData(2), first.values[1])
        view.selector:ChooseOptionID(2); H.roundtrip(env, player, client, H.lastRequest(client))
        equal(view.body.text, "Dropped first clue")
        local list = H.ask(env, stranger, 1); equal(list.count, 0)
        local read, packet = H.ask(env, stranger, 2, first.values[1]); equal(read.status, 1); equal(read.record, nil)
        assert(not packet.bytes:find("Dropped first clue", 1, true))
        equal(#otherClient.panels, 0); equal(#otherClient.chatMessages, 0)
        for _, sent in ipairs(H.packets(env, H.replyName)) do
            if sent.player == stranger then
                local decoded = H.decode(sent.bytes)
                assert(not decoded.record and (not decoded.entries or #decoded.entries == 0))
            end
        end
    end)

    test("W3 an evicted snapshot ID is unavailable without substitution and Refresh returns newest ten", function()
        local env, owner, player = H.fixture(); local client = H.client(); local awards = {}
        for i = 1, 10 do awards[i] = H.award(env, owner, player, "Clue " .. i) end
        H.deliver(client, awards[10]); local view, request = H.open(client)
        H.roundtrip(env, player, client, request); equal(view.selector:GetOptionData(10), awards[1].values[1])
        local blank = H.add(env, owner); equal(H.finish(env, player, blank), nil); tools(env, owner, player)
        local unchanged = H.ask(env, player, 1); equal(unchanged.count, 10)
        equal(unchanged.entries[10].award, awards[1].values[1])
        awards[11] = H.award(env, owner, player, "Clue 11")
        equal(view.selector:GetOptionData(1), awards[10].values[1], "Arrival alone does not auto-refresh")
        local count = #client.messages
        view.selector:ChooseOptionID(10); local result = H.roundtrip(env, player, client, H.lastRequest(client))
        equal(result.status, 1); equal(view.body.text, "")
        equal(view.status.text, "That clue is no longer saved. Refresh the list.")
        equal(#client.messages, count + 1)
        view.refresh:DoClick(); local list = H.roundtrip(env, player, client, H.lastRequest(client))
        equal(list.count, 10)
        for i = 1, 10 do equal(view.selector:GetOptionData(i), awards[12 - i].values[1]) end
        assert(view.footer.text:find("Saved 10/10", 1, true)); assert(view.footer.text:find("newest 10", 1, true))
    end)

    test("W4 archive activity preserves a live ordinary terminal draft caret recall timer tool and session", function()
        for _, folder in ipairs({"data", "server"}) do
            local env, owner, player = H.fixture(); local client = H.client()
            H.deliver(client, H.award(env, owner, player, "Already awarded"))
            local console = H.add(env, owner, nil, folder)
            env.open(player, console); H.deliver(client, env.lastMessage("ServerSendsEntityInformation"))
            client.command("/a[terminal]")
            local input
            for _, panel in ipairs(client.panels) do
                if panel.class == "DTextEntry" and panel.IsCurrentTerminalPage and panel:IsCurrentTerminalPage() then input = panel end
            end
            assert(input, "No ordinary live login entry")
            input:SetText("unfinished " .. folder .. " draft"); input:SetCaretPos(7)
            local text, caret, history, identity = input.text, input.caret, input.History, input.IsCurrentTerminalPage
            local historyValues = {}; for i, item in ipairs(history) do historyValues[i] = item end
            local access = assert(client.timers.AccessDelay)
            local delay, clock, weapon = access.delay, env.now, player.weapon
            local view, request = H.open(client)
            H.roundtrip(env, player, client, request, false)
            view.selector:ChooseOptionID(1); H.roundtrip(env, player, client, H.lastRequest(client), false)
            view.refresh:DoClick(); H.roundtrip(env, player, client, H.lastRequest(client), false)
            view.frame:Close()
            equal(input.text, text); equal(input.caret, caret); equal(input.History, history)
            equal(#history, #historyValues); for i, item in ipairs(historyValues) do equal(history[i], item) end
            equal(input.IsCurrentTerminalPage, identity); equal(input:IsCurrentTerminalPage(), true)
            equal(client.timers.AccessDelay, access); equal(access.delay, delay)
            equal(env.now, clock); equal(player.weapon, weapon); equal(console.SlicerInformation.inUse, true)
            equal(#H.packets(client, "playerQuitConsole"), 0); equal(#H.packets(client, "destroyOnServer"), 0)
            equal(#H.packets(client, "PlayerActivatedDoor"), 0)
            -- The original server deadline remains sufficient after archive activity.
            env.now = clock + 4; env.receive("destroyOnServer", player, console)
            equal(console.removed, true)
        end
    end)

    test("W5 death respawn tool loss and source removal retain lookup while connection/map resets reject it", function()
        local env, owner, player = H.fixture(); local client = H.client()
        local award, source = H.award(env, owner, player, "Surviving clue"); H.deliver(client, award)
        equal(source.removed, true)
        local view, request = H.open(client); H.roundtrip(env, player, client, request)
        player.alive, player.weapon = false, nil; env.fire("PlayerDeath", player); client.receive("PlayerDied")
        equal(H.archive(client).frame, view.frame)
        view.selector:ChooseOptionID(1); H.roundtrip(env, player, client, H.lastRequest(client))
        equal(view.body.text, "Surviving clue")
        player.alive = true; env.fire("PlayerSpawn", player)
        equal(H.ask(env, player, 2, award.values[1]).record.body, "Surviving clue")
        view.refresh:DoClick(); local pending = H.lastRequest(client)
        env.now = env.now + 1; env.receiveBytes(H.requestName, player, pending.packet.bytes)
        local delayed = env.lastMessage(H.replyName); view.frame:Close()
        env.fire("PlayerDisconnected", player); env.fire("PlayerInitialSpawn", player)
        H.deliver(client, delayed); equal(#H.frames(client, "Saved mission intel"), 0)
        equal(H.ask(env, player, 2, award.values[1]).status, 1)
        player.weapon = env.entity("weapon_hacking")
        local nextAward = H.award(env, owner, player, "New connection").values[1]
        local original = player.GetCreationID; player.GetCreationID = function(self) return original(self) + 1000 end
        equal(H.ask(env, player, 2, nextAward).status, 1)
        local fresh, _, freshPlayer = H.fixture()
        equal(H.ask(fresh, freshPlayer, 2, award.values[1]).status, 1); equal(H.ask(fresh, freshPlayer, 1).count, 0)
    end)

    test("W6 duplicate completion and latest/archive delivery keep one award reader and archive with consistent notices", function()
        local env, owner, player = H.fixture(); local client = H.client()
        local console = authored(env, owner, "data", "Once only")
        local award = assert(H.finish(env, player, console))
        for i = 1, 3 do env.receive("destroyOnServer", player, console) end
        equal(#H.packets(env, "SlicerCompleted"), 1); equal(#H.packets(env, "SlicerIntel"), 1)
        for i = 1, 3 do H.deliver(client, award) end
        local latest = currentLatest(client); equal(latest.popupCalls, 1)
        local view, request = H.open(client); local _, reply = H.roundtrip(env, player, client, request)
        H.deliver(client, reply); H.deliver(client, reply)
        equal(#view.selector.choices, 1); equal(H.ask(env, player, 1).count, 1)
        view.selector:ChooseOptionID(1); local _, body = H.roundtrip(env, player, client, H.lastRequest(client))
        H.deliver(client, body); H.deliver(client, body)
        equal(view.body.text, "Once only"); equal(view.frame.popupCalls, 1)
        equal(#H.frames(client, latest.title), 1); equal(#H.frames(client, "Saved mission intel"), 1)
        assert(view.footer.text:find("newest 10 clues", 1, true)); assert(view.footer.text:find("Disconnect/map change", 1, true))
        local notice
        for _, panel in ipairs(latest.children) do if panel.class == "DLabel" and panel.text:find("Saved intel", 1, true) then notice = panel.text end end
        assert(notice and notice:find("newest 10 clues", 1, true) and notice:find("Disconnect/map change", 1, true))
    end)
end

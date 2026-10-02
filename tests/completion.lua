return function(gmod, test, equal)
    local kinds = {
        {folder="data", extension="data", timer="DownloadDataFile", message="destroyOnServer"},
        {folder="server", extension="sys", timer="DownloadServerFile", message="destroyOnServer"},
        {folder="tools", extension="exe", message="PlayerActivatedDoor"},
    }
    local unpackValues = table.unpack or unpack
    local function open(kind)
        local server, client = gmod.new(), gmod.client()
        local owner, hacker = server.player(), server.player()
        hacker.name = "Synthetic Hacker"
        local console = server.console(owner)
        local info = server.configure(owner, console, kind.folder, 2)
        if kind.folder == "tools" then
            owner.target = server.entity("func_door")
            server.fire("PlayerSay", owner, "!setEntity")
        end
        server.open(hacker, console)
        local opening = assert(server.lastMessage("ServerSendsEntityInformation"))
        client.receive(opening.name, nil, unpackValues(opening.values))
        client.command("/a[terminal]")
        client.fireTimer("AccessDelay")
        client.command("/a[terminal]/{_" .. kind.folder .. "}")
        local function request()
            client.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension)
            if kind.timer then client.fireTimer(kind.timer) end
            client.assertClosed()
            return assert(client.lastMessage(kind.message))
        end
        return server, client, owner, hacker, console, info, request
    end

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " completion is announced only after server acceptance and never replayed", function()
            local server, client, _, hacker, console, info, request = open(kind)
            server.now = 4
            local message = request()
            equal(#client.chatMessages, 0, "Request alone must not claim success")
            server.receive(message.name, hacker, unpackValues(message.values))
            equal(console.removed, true); equal(info.inUse, false)
            local accepted = assert(server.lastMessage("SlicerCompleted"), "Missing acceptance notice")
            equal(accepted.player, hacker)
            local count = #server.messages
            server.receive(message.name, hacker, unpackValues(message.values))
            equal(#server.messages, count, "Replayed request must not announce another completion")
            client.receive(accepted.name, nil, unpackValues(accepted.values))
            equal(#client.chatMessages, 1)
            equal(client.chatMessages[1][2], "[TERMINAL]: ")
            equal(client.chatMessages[1][4], "Synthetic Hacker has " .. (kind.timer and "downloaded" or "executed") .. " 'secret." .. kind.extension .. "'")
            if kind.folder == "tools" then equal(console.SlicerDoor.inputs[#console.SlicerDoor.inputs], "Unlock") end
        end)

        for _, reason in ipairs({"lost tool", "too early"}) do
            test(kind.folder .. " rejected completion releases its own reservation after " .. reason, function()
                local server, client, _, hacker, console, info, request = open(kind)
                server.now = reason == "too early" and 0 or 4
                if reason == "lost tool" then hacker.weapon = nil end
                local message = request()
                server.receive(message.name, hacker, unpackValues(message.values))
                equal(info.inUse, false, "Rejected completion must not strand the closed UI's reservation")
                equal(console.removed, nil)
                equal(server.lastMessage("SlicerCompleted"), nil)
                equal(#client.chatMessages, 0, "Rejected request must not print success")
                assert(hacker.chats[#hacker.chats]:find("not completed", 1, true), "Missing failure feedback")
                local closed = assert(server.lastMessage("PlayerDied"))
                client.receive(closed.name, nil); client.assertClosed()
                local nextHacker = server.player()
                server.open(nextHacker, console)
                equal(server.lastMessage("ServerSendsEntityInformation").player, nextHacker)
                equal(info.inUse, true)
                if kind.folder == "tools" then equal(console.SlicerDoor.inputs[#console.SlicerDoor.inputs], "Lock") end
            end)
        end
    end

    test("a request for another console cannot release or complete the sender's current session", function()
        local server, _, owner, hacker, console, info = open(kinds[1])
        local unrelated = server.console(owner); server.configure(owner, unrelated)
        server.now = 4
        local count = #server.messages
        server.receive("destroyOnServer", hacker, unrelated)
        equal(info.inUse, true); equal(console.removed, nil); equal(unrelated.removed, nil)
        equal(#server.messages, count)
    end)

    test("late accepted feedback cannot close a subsequently opened console", function()
        local server, client, owner, hacker, _, _, request = open(kinds[1])
        server.now = 4
        local message = request(); server.receive(message.name, hacker, unpackValues(message.values))
        local accepted = assert(server.lastMessage("SlicerCompleted"), "Missing acceptance notice")
        local nextConsole = server.console(owner); server.configure(owner, nextConsole)
        server.open(hacker, nextConsole)
        local opening = server.lastMessage("ServerSendsEntityInformation")
        client.receive(opening.name, nil, unpackValues(opening.values))
        local frame = client.firstPage
        equal(frame.valid, true)
        client.receive(accepted.name, nil, unpackValues(accepted.values))
        equal(frame.valid, true); equal(client.firstPage, frame)
        equal(#client.chatMessages, 1)
        client.receive("PlayerDied", nil); client.assertClosed()
    end)
end

-- Actual chat/page/row handlers; this never consults disk files.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function contains(text, part) assert(text:find(part, 1, true), "Missing '" .. part .. "' in " .. text) end
    local function console(env, owner, file, folder)
        local ent = env.console(owner)
        local info = assert(env.configure(owner, ent, folder or "data"))
        info.name, info.fileName = "same name", file or "secret"
        return ent
    end
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function reply(env, owner, text)
        local chats, packets, outgoing, observers = #owner.chats, #env.messages, env.outgoing, {}
        for _, ent in ipairs(env.entities) do
            if ent:IsPlayer() and ent ~= owner then observers[ent] = #ent.chats end
        end
        equal(say(env, owner, text), "", "File search must be private")
        equal(#env.messages, packets); equal(env.outgoing, outgoing)
        for ent, count in pairs(observers) do equal(#ent.chats, count) end
        local rows, lines = {}, {}
        for index = chats + 1, #owner.chats do
            local line = owner.chats[index]
            assert(#line <= 255 and not line:find("[%z\1-\31\127]"), "Unbounded or unsafe line")
            lines[#lines + 1] = line
            if line:match("^[1-5]%. Console") then rows[#rows + 1] = line end
        end
        assert(#lines >= 1 and #lines <= 7, "Expected bounded page")
        return rows, lines
    end
    local function find(env, owner, text, page)
        return reply(env, owner, "!findConsoleFiles " .. (page or 1) .. " " .. text)
    end
    local function locate(env, owner, target, row)
        local packets = #env.messages
        equal(say(env, owner, "!locateConsole " .. (row or 1)), "")
        if not target then equal(#env.messages, packets); return end
        equal(#env.messages, packets + 1)
        local packet = env.lastMessage("SlicerConsoleLocation")
        equal(packet.player, owner); equal(packet.values[3].x, target.position.x)
    end

    test("file search matches raw literal filename or folder with ASCII-only folding", function()
        local env = support.server(); local owner = env.player()
        local raw = "  REACTOR  west [a].% ../x \\path É é é Straße  "
        local ent = console(env, owner, raw, "server")
        for _, query in ipairs({"reactor", "REACTOR  WEST", "[a].%", "../", "\\path", "É", "é", "é", "Straße", "SERVER", "erv"}) do
            local rows, lines = find(env, owner, query); equal(#rows, 1); locate(env, owner, ent)
            contains(lines[1], "filename/folder"); contains(lines[1], "valid"); contains(lines[1], "!inspectConsole <row>")
        end
        for _, query in ipairs({"reactor west", ".*", "STRASSE", "same name", "configured", ent:GetName(), ".server"}) do
            local rows, lines = find(env, owner, query); equal(#rows, 0); equal(#lines, 1)
            contains(lines[1], "valid"); contains(lines[1], "!listConsoles"); locate(env, owner)
        end
        equal(ent.SlicerInformation.fileName, raw)
        equal(#reply(env, owner, "!findConsoles 1 REACTOR"), 0)
        equal(#reply(env, owner, "!findConsoles 1 server"), 0)
        equal(#reply(env, owner, "!findConsoles 1 same name"), 1)
        equal(#reply(env, owner, "!listConsoles 1 reserved secret"), 0)
        for _, folder in ipairs({"data", "server", "tools"}) do
            ent.SlicerInformation.fileType = folder
            equal(#find(env, owner, folder:upper()), 1); locate(env, owner, ent)
        end
    end)

    test("file search keeps display cleanup and Unicode normalization out of matching", function()
        local env = support.server(); local owner = env.player()
        local a = console(env, owner, "a\tb É é")
        local b = console(env, owner, "a b é é")
        equal(#find(env, owner, "a b"), 1); locate(env, owner, b)
        equal(#find(env, owner, "É"), 1); locate(env, owner, a)
        equal(#find(env, owner, "é"), 1); locate(env, owner, a)
        equal(#find(env, owner, "é"), 1); locate(env, owner, b)
        equal(a.SlicerInformation.fileName, "a\tb É é")
    end)

    test("file search excludes every invalid configuration without mutating saved data", function()
        local env = support.server(); local owner = env.player()
        local good = console(env, owner, "needle"); local saved = good.SlicerInformation
        local bad = {
            {name = false}, {name = " "}, {name = string.rep("n", 129)}, {fileName = false},
            {fileName = " "}, {fileName = string.rep("n", 129)}, {fileType = "DATA"}, {fileType = "bogus"},
            {delay = 0}, {delay = -1}, {delay = math.huge}, {delay = -math.huge}, {delay = 0/0}, {delay = "2"},
        }
        local records = {}
        for _, changes in ipairs(bad) do
            local ent = console(env, owner, "needle")
            for key, value in pairs(changes) do ent.SlicerInformation[key] = value end
            local fields = {}
            for key, value in pairs(ent.SlicerInformation) do fields[key] = value end
            records[#records + 1] = {ent, ent.SlicerInformation, fields}
        end
        env.console(owner); local malformed = env.console(owner); malformed.SlicerInformation = "needle"
        equal(#find(env, owner, "needle"), 1); locate(env, owner, good)
        equal(good.SlicerInformation, saved)
        for _, record in ipairs(records) do
            equal(record[1].SlicerInformation, record[2])
            for key, value in pairs(record[3]) do
                local actual = record[2][key]
                assert(actual == value or (actual ~= actual and value ~= value), "Search changed invalid saved data")
            end
            for key in pairs(record[2]) do assert(record[3][key] ~= nil, "Search added a saved field") end
        end
        equal(malformed.SlicerInformation, "needle")
    end)

    test("file search rejects malformed grammar before enumeration or number conversion", function()
        local env = support.server(); local owner = env.player(); console(env, owner)
        say(env, owner, "!listConsoles")
        env.ents.FindByClass = function() error("Malformed request enumerated") end
        env.tonumber = function() error("Malformed request converted") end
        local suffixes = {"", " ", " x", " 1", " 1 ", " 0 x", " 01 x", " -1 x", " +1 x", " 1.0 x", " 1e1 x",
            " ١ x", "  1 x", " 1  x", " 1 x ", "\t1 x", "\n1 x", "\r1 x", "\v1 x", "\f1 x", " 1\tx",
            " 10000000 x", " 1 " .. string.rep("x", 129), " " .. string.rep("9", 200000) .. " x"}
        for byte = 0, 31 do suffixes[#suffixes + 1] = " 1 a" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 a\127b"
        for byte = 128, 159 do suffixes[#suffixes + 1] = " 1 a\194" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 a\226\128\168b"; suffixes[#suffixes + 1] = " 1 a\226\128\169b"
        for _, suffix in ipairs(suffixes) do
            local rows, lines = reply(env, owner, "!findConsoleFiles" .. suffix)
            equal(#rows, 0); equal(#lines, 1); contains(lines[1], "Usage:")
        end
        env.tonumber = tonumber; locate(env, owner)
    end)

    test("file search near matches retain ordinary chat and the original rows", function()
        local env = support.server(); local owner = env.player(); local ent = console(env, owner)
        find(env, owner, "secret"); local chats = #owner.chats
        for _, text in ipairs({"!findConsoleFilesNow", "!findConsoleFiles1", "!findConsoleFiles/2", "!findconsolefiles 1 x",
            "!FINDCONSOLEFILES 1 x", " !findConsoleFiles 1 x", "!findConsoleFiles\0", "ordinary chat"}) do
            equal(say(env, owner, text), nil); equal(#owner.chats, chats)
        end
        locate(env, owner, ent)
    end)

    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("file search consumes " .. kind .. " requesters without private data reads", function()
            local env = support.server(); local owner = env.player(); console(env, owner)
            find(env, owner, "secret")
            local actor = owner
            if kind == "missing" then actor = nil elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics" else owner.alive = false end
            local feedback = owner.ChatPrint
            owner.ChatPrint = function() error("Invalid requester reply") end
            env.ents.FindByClass = function() error("Invalid requester enumerated") end
            for _, text in ipairs({"!findConsoleFiles", "!findConsoleFiles 1 secret", "!findConsoleFiles 01 x"}) do
                equal(say(env, actor, text), "")
            end
            owner.ChatPrint, owner.valid, owner.class, owner.alive = feedback, true, "player", true
            if actor then locate(env, owner) end
        end)
    end

    for _, count in ipairs({0, 1, 5, 6, 12}) do
        test("file search pages " .. count .. " owned matches with exact bounded hints", function()
            local env = support.server(); local owner, other = env.player(), env.player()
            local query, targets = 'file  "2".%\\', {}
            for index = 1, count do targets[index] = console(env, owner, query .. index) end
            console(env, owner, "unrelated"); console(env, other, query)
            local pages = math.ceil(count / 5)
            for page = 1, math.max(1, pages) do
                local rows, lines = find(env, owner, query, page)
                equal(#rows, math.min(5, count - (page - 1) * 5))
                if count == 0 then contains(lines[1], "!listConsoles") else
                    contains(lines[1], "page " .. page .. " of " .. pages); contains(lines[1], "(" .. count .. " matches)")
                    for row = 1, #rows do locate(env, owner, targets[(page - 1) * 5 + row], row) end
                    if page < pages then equal(lines[#lines], "Next page: !findConsoleFiles " .. (page + 1) .. " " .. query)
                    elseif page > 1 then equal(lines[#lines], "First page: !findConsoleFiles 1 " .. query) end
                end
            end
            local rows, lines = find(env, owner, query, 9999999); equal(#rows, 0)
            contains(lines[1], count == 0 and "!listConsoles" or "between 1 and " .. pages); locate(env, owner)
        end)
    end

    test("file search admits 128-byte queries and the exact 154-byte command boundary", function()
        local env = support.server(); local owner = env.player()
        for _, query in ipairs({string.rep("a", 128), string.rep("é", 64)}) do
            local first = console(env, owner, query)
            first.SlicerInformation.name = string.rep("é", 64)
            for _ = 1, 5 do console(env, owner, query) end
            local rows, lines = find(env, owner, query); equal(#rows, 5)
            equal(lines[#lines], "Next page: !findConsoleFiles 2 " .. query); locate(env, owner, first)
            equal(#("!findConsoleFiles 9999999 " .. query), 154)
            rows, lines = find(env, owner, query, 9999999); equal(#rows, 0); contains(lines[1], "between 1 and 2")
        end
    end)

    test("file search excludes foreign metadata and orders duplicate names and IDs by entity index", function()
        local env = support.server(); local owner, other = env.player(), env.player()
        local a, b, c = console(env, owner), console(env, owner), console(env, owner)
        a.id, b.id, c.id = 10, 0, 0
        local foreign, ownerless = env.console(other), env.console(owner); ownerless.SlicerCreator = nil
        for _, ent in ipairs({foreign, ownerless}) do
            setmetatable(ent, {__index = function(_, key) if key == "SlicerInformation" then error("Foreign metadata read") end end})
        end
        local removed, wrong = console(env, owner), console(env, owner); removed:Remove(); wrong.class = "prop_physics"
        local all = {a, foreign, c, removed, ownerless, wrong, b}
        env.ents.FindByClass = function() return all end
        equal(#find(env, owner, "secret"), 3)
        locate(env, owner, b, 1); locate(env, owner, c, 2); locate(env, owner, a, 3)
        equal(all[1], a); equal(all[3], c); equal(all[7], b)
    end)

    test("file search rows survive metadata edits without remapping or renewing their lease", function()
        local env = support.server(); local owner = env.player()
        local first, second = console(env, owner, "needle"), console(env, owner, "other")
        env.now = 10; find(env, owner, "needle")
        first.SlicerInformation.fileName, second.SlicerInformation.fileName = "changed", "needle"
        env.now = 69.99; locate(env, owner, first)
        local chats = #owner.chats; equal(say(env, owner, "!inspectConsole 1"), "")
        contains(table.concat(owner.chats, "\n", chats + 1), "'changed'")
        env.now = 70; locate(env, owner)
        find(env, owner, "needle"); locate(env, owner, second)
        second:Remove(); local replacement = console(env, owner, "needle"); replacement.id = second.id
        locate(env, owner)
        find(env, owner, "needle"); replacement.SlicerCreator = env.player(); locate(env, owner)
    end)

    test("file search shares lease replacement and clearing with every catalogue family", function()
        local env = support.server(); local owner = env.player()
        local first, second = console(env, owner, "first"), console(env, owner, "second")
        function owner:GetPos() return support.vector(0, 0, 0) end
        for _, ent in ipairs({first, second}) do function ent:GetPos() return self.position end end
        second.SlicerInformation.name = "unique"
        for _, request in ipairs({"!findConsoles 1 unique", "!listConsoles 1", "!nearConsoles 1"}) do
            find(env, owner, "second"); say(env, owner, request)
            locate(env, owner, request:find("findConsoles", 1, true) and second or first)
            find(env, owner, "second"); locate(env, owner, second)
        end
        for _, request in ipairs({"!findConsoleFiles 1 absent", "!findConsoleFiles 2 first", "!findConsoleFiles 01 first"}) do
            say(env, owner, "!listConsoles"); reply(env, owner, request); locate(env, owner)
        end
        for _, event in ipairs({"PlayerDeath", "PlayerDisconnected"}) do
            find(env, owner, "first"); env.fire(event, owner); locate(env, owner)
        end
    end)

    for _, stage in ipairs({"metadata", "sort", "feedback"}) do
        test("file search suppresses obsolete " .. stage .. " replies after a newer page", function()
            local env = support.server(); local owner = env.player()
            local outer, inner = console(env, owner, "outer"), console(env, owner, "inner")
            local fired = false
            local function replace()
                if fired then return end; fired = true; find(env, owner, "inner")
            end
            if stage == "metadata" then
                local info = outer.SlicerInformation; outer.SlicerInformation = nil
                local old = getmetatable(outer).__index
                setmetatable(outer, {__index = function(self, key)
                    if key == "SlicerInformation" then replace(); return info end
                    return old[key]
                end})
            elseif stage == "sort" then
                console(env, owner, "outer")
                local accessor = outer.GetCreationID
                outer.GetCreationID = function(self) replace(); return accessor(self) end
            else
                local feedback = owner.ChatPrint
                owner.ChatPrint = function(self, message) feedback(self, message); replace() end
            end
            equal(say(env, owner, "!findConsoleFiles 1 outer"), "")
            assert(fired); locate(env, owner, inner)
            for _, line in ipairs(owner.chats) do assert(not line:find("1. Console 'same name' (current ID #" .. outer.id .. ")", 1, true)) end
        end)
    end

    for _, change in ipairs({"remove", "reown", "death"}) do
        test("file search retires unseen rows after header feedback " .. change, function()
            local env = support.server(); local owner, other = env.player(), env.player()
            local first, second = console(env, owner), console(env, owner)
            local feedback, chats, fired = owner.ChatPrint, #owner.chats, false
            owner.ChatPrint = function(self, message)
                feedback(self, message)
                if fired then return end
                fired = true
                if change == "remove" then first:Remove()
                elseif change == "reown" then first.SlicerCreator = other
                else owner.alive = false end
            end
            equal(say(env, owner, "!findConsoleFiles 1 secret"), "")
            assert(fired); equal(#owner.chats, chats + 1, "Only the header should be emitted")
            owner.ChatPrint, owner.alive = feedback, true
            equal(env.slicerListedConsole(owner, 2), nil, "An unseen second row retained authority")
            locate(env, owner, nil, 2)
            equal(second.valid, true); equal(second.SlicerCreator, owner)
            equal(#other.chats, 0)
        end)

        test("file search stops metadata feedback after requester or target " .. change, function()
            local env = support.server(); local owner, other = env.player(), env.player()
            local ent = console(env, owner)
            local info = ent.SlicerInformation; ent.SlicerInformation = nil
            local old = getmetatable(ent).__index
            setmetatable(ent, {__index = function(self, key)
                if key == "SlicerInformation" then
                    if change == "remove" then self.valid = false elseif change == "reown" then self.SlicerCreator = other else owner.alive = false end
                    return info
                end
                return old[key]
            end})
            local chats = #owner.chats; equal(say(env, owner, "!findConsoleFiles 1 secret"), "")
            equal(#owner.chats, chats); equal(#other.chats, 0)
        end)
    end
end

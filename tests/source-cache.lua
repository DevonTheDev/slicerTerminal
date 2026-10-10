-- Exercise the source cache through real files. A temporary string.sub spy counts
-- translation work without exposing the cache or caching compiled Lua functions.
return function(_, test, equal)
    local function write(path, source)
        local file = assert(io.open(path, "w"))
        assert(file:write(source))
        assert(file:close())
    end
    local function files(sources, callback)
        local paths = {}
        local ok, message = pcall(function()
            for i, source in ipairs(sources) do
                paths[i] = os.tmpname()
                write(paths[i], source)
            end
            callback(dofile("tests/gmod.lua"), paths)
        end)
        for _, path in ipairs(paths) do os.remove(path) end
        assert(ok, message)
    end
    local function translated(gmod, path)
        local original, calls = string.sub, 0
        string.sub = function(...)
            calls = calls + 1
            return original(...)
        end
        local ok, result = pcall(gmod.source, path)
        string.sub = original
        assert(ok, result)
        return result, calls
    end
    local function hit(gmod, path, expected)
        local result, calls = translated(gmod, path)
        equal(result, expected)
        equal(calls, 0, "A repeated exact path and bytes should reuse translation")
    end
    local function miss(gmod, path, expected)
        local result, calls = translated(gmod, path)
        equal(result, expected)
        assert(calls > 0, "An uncached path and bytes must be translated")
    end
    local function comment(size, label)
        local prefix = "--[[" .. label
        return prefix .. string.rep("x", size - #prefix - 2) .. "]]"
    end

    test("source cache preserves translation bytes on misses and hits", function()
        local cases = {
            {"", ""},
            {"a != b and !c\r\n// != !\r\n", "a ~= b and not c\r\n-- != !\r\n"},
            {[[local a = "! != // \\\""; local b = '! != // \\'']],
             [[local a = "! != // \\\""; local b = '! != // \\'']]},
            {"--[==[ ! != // ]=] ]==]\n!ready", "--[==[ ! != // ]=] ]==]\nnot ready"},
            {"-- untouched ! !=\nlocal x = '\0\195\169'", "-- untouched ! !=\nlocal x = '\0\195\169'"},
            {"// no trailing newline !", "-- no trailing newline !"},
        }
        for _, case in ipairs(cases) do
            files({case[1]}, function(gmod, paths)
                equal(gmod.source(paths[1]), case[2])
                equal(gmod.source(paths[1]), case[2])
            end)
        end
    end)

    test("source cache reopens reads and closes the file on every hit", function()
        files({"return !false"}, function(gmod, paths)
            local original, opens, reads, closes = io.open, 0, 0, 0
            io.open = function(path, mode)
                local file = assert(original(path, mode))
                equal(path, paths[1]); equal(mode, "r")
                opens = opens + 1
                return {
                    read = function(_, format) reads = reads + 1; return file:read(format) end,
                    close = function() closes = closes + 1; return file:close() end,
                }
            end
            local ok, message = pcall(function()
                equal(gmod.source(paths[1]), "return not false")
                hit(gmod, paths[1], "return not false")
            end)
            io.open = original
            assert(ok, message)
            equal(opens, 2); equal(reads, 2); equal(closes, 2)
        end)
    end)

    test("source cache keys identical bytes by exact path", function()
        files({"!value", "!value"}, function(gmod, paths)
            miss(gmod, paths[1], "not value")
            miss(gmod, paths[2], "not value")
            hit(gmod, paths[1], "not value")
            hit(gmod, paths[2], "not value")
        end)
    end)

    test("source cache detects same length edits and restored bytes", function()
        files({"!first"}, function(gmod, paths)
            miss(gmod, paths[1], "not first")
            write(paths[1], "!other")
            miss(gmod, paths[1], "not other")
            hit(gmod, paths[1], "not other")
            write(paths[1], "!first")
            hit(gmod, paths[1], "not first")
            write(paths[1], "!a longer value")
            miss(gmod, paths[1], "not a longer value")
        end)
    end)

    test("source cache cannot serve a deleted file and retains its prior valid result", function()
        files({"!valid"}, function(gmod, paths)
            miss(gmod, paths[1], "not valid")
            assert(os.remove(paths[1]))
            local ok, message = pcall(gmod.source, paths[1])
            equal(ok, false)
            assert(tostring(message):find(paths[1], 1, true), "Open failure names the missing file")
            write(paths[1], "!valid")
            hit(gmod, paths[1], "not valid")
        end)
    end)

    test("source cache closes a failed read without serving or poisoning an old hit", function()
        files({"!valid"}, function(gmod, paths)
            miss(gmod, paths[1], "not valid")
            local original, closed = io.open, false
            io.open = function(path, mode)
                local file = assert(original(path, mode))
                return {read = function() return nil, "injected read failure" end,
                    close = function() closed = true; return file:close() end}
            end
            local ok, message = pcall(gmod.source, paths[1])
            io.open = original
            equal(ok, false)
            assert(tostring(message):find("nil", 1, true), "Preserve the original nil-read error")
            equal(closed, true)
            hit(gmod, paths[1], "not valid")
        end)
    end)

    test("source cache repeats translation errors and preserves the earlier valid entry", function()
        files({"!valid"}, function(gmod, paths)
            miss(gmod, paths[1], "not valid")
            write(paths[1], "--[[unclosed")
            for _ = 1, 2 do
                local ok, message = pcall(gmod.source, paths[1])
                equal(ok, false)
                assert(tostring(message):match("unclosed comment$"), "Preserve the translation error")
            end
            write(paths[1], "!valid")
            hit(gmod, paths[1], "not valid")
        end)
    end)

    test("source cache evicts the oldest entry after eight distinct keys", function()
        local sources = {}
        for i = 1, 9 do sources[i] = "!value" .. i end
        files(sources, function(gmod, paths)
            for i = 1, 8 do miss(gmod, paths[i], "not value" .. i) end
            hit(gmod, paths[1], "not value1")
            miss(gmod, paths[9], "not value9")
            hit(gmod, paths[2], "not value2")
            miss(gmod, paths[1], "not value1")
        end)
    end)

    test("source cache counts retained source and output toward its total byte bound", function()
        local sources = {comment(180000, "one"), comment(180000, "two"), comment(180000, "three")}
        files(sources, function(gmod, paths)
            for i = 1, 3 do miss(gmod, paths[i], sources[i]) end
            hit(gmod, paths[2], sources[2])
            hit(gmod, paths[3], sources[3])
            miss(gmod, paths[1], sources[1])
        end)
    end)

    test("source cache accepts a payload exactly at the combined byte limit", function()
        local source = comment(524288, "boundary")
        files({source}, function(gmod, paths)
            miss(gmod, paths[1], source)
            hit(gmod, paths[1], source)
        end)
    end)

    test("source cache skips oversized output growth without evicting valid entries", function()
        local sources = {}
        for i = 1, 8 do sources[i] = "!value" .. i end
        sources[9] = string.rep("!", 209716) -- 1,048,580 source+output bytes.
        local output = string.rep("not ", 209716)
        files(sources, function(gmod, paths)
            for i = 1, 8 do miss(gmod, paths[i], "not value" .. i) end
            miss(gmod, paths[9], output)
            miss(gmod, paths[9], output)
            for i = 1, 8 do hit(gmod, paths[i], "not value" .. i) end
        end)
    end)

    test("source cache skips a payload one source byte past the combined limit", function()
        local source = comment(524289, "oversize")
        files({source}, function(gmod, paths)
            miss(gmod, paths[1], source)
            miss(gmod, paths[1], source)
        end)
    end)

    test("source cache preserves fresh server and client functions and state", function()
        local gmod = dofile("tests/gmod.lua")
        local left, right = gmod.new(), gmod.new()
        assert(left ~= right and left._G == left and right._G == right)
        assert(left.ENT ~= right.ENT and left.ENT.Initialize ~= right.ENT.Initialize)
        assert(left.returnSpawnedEntities ~= right.returnSpawnedEntities)
        left.privateValue = true
        left.spawnedEntities[1] = {private = true}
        equal(right.privateValue, nil); equal(next(right.spawnedEntities), nil)
        local first, second = gmod.client(), gmod.client()
        assert(first ~= second and first.receivers ~= second.receivers)
        assert(first.panels ~= second.panels and first.timers ~= second.timers)
        assert(first.returnSpawnedEntities ~= second.returnSpawnedEntities)
        first.timers.privateTimer = true
        equal(second.timers.privateTimer, nil)
        left.include("weapons/weapon_hacking.lua")
        local initialize = left.SWEP.Initialize
        left.include("weapons/weapon_hacking.lua")
        assert(initialize ~= left.SWEP.Initialize, "Every include must compile a fresh chunk")
    end)
end

return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function contains(text, fragment) assert(text:find(fragment, 1, true), "Missing " .. fragment .. " in " .. text) end
    local function set(env, label, position)
        assert(env.receivers.SlicerConsoleLocation, "Missing locator receiver")
        env.receive("SlicerConsoleLocation", nil, true, label or "Console", position or env.position(100, 0, 0))
    end
    local function fit(env)
        assert(#env.draws >= 2, "Locator needs identity and useful location context")
        for _, item in ipairs(env.draws) do
            assert(item.x >= 0 and item.x + item.width <= env.width, "Text exceeds current viewport: " .. item.text)
            assert(item.y >= 0 and item.y + 16 <= env.height, "Text exceeds viewport height")
            assert(env.utf8.len(item.text), "Truncation split UTF-8")
            assert(not item.text:find("[%z\1-\31\127]"), "HUD label contains control bytes")
        end
        for _, line in ipairs(env.lines) do
            assert(line[1] >= 0 and line[1] <= env.width and line[3] >= 0 and line[3] <= env.width)
            assert(line[2] >= 0 and line[2] <= env.height and line[4] >= 0 and line[4] <= env.height)
        end
    end
    test("locator HUD consumes vector-only packets outside entity visibility and renders sampled context", function()
        local env = support.client()
        env.net.ReadEntity = function() error("Locator must not require a client entity") end
        set(env, "Console 'upper'", env.position(300, 0, 400))
        local text = env.paint()
        contains(text, "Location snapshot"); contains(text, "upper"); contains(text, "500")
        contains(text, "above"); contains(text, "400"); fit(env)
        equal(#env.messages, 0, "HUD has no outbound authority")
    end)
    test("locator HUD replaces one marker and expires 15 seconds after replacement", function()
        local env = support.client(); set(env, "first")
        env.now = 10; set(env, "second")
        local text = env.paint(); contains(text, "second"); assert(not text:find("first", 1, true))
        env.now = 24.99; contains(env.paint(), "second")
        env.now = 25; env.fire("Think"); equal(env.paint(), "")
        equal(next(env.hooks.Think or {}), nil, "Expired marker removes cleanup hook")
    end)
    test("locator cleanup never consumes the shared Think event", function()
        local env = support.client(); set(env)
        local callback = assert(env.hooks.Think.slicerConsoleLocation)
        equal(callback(), nil, "Live marker cannot suppress other addon Think hooks")
        env.now = 15
        equal(callback(), nil, "Expired marker cannot suppress other addon Think hooks")
    end)
    for _, reason in ipairs({"clear", "death", "invalid player"}) do
        test("locator HUD retires marker and hook on " .. reason, function()
            local env = support.client(); set(env)
            if reason == "clear" then env.receive("SlicerConsoleLocation", nil, false)
            elseif reason == "death" then env.localPlayer.alive = false
            else env.localPlayer.valid = false end
            env.fire("Think"); equal(env.paint(), ""); equal(next(env.hooks.Think or {}), nil)
        end)
    end
    local directions = {
        {name = "right offscreen", x = 100, y = 400, z = 0, sx = 1000, sy = 240, horizontal = "right", expected = "ahead"},
        {name = "left behind", x = -100, y = -400, z = 0, sx = 900, sy = 240, horizontal = "left", expected = "behind"},
        {name = "right behind", x = -100, y = 400, z = 0, sx = -100, sy = 240, horizontal = "right", expected = "behind"},
        {name = "directly behind", x = -100, y = 0, z = 0, sx = 320, sy = 240, vertical = "bottom", expected = "behind"},
        {name = "above offscreen", x = 100, y = 0, z = 500, sx = 320, sy = -100, vertical = "top", expected = "above"},
        {name = "below offscreen", x = 100, y = 0, z = -500, sx = 320, sy = 1000, vertical = "bottom", expected = "below"},
    }
    for _, case in ipairs(directions) do
        test("locator HUD gives bounded direction for " .. case.name, function()
            local env = support.client()
            set(env, "Target", env.position(case.x, case.y, case.z, case.sx, case.sy, false))
            contains(env.paint(), case.expected); fit(env)
            assert(#env.lines >= 2, "An edge cue must draw a directional pointer")
            local line = env.lines[1]
            if case.horizontal == "right" then assert(line[1] > env.width / 2)
            elseif case.horizontal == "left" then assert(line[1] < env.width / 2)
            elseif case.vertical == "top" then assert(line[2] < env.height / 2)
            else assert(line[2] > env.height / 2) end
        end)
    end
    test("locator HUD measures labels at current dimensions without splitting multibyte names", function()
        local env = support.client(1920, 1080)
        set(env, "Console '" .. string.rep("界", 42) .. "é' (current ID #10000000)", env.position(100, 400, 0, 3000, 100))
        env.paint(); fit(env)
        for _, size in ipairs({{640, 480}, {320, 240}, {800, 600}}) do
            env.width, env.height = size[1], size[2]
            env.paint(); fit(env)
        end
        equal(#env.panels, 0, "A waypoint does not open/focus a form")
    end)
    test("locator HUD drops malicious or invalid labels without retaining old markers", function()
        local env = support.client(); set(env, "old")
        set(env, "a\0b\9c\194\133d\226\128\168e"); env.paint(); fit(env)
        set(env, string.rep("x", 5000)); env.paint(); fit(env)
    end)
    test("locator HUD rejects non-finite coordinates before projection and clears previous marker", function()
        local env = support.client()
        for _, bad in ipairs({0 / 0, math.huge, -math.huge}) do
            for _, axis in ipairs({"x", "y", "z"}) do
                set(env, "old")
                local position = env.position(100, 0, 0); position[axis] = bad
                function position:ToScreen() error("Non-finite position reached projection") end
                set(env, "invalid", position)
                equal(env.paint(), ""); equal(next(env.hooks.Think or {}), nil)
            end
        end
    end)
end

-- Focused entry point; run from the repository root with Lua 5.3.
-- tests/run.lua also discovers every fixture below as part of the full suite.
local gmod = dofile("tests/gmod.lua")
local passed, failed = 0, 0
local function test(name, callback)
    local ok, problem = pcall(callback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(problem)) end
end
local function equal(actual, expected, message)
    assert(actual == expected, (message or "Unexpected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
dofile("tests/readable-intel-server.lua")(gmod, test, equal)
dofile("tests/readable-intel-client.lua")(gmod, test, equal)
dofile("tests/readable-intel-workflow.lua")(gmod, test, equal)
print(string.format("\n%d passed, %d failed", passed, failed))
assert(passed + failed == 106, "Readable intel must register exactly 106 reviewed cases")
if failed > 0 then os.exit(1) end

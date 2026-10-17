-- Ordinary entity/config includes must preserve this closure. No store or body
-- is attached to an entity, public settings, a registry row or Duplicator data.
if slicerIntel then return end
include("slicer/sh_intel.lua")
local bodies, players = {}, {}
local awardSerial = 0
local maximumAwardSerial = 9007199254740991
slicerIntel = {}

local function sameGeneration(entity, state)
    return IsValid(entity) and state.creationID == entity:GetCreationID()
        and state.entityIndex == entity:EntIndex()
end

function slicerIntel.GetBody(console)
    local state = bodies[console]
    if not state then return "" end
    if not sameGeneration(console, state) then bodies[console] = nil; return "" end
    return state.body
end

function slicerIntel.SetBody(console, body)
    if not IsValid(console) or console:GetClass() ~= "consoleent" then return false end
    local text = normalizeSlicerIntel(body)
    if text == nil then return false end
    bodies[console] = text ~= "" and {creationID = console:GetCreationID(),
        entityIndex = console:EntIndex(), body = text} or nil
    return true
end

function slicerIntel.ClearBody(console)
    bodies[console] = nil
end

local function playerState(ply, create)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local state = players[ply]
    if state and not sameGeneration(ply, state) then players[ply], state = nil, nil end
    if not state and create then
        state = {creationID = ply:GetCreationID(), entityIndex = ply:EntIndex()}
        players[ply] = state
    end
    return state
end

-- Called only after canComplete accepts. The record has copied scalar values,
-- no console/session reference, and is stored before any removal or delivery.
function slicerIntel.Award(ply, console, information)
    if information.fileType ~= "data" and information.fileType ~= "server" then return end
    local body = slicerIntel.GetBody(console)
    if body == "" then return end
    local state = playerState(ply, true)
    if not state or awardSerial >= maximumAwardSerial then
        return nil, "Mission intel could not be recorded. The console was kept; try again later."
    end
    awardSerial = awardSerial + 1 -- Never wrap or reuse an award identity.
    local record = {award = string.format("%.0f", awardSerial), body = body,
        consoleName = information.name, fileName = information.fileName, fileType = information.fileType}
    state.record = record
    return record
end

util.AddNetworkString("SlicerIntel")
function slicerIntel.Send(ply, record, recovery)
    local state = playerState(ply, false)
    if not state or state.record ~= record then return end
    net.Start("SlicerIntel")
        net.WriteString(record.award)
        net.WriteString(record.consoleName)
        net.WriteString(record.fileName)
        net.WriteString(record.fileType)
        net.WriteString(record.body)
        net.WriteBool(recovery == true)
    net.Send(ply)
end

hook.Add("PlayerSay", "slicerReadIntel", function(ply, text)
    if text ~= "!readIntel" and text:sub(1, 11) ~= "!readIntel " then return end
    local state = playerState(ply, true)
    if not state then return "" end
    local now = CurTime()
    if state.nextRead and now < state.nextRead then return "" end
    state.nextRead = now + 1
    if text ~= "!readIntel" then
        ply:ChatPrint("Use !readIntel with no arguments to read your most recent mission intel.")
    elseif state.record then
        slicerIntel.Send(ply, state.record, true)
    else
        ply:ChatPrint("No mission intel is available for this connection. Complete a data/server download with authored intel first.")
    end
    return ""
end)

local function clearPlayer(ply) players[ply] = nil end
hook.Add("PlayerDisconnected", "slicerClearIntel", clearPlayer)
hook.Add("PlayerInitialSpawn", "slicerClearIntel", clearPlayer)

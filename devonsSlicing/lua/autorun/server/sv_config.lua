AddCSLuaFile("entities/consoleent/shared.lua")
AddCSLuaFile("entities/consoleent/cl_init.lua")
AddCSLuaFile("weapons/weapon_hacking.lua")

entityModel = "models/props_combine/combine_interface001.mdl" -- The console model

-- Keep configuration when this file is included again by the entity loader.
spawnedEntities = spawnedEntities or {}

function returnEntityModel()
    return entityModel or "models/props_combine/combine_interface001.mdl"
end

local function validName(value)
    return type(value) == "string" and #value <= 128 and string.Trim(value) ~= ""
end

-- Setup and duplication share the same rules. Always return a new allowlisted
-- table: copied entity fields can alias the original console's live state.
function normalizeSlicerInformation(givenInformation)
    if type(givenInformation) ~= "table" then return end
    local name, delay = givenInformation.name, givenInformation.delay
    local fileType, fileName = givenInformation.fileType, givenInformation.fileName
    if not validName(name) or not validName(fileName) then return end
    if type(delay) ~= "number" or delay ~= delay or delay <= 0 or delay == math.huge then return end
    if fileType ~= "data" and fileType ~= "server" and fileType ~= "tools" then return end
    return {
        name = string.lower(string.Trim(name)),
        delay = delay,
        fileType = fileType,
        fileName = string.lower(string.Trim(fileName)),
        inUse = false,
    }
end

-- Edit authority is server-only and never travels through copied entity data.
-- Reincluding this file retires its tickets, but preserves the serial so an
-- older form can never acquire a new ticket's identity. Stop rather than wrap.
slicerSetupEditSerial = slicerSetupEditSerial or 0
local editTickets = {}
local maximumEditSerial = 9007199254740991
local reopenEdit = "Close this form and use !editConsole to reopen it."
local informationFields = {"name", "delay", "fileType", "fileName", "inUse"}

function retireSlicerSetupEdit(console)
    if console ~= nil then editTickets[console] = nil end
end

function retireSlicerSetupEditsForPlayer(ply)
    for console, ticket in pairs(editTickets) do
        if ticket.player == ply then editTickets[console] = nil end
    end
end

local function editContext(ply, console)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
    if not IsValid(console) or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply then return end
    local information = console.SlicerInformation
    local normalized = normalizeSlicerInformation(information)
    if not normalized or information.inUse
        or (slicerConsoleHasActiveSession and slicerConsoleHasActiveSession(console)) then return end
    for _, field in ipairs(informationFields) do
        if information[field] ~= normalized[field] then return end
    end
    local record
    for _, entry in pairs(spawnedEntities) do
        if entry.entity == console then
            if record or entry.entityName ~= console:GetName() or entry.information ~= information then return end
            record = entry
        end
    end
    if not record then return end
    return information, normalized, record
end

local function currentEdit(ticket, ply, console)
    local information, normalized, record = editContext(ply, console)
    if not information or ticket.player ~= ply or ticket.console ~= console
        or ticket.information ~= information or ticket.record ~= record
        or ticket.entityName ~= console:GetName() then return false end
    for _, field in ipairs(informationFields) do
        if ticket.snapshot[field] ~= normalized[field] then return false end
    end
    return true
end

local function nextEditToken()
    if type(slicerSetupEditSerial) ~= "number" or slicerSetupEditSerial < 0
        or slicerSetupEditSerial % 1 ~= 0 or slicerSetupEditSerial >= maximumEditSerial then return end
    slicerSetupEditSerial = slicerSetupEditSerial + 1
    return string.format("%.0f", slicerSetupEditSerial)
end

local function validEditToken(token)
    return type(token) == "string" and #token > 0 and #token <= 16 and token:match("^%d+$") ~= nil
end

local function editReply(ply, token, ok, message)
    -- No Entity is written: stale forms still receive errors after removal.
    net.Start("SlicerSetupEditReply")
        net.WriteString(token)
        net.WriteTable({ok = ok, message = message})
    net.Send(ply)
end

for _, name in ipairs({"SlicerSetupEditOpen", "SlicerSetupEditSave", "SlicerSetupEditReply", "SlicerSetupEditCancel"}) do
    util.AddNetworkString(name)
end

hook.Add("PlayerSay", "slicerEditConsole", function(ply, text)
    if text ~= "!editConsole" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local console = ply:GetEyeTrace().Entity
    local ticket = console ~= nil and editTickets[console] or nil
    if ticket and not currentEdit(ticket, ticket.player, console) then
        retireSlicerSetupEdit(console)
        ticket = nil
    end
    local information, normalized, record = editContext(ply, console)
    if not information then
        ply:ChatPrint("Look at one of your configured, idle consoles and type !editConsole to edit it.")
        return ""
    end
    if not ticket then
        local token = nextEditToken()
        if not token then
            ply:ChatPrint("An edit cannot be opened right now.")
            return ""
        end
        ticket = {player = ply, console = console, token = token,
            information = information, snapshot = normalized, record = record, entityName = console:GetName(),
            displayIdentity = {creationID = console:GetCreationID(), entityIndex = console:EntIndex()}}
        editTickets[console] = ticket
    end
    -- Display context is captured per ticket, separate from its five saved fields.
    local payload = table.Copy(ticket.snapshot)
    payload.displayIdentity = table.Copy(ticket.displayIdentity)
    net.Start("SlicerSetupEditOpen")
        net.WriteEntity(console)
        net.WriteEntity(ply)
        net.WriteString(ticket.token)
        net.WriteTable(payload)
    net.Send(ply)
    return ""
end)

net.Receive("SlicerSetupEditSave", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local console, token, fields = net.ReadEntity(), net.ReadString(), net.ReadTable()
    if not validEditToken(token) then return end
    local ticket = console ~= nil and editTickets[console] or nil
    if not ticket or ticket.player ~= ply or ticket.console ~= console or ticket.token ~= token then
        editReply(ply, token, false, "This edit is no longer current. " .. reopenEdit)
        return
    end
    if not currentEdit(ticket, ply, console) then
        retireSlicerSetupEdit(console)
        editReply(ply, token, false, "This console is unavailable or its setup has changed. " .. reopenEdit)
        return
    end
    local information = type(fields) == "table" and normalizeSlicerInformation({
        name = fields.name, delay = fields.delay, fileName = fields.fileName,
        fileType = ticket.snapshot.fileType,
    }) or nil
    if not information then
        editReply(ply, token, false, "Use nonblank names of at most 128 bytes and a finite positive delay.")
        return
    end
    console.SlicerInformation = information
    ticket.record.information = information
    retireSlicerSetupEdit(console)
    editReply(ply, token, true, "Console setup updated.")
end)

net.Receive("SlicerSetupEditCancel", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local console, token = net.ReadEntity(), net.ReadString()
    local ticket = console ~= nil and editTickets[console] or nil
    if ticket and ticket.player == ply and ticket.console == console and ticket.token == token then
        retireSlicerSetupEdit(console)
    end
end)

-- Initial setup keeps the legacy five fields. A sixth field only correlates a
-- reply; it never grants authority or permits an existing setup to be replaced.
local function validInitialSetupToken(token)
    return type(token) == "string" and #token <= 16 and token:match("^[1-9]%d*$") ~= nil
        and (#token < 16 or token <= "9007199254740991")
end

local function initialSetupReply(ply, token, result)
    if token == nil then return end -- Legacy clients did not request a reply.
    net.Start("SlicerInitialSetupReply")
        net.WriteString(token)
        net.WriteTable(result)
    net.Send(ply)
end

util.AddNetworkString("AdminFinishedCreation")
util.AddNetworkString("SlicerInitialSetupReply")
net.Receive("AdminFinishedCreation", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    local givenInformation = net.ReadTable()
    if type(givenInformation) ~= "table" then return end

    local token = givenInformation[6]
    if token ~= nil and not validInitialSetupToken(token) then return end

    -- [name, delay, fileType, fileName, entityName, optional token] comes from the client.
    local name, delay, fileType, fileName, entityName = givenInformation[1], givenInformation[2], givenInformation[3], givenInformation[4], givenInformation[5]
    local information = normalizeSlicerInformation({name = name, delay = delay, fileType = fileType, fileName = fileName})
    if type(entityName) ~= "string" or not information then
        initialSetupReply(ply, token, {ok = false,
            message = "Invalid setup: choose a folder, nonblank names of at most 128 bytes, and a finite positive delay."})
        return
    end

    local target
    for _, console in ipairs(ents.FindByClass("consoleent")) do
        if console:GetName() == entityName and console.SlicerCreator == ply and not console.SlicerInformation then
            if target then
                initialSetupReply(ply, token, {ok = false,
                    message = "This console's identity is ambiguous. Close this form and use a uniquely named console."})
                return
            end
            target = console
        end
    end
    if not target then
        initialSetupReply(ply, token, {ok = false,
            message = "This console is unavailable or already configured. Close this form and use the console again if setup is still available."})
        return
    end

    target.SlicerInformation = information
    table.insert(spawnedEntities, {entityName = entityName, entity = target, information = information})
    if fileType == "tools" then ply.SlicerPendingConsole = target end
    initialSetupReply(ply, token, {ok = true, name = information.name, fileType = information.fileType})
end)

function returnSpawnedEntities()
    return spawnedEntities
end

function updateInUse(consoleName, setValue)
    for _, entry in pairs(spawnedEntities) do
        if entry.entityName == consoleName then
            if setValue ~= nil then
                entry.information.inUse = setValue
            else
                entry.information.inUse = not entry.information.inUse
            end
        end
    end
end

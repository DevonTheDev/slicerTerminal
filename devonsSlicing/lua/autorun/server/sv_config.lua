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

util.AddNetworkString("AdminFinishedCreation")
net.Receive("AdminFinishedCreation", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    local givenInformation = net.ReadTable()
    if type(givenInformation) ~= "table" then return end

    -- [name, delay, fileType, fileName, entityName] comes from the client.
    local name, delay, fileType, fileName, entityName = givenInformation[1], givenInformation[2], givenInformation[3], givenInformation[4], givenInformation[5]
    if not validName(name) or not validName(fileName) or type(entityName) ~= "string" then return end
    if type(delay) ~= "number" or delay ~= delay or delay <= 0 or delay == math.huge then return end
    if fileType ~= "data" and fileType ~= "server" and fileType ~= "tools" then return end

    for _, console in ipairs(ents.FindByClass("consoleent")) do
        if console:GetName() == entityName and console.SlicerCreator == ply and not console.SlicerInformation then
            local information = {
                name = string.lower(string.Trim(name)),
                delay = delay,
                fileType = fileType,
                fileName = string.lower(string.Trim(fileName)),
                inUse = false,
            }
            console.SlicerInformation = information
            table.insert(spawnedEntities, {entityName = entityName, entity = console, information = information})
            if fileType == "tools" then ply.SlicerPendingConsole = console end
            return
        end
    end
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

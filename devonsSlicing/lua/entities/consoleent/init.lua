AddCSLuaFile("entities/consoleent/cl_init.lua")
AddCSLuaFile("entities/consoleent/shared.lua")

include("entities/consoleent/shared.lua")
include("autorun/server/sv_config.lua")

local sessions = {}
local linkedDoors = {}
local consoleListings = {}
local listingLifetime = 60

-- Configuration flags can be changed by legacy callers independently of a
-- reservation. Editing and link recovery also consult server-owned sessions.
function slicerConsoleHasActiveSession(console)
    for _, session in pairs(sessions) do
        if session.console == console then return true end
    end
    return false
end

for _, name in ipairs({
    "PlayerSpawnedConsole", "ServerSendsEntityInformation", "updateInUse",
    "PlayerDied", "playerQuitConsole", "ServerWaitingForEntity", "PlayerAlert",
    "PlayerActivatedDoor", "destroyOnServer", "SlicerCompleted", "SlicerConsoleLocation",
}) do
    util.AddNetworkString(name)
end

local function releaseSession(ply, closeUI)
    local session = sessions[ply]
    if not session then return end
    sessions[ply] = nil
    if IsValid(session.console) and session.console:GetCreationID() == session.consoleCreationID
        and session.console:EntIndex() == session.consoleIndex and session.console.SlicerInformation then
        session.console.SlicerInformation.inUse = false
    end
    if closeUI and IsValid(ply) then
        net.Start("PlayerDied")
        net.Send(ply)
    end
end

local function hasHackingTool(ply)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
    local weapon = ply:GetActiveWeapon()
    return IsValid(weapon) and weapon:GetClass() == "weapon_hacking"
end

local function canLinkConsole(ply, console)
    if not IsValid(console) or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply then return false end
    local information = console.SlicerInformation
    -- A removed door still counts as a previous assignment until its creator
    -- explicitly clears it with !resetLink. Selection cannot redirect a hack.
    return information and information.fileType == "tools"
        and console.SlicerDoor == nil and not information.inUse
end

local selectionInstruction = "Look at one of your configured, unlinked tools consoles and type !setEntity to select it."
local supportedDoors = {func_door = true, func_door_rotating = true}
local doorClassNames = "func_door or func_door_rotating"

function ENT:Initialize()
    self:SetModel(returnEntityModel())
    self:SetSolid(SOLID_BBOX)
    self:SetUseType(SIMPLE_USE)
    -- Runtime names follow creation IDs, independently of the live count.
    self:SetName("DevonsConsoleEntity" .. self:GetCreationID())
end

function ENT:OnEntityCopyTableFinish(data)
    -- Replace this table rather than editing inUse on an aliased live original.
    data.SlicerInformation = normalizeSlicerInformation(data.SlicerInformation)
    data.SlicerCreator, data.SlicerDoor = nil, nil
end

local function resetCopiedState(console)
    slicerIntel.ClearBody(console)
    retireSlicerInitialSetup(console)
    retireSlicerSetupEdit(console)
    console.SlicerCreator, console.SlicerDoor = nil, nil
    console.SlicerInformation = normalizeSlicerInformation(console.SlicerInformation)
    if IsValid(console) then
        console:SetName("DevonsConsoleEntity" .. console:GetCreationID())
    end
end

function ENT:OnDuplicated()
    -- Generic restoration precedes this hook; modifiers run afterward. Remove
    -- copied authority before a modifier can remove the newly spawned entity.
    resetCopiedState(self)
end

function ENT:PostEntityPaste(ply)
    if not IsValid(self) then return end
    -- Modifiers may have restored legacy fields. Revalidate and clear again,
    -- even on invalid-actor paths, before rejecting only this new entity.
    resetCopiedState(self)
    if not IsValid(ply) or not ply:IsPlayer() then
        self:Remove()
        return
    end
    self.SlicerCreator = ply

    -- Rebuild only this entity's record, without reusing a copied table or
    -- appending duplicates if another paste hook already registered it.
    for i = #spawnedEntities, 1, -1 do
        if spawnedEntities[i].entity == self then table.remove(spawnedEntities, i) end
    end
    local information = self.SlicerInformation
    if information then
        table.insert(spawnedEntities, {entityName = self:GetName(), entity = self, information = information})
        if information.fileType == "tools" then
            ply:ChatPrint("Copied tools console is unlinked. Look at it and type !setEntity, then look at a " .. doorClassNames .. " and type !setEntity to link it.")
        else
            ply:ChatPrint("Copied console has no mission intel. Use !editConsole to add it after pasting.")
        end
    else
        ply:ChatPrint("Copied console needs setup. Use it to configure it.")
    end
end

local function openSetup(ply, ent, listed)
    if not IsValid(ply) or not ply:IsPlayer() or (listed and not IsValid(ply)) or not ply:Alive() then return end
    local name = listed and listed.name or ent:GetName()
    local token, currentTicket = prepareSlicerInitialSetup(ply, ent, name)
    -- Ticket preparation precedes the existing final listed guard. Afterwards
    -- only captured scalars and private map ownership are consulted.
    if listed and not listed.current() then return end
    if currentTicket and not currentTicket() then return end
    net.Start("PlayerSpawnedConsole")
        net.WriteEntity(ply)
        net.WriteString(name)
        -- Even issuance failure advertises modern capability and fails closed.
        net.WriteString("slicer-initial-v2:" .. (token or ""))
    net.Send(ply)
    return true
end

hook.Add("PlayerSpawnedSENT", "checkForConsole", function(ply, ent)
    if not IsValid(ent) or ent:GetClass() ~= "consoleent" then return end
    ent.SlicerCreator = ply
    openSetup(ply, ent)
end)

function ENT:AcceptInput(name, activator, caller)
    if name ~= "Use" or not IsValid(self) or not IsValid(activator) or not activator:IsPlayer() then return end
    local information = self.SlicerInformation
    if not information then
        -- Initial setup belongs to the creator and needs no hacking tool.
        -- Reopening does not reserve a hack or change a pending door choice.
        if self.SlicerCreator == activator then openSetup(activator, self) end
        return
    end
    if not hasHackingTool(activator) then
        activator:ChatPrint("You don't have the necessary tools to hack this console.")
        return
    end

    if information.fileType == "tools" and not IsValid(self.SlicerDoor) then
        local message = "This console does not have a linked door yet."
        if canLinkConsole(activator, self) then message = message .. " " .. selectionInstruction end
        activator:ChatPrint(message)
        return
    end
    if information.inUse or sessions[activator] then
        local message = "This console or your hacking tool is already in use."
        if sessions[activator] then message = message .. " Type !quitConsole to leave your current session." end
        activator:ChatPrint(message)
        return
    end

    -- Reserve on the server before another player's Use can be handled. The
    -- client expects inUse=false in its own opening message.
    local clientInformation = {name = information.name, delay = information.delay,
        fileName = information.fileName, fileType = information.fileType, inUse = false}
    retireSlicerSetupEdit(self)
    information.inUse = true
    sessions[activator] = {
        console = self, consoleCreationID = self:GetCreationID(), consoleIndex = self:EntIndex(),
        playerCreationID = activator:GetCreationID(), playerIndex = activator:EntIndex(),
        completeAt = CurTime() + information.delay * (information.fileType == "tools" and 1 or 2),
    }
    net.Start("ServerSendsEntityInformation")
        net.WriteEntity(self)
        net.WriteEntity(activator)
        net.WriteTable(clientInformation)
        net.WriteString(self:GetName())
    net.Send(activator)
end

-- Kept for existing clients; reservation is now authoritative in AcceptInput.
net.Receive("updateInUse", function() end)

hook.Add("PlayerDeath", "checkForInConsole", function(victim)
    consoleListings[victim] = nil
    retireSlicerSetupEditsForPlayer(victim)
    releaseSession(victim, true)
end)

hook.Add("PlayerDisconnected", "slicerReleaseConsole", function(ply)
    retireSlicerInitialSetupsForPlayer(ply)
    consoleListings[ply] = nil
    retireSlicerSetupEditsForPlayer(ply)
    releaseSession(ply, false)
    ply.SlicerPendingConsole = nil
end)

net.Receive("playerQuitConsole", function(_, ply)
    -- Never trust the player/entity IDs in the legacy payload.
    releaseSession(ply, false)
end)

-- Static, requester-private help needs no game-state reads or live authority.
-- Keep it in the existing hook; every other command retains its own checks.
local slicerHelp = {
    ["!slicerHelp"] = {
        "Slicer chat help: !slicerHelp browse | !slicerHelp setup | !slicerHelp links | !slicerHelp hacking",
        "Help is available alive or dead. It changes nothing; each action keeps its living-player, creator and tool requirements.",
        "Use exact command spelling and one ASCII space before a lowercase topic. In a terminal, Commands (/help) shows that screen's commands.",
    },
    ["!slicerHelp browse"] = {
        "Browse your own consoles while alive; these commands need no hacking tool or eye target.",
        "!listConsoles [<page> [<state>]]: list; !nearConsoles [<page> [<state>]]: nearest first.",
        "!findConsoles <page> <text>: search saved names literally (ASCII case-insensitive).",
        "!findConsoleFiles <page> <text>: search saved filename/folder in valid saved configurations (literal, ASCII case-insensitive).",
        "!listConsoles <page> <state> <text> or !nearConsoles <page> <state> <text>: combine state and name; setup does not accept text.",
        "States: setup, unlinked, unconfirmed, linked, reserved. Pages: 1-7 digits, no leading zero.",
        "Text: 1-128 bytes, no edge spaces or controls. Use one ASCII space between arguments.",
        "!locateConsole <row> marks a row; !locateConsole pending marks your selected console; !locateConsole clear hides your marker.",
        "!inspectConsole <row> privately shows the saved name, folder, base delay and filename, including while busy.",
        "Rows 1-5 are exact entities for 60 seconds; actions do not renew them. New list/find/near requests replace them; malformed/empty requests clear them. Ownership and eligibility still apply.",
    },
    ["!slicerHelp setup"] = {
        "Setup/edit require the living console creator. Use your unconfigured console to open setup without a hacking tool.",
        "!setupConsole <row> opens an unconfigured, unreserved listed console with a unique runtime name among your consoles.",
        "!editConsole or !editConsole <row> opens a configured, idle console for name, delay and filename edits.",
        "Data/server mission intel is optional: add it after initial setup with !editConsole (4096-byte plain text). Duplicator copies omit it.",
        "Only the downloader's latest intel is retained; newer intel replaces unread content and disconnect loses it.",
        "Bare !editConsole uses your eye target; row commands use your last list/find/near page (1-5, up to 60 seconds).",
        "Opening a form does not save it. Submit with Done or Save changes; accepted tools setup selects that console for linking.",
    },
    ["!slicerHelp links"] = {
        "Console selection, inspection and link changes remain creator-only. Row selection, cancel, inspect, reset and unlink require a living player.",
        "!setEntity: look at your configured, idle, unlinked tools console to select it, then at a door to link.",
        "!setEntity <row> selects an eligible console from your last list/find/near page (1-5, up to 60 seconds).",
        "Supported doors: func_door and func_door_rotating. !cancelLink clears only your pending selection.",
        "!pendingLink privately shows your current pending console, without an eye target or tool; linking rechecks eligibility.",
        "!locateConsole pending marks your live owned selection for 15 seconds, even after its catalogue page expires or changes.",
        "!inspectLink: look at your console or its registered door for private link information.",
        "!unlinkConsole or !unlinkConsole <row>: clear your idle tools console's registered live link and send Unlock; bare uses your eye target, row uses your last list/find/near page (1-5, up to 60 seconds).",
        "!resetLink: look at your configured, idle tools console to clear a removed door's old link before selecting a replacement.",
        "!resetLink <row>: recover that console from your last list/find/near page (1-5, up to 60 seconds), then explicitly select it with !setEntity <row>. Live doors cannot be reset.",
    },
    ["!slicerHelp hacking"] = {
        "To hack, a living player equips Devons Hacking Tool and uses Use on a configured, available console. Tools consoles need a linked door.",
        "In the terminal, click Commands (/help) or enter /help for the current screen's exact commands. Inserting one does not submit it.",
        "!hackStatus privately shows your session's server minimum wait, not client progress or completion. You must be alive; no tool or eye target is needed.",
        "!quitConsole leaves only your current hacking session, even if its page is missing. You must be alive; no tool or eye target is needed.",
        "!readIntel opens or recovers your most recent authored mission intel; it works alive or dead, without a tool (one request per second).",
        "Only the latest intel-bearing download is kept, even if unread. Disconnect/map change loses it; older replaced intel cannot be recovered.",
        "Quitting preserves the console and saved links. Use it again for a fresh attempt; quitting cannot undo an accepted completion.",
    },
}
local slicerHelpUsage = {"Usage: !slicerHelp, !slicerHelp browse, !slicerHelp setup, !slicerHelp links, or !slicerHelp hacking (exact spelling, one space)."}

hook.Add("PlayerSay", "slicerQuitConsole", function(ply, text)
    if type(text) == "string" and (text == "!slicerHelp" or text:find("^!slicerHelp%s")) then
        -- Stop on requester/reply errors without exposing recognized help as chat.
        pcall(function()
            if not IsValid(ply) or not ply:IsPlayer() then return end
            -- Bound before lookup. Malformed input never appears in the reply.
            local messages = #text <= 19 and slicerHelp[text] or nil
            for _, message in ipairs(messages or slicerHelpUsage) do ply:ChatPrint(message) end
        end)
        return ""
    end
    -- A lost terminal page must not strand its player's server reservation.
    if text ~= "!quitConsole" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    if sessions[ply] then
        releaseSession(ply, true)
        ply:ChatPrint("You left your hacking session. Use the console again to start a fresh attempt.")
    else
        ply:ChatPrint("You are not in a hacking session.")
    end
    return ""
end)

-- Configuration records the pending console on the authenticated creator.
-- The legacy packet is unnecessary and must not select another player's door.
net.Receive("ServerWaitingForEntity", function() end)

hook.Add("PlayerSay", "slicerCancelLink", function(ply, text)
    if text ~= "!cancelLink" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local message = ply.SlicerPendingConsole ~= nil
        and "Pending door-link selection canceled. Use !setEntity on one of your unlinked tools consoles to select again."
        or "You have no pending door-link selection."
    -- Clear only the caller's choice, even if stale. Feedback can reenter the
    -- selector, so commit before ChatPrint and leave any newer selection alone.
    ply.SlicerPendingConsole = nil
    ply:ChatPrint(message)
    return ""
end)

local function selectConsole(ply, console)
    -- Commit before feedback can reenter selection, cancel or remove a console.
    ply.SlicerPendingConsole = console
    ply:ChatPrint("Selected '" .. console.SlicerInformation.name .. "'. Look at a " .. doorClassNames .. " and use !setEntity to link, or !cancelLink to cancel.")
    return ""
end

hook.Add("PlayerSay", "doesThePlayerSetAnEntity", function(ply, text)
    local row = #text == 12 and text:match("^!setEntity ([1-5])$")
    if row then
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
        -- Resolve the current listing closure without refreshing its lease or
        -- consulting eye trace. IDs and current list order are not authority.
        local console = type(slicerListedConsole) == "function" and slicerListedConsole(ply, tonumber(row))
        if not console then
            ply:ChatPrint("That console row is unavailable or expired. Use !listConsoles or !findConsoles again, then !setEntity <row>.")
            return ""
        end
        local information = normalizeSlicerInformation(console.SlicerInformation)
        if not information or information.fileType ~= "tools" or not canLinkConsole(ply, console)
            or slicerConsoleHasActiveSession(console) then
            ply:ChatPrint("That listed console cannot be selected. " .. selectionInstruction .. " It must not be in use.")
            return ""
        end
        return selectConsole(ply, console)
    end
    if text ~= "!setEntity" then return end
    local target = ply:GetEyeTrace().Entity
    if IsValid(target) and target:GetClass() == "consoleent" then
        if not canLinkConsole(ply, target) then
            ply:ChatPrint("That console cannot be selected. " .. selectionInstruction .. " It must not be in use.")
            return
        end
        return selectConsole(ply, target)
    end

    local console = ply.SlicerPendingConsole
    -- Recheck every condition at the final link, including setup's automatic
    -- selection. Rejected targets never replace the current pending choice.
    if not canLinkConsole(ply, console) then
        ply:ChatPrint(selectionInstruction)
        return
    end
    local door = target
    if not IsValid(door) or not supportedDoors[door:GetClass()] then
        ply:ChatPrint("That is not a valid door object. Look at a " .. doorClassNames .. " and type !setEntity to retry.")
        return
    end
    if IsValid(linkedDoors[door]) then
        ply:ChatPrint("That door is already linked to a console. Look at another " .. doorClassNames .. " and type !setEntity to retry.")
        return
    end
    console.SlicerDoor = door
    linkedDoors[door] = console
    ply.SlicerPendingConsole = nil
    door:Fire("Lock")
    ply:ChatPrint("Entity successfully set")
    return ""
end)

local function inspectionText(text)
    return (text:gsub("[%z\1-\31\127]", "?"):gsub("\194[\128-\159]", "?")
        :gsub("\226\128[\168\169]", "?"))
end

hook.Add("PlayerSay", "slicerPendingLink", function(ply, text)
    if text ~= "!pendingLink" then return end
    -- A failed native read or private reply must not publish recognized chat.
    pcall(function()
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
        local console = ply.SlicerPendingConsole
        local live = console ~= nil and IsValid(console)
        local creator, class
        if live then
            -- Capture ordinary fields before accessors can reenter. Neither
            -- a saved name nor a creation ID resolves or authorizes a choice.
            creator = console.SlicerCreator
            class = console:GetClass()
        end
        local message = "You have no pending door-link selection."
        if console ~= nil then
            message = "Your pending door-link selection is unavailable. Use !cancelLink, or !setEntity on an eligible console to select again."
            if live and class == "consoleent" and creator == ply then
                local information = console.SlicerInformation
                local name = type(information) == "table" and information.name
                local label = "Your pending console"
                if type(name) == "string" and #name <= 128 and string.Trim(name) ~= "" then
                    label = label .. " '" .. inspectionText(name) .. "'"
                end
                local getID = console.GetCreationID
                local id = type(getID) == "function" and getID(console)
                if type(id) == "number" and id >= 0 and id <= 10000000 and id == math.floor(id) then
                    label = label .. " (current ID #" .. string.format("%.0f", id) .. ")"
                end
                message = label .. "; linking rechecks eligibility."
            end
        end
        -- Resolve feedback before rechecking the captured entity and caller.
        -- Suppress obsolete replies; never restore, clear or renew a choice.
        -- These are synchronous native-accessor checks, not a reply registry.
        local feedback = ply.ChatPrint
        if (console ~= nil and IsValid(console)) ~= live then return end
        if live and (console:GetClass() ~= class or console.SlicerCreator ~= creator or not IsValid(console)) then return end
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
        if ply.SlicerPendingConsole ~= console then return end
        feedback(ply, message)
    end)
    return ""
end)

local function inspectionLabel(console, information)
    information = information or console.SlicerInformation
    local name = type(information) == "table" and information.name or nil
    local label = "Console"
    if type(name) == "string" and #name <= 128 and string.Trim(name) ~= "" then
        -- Sanitize only the displayed copy. Keeping the whole bounded name
        -- avoids cutting a valid multibyte character at ChatPrint's byte limit.
        label = label .. " '" .. inspectionText(name) .. "'"
    end
    -- Native creation IDs wrap; these are current labels, never authority.
    return label .. " (current ID #" .. console:GetCreationID() .. "): "
end

hook.Add("PlayerSay", "slicerResetLink", function(ply, text)
    local digits = type(text) == "string" and #text == 12 and text:match("^!resetLink ([1-5])$")
    if text ~= "!resetLink" and not digits then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local row = digits and tonumber(digits)
    local listing = row and consoleListings[ply]
    local console
    local function unavailable()
        ply:ChatPrint("That console row is unavailable or expired. Use !listConsoles, !findConsoles or !nearConsoles again, then !resetLink <row>.")
        return ""
    end
    if row then
        -- Capture the original page and exact entity before resolver callbacks.
        console = listing and listing.rows[row]
        if slicerListedConsole(ply, row) ~= console or not console then return unavailable() end
    else
        console = ply:GetEyeTrace().Entity
    end
    local information = IsValid(console) and console:GetClass() == "consoleent" and console.SlicerCreator == ply
        and normalizeSlicerInformation(console.SlicerInformation)
    -- Validate a separate copy without replacing saved fields, records or edit
    -- tickets. The raw busy flag and actual reservation independently veto reset.
    if not information or information.fileType ~= "tools" or console.SlicerInformation.inUse
        or slicerConsoleHasActiveSession(console) then
        ply:ChatPrint(row and "That listed console cannot be reset. It must be your configured, idle tools console with a removed door."
            or "Look at one of your configured, idle tools consoles with a removed door and type !resetLink.")
        return ""
    end
    local door, message = console.SlicerDoor
    if door == nil then
        message = row and "has no link to reset. !listConsoles again; find this console, then !setEntity <row>."
            or "has no link to reset. Use !setEntity to select it."
    elseif IsValid(door) then
        message = "still has an available door; its link was not changed."
    else
        -- A newer page cannot authorize this earlier request, even when its
        -- row points at the same console. Neither reset outcome renews a page.
        if row and (consoleListings[ply] ~= listing or listing.rows[row] ~= console
            or CurTime() >= listing.expires or consoleListings[ply] ~= listing) then return unavailable() end
        console.SlicerDoor = nil
        if linkedDoors[door] == console then linkedDoors[door] = nil end
        message = row and "old link cleared. !listConsoles again; find this console, then !setEntity <row>."
            or "old link cleared. Use !setEntity on this console, then on a replacement door."
    end
    ply:ChatPrint(inspectionLabel(console) .. message)
    return ""
end)

hook.Add("PlayerSay", "slicerUnlinkConsole", function(ply, text)
    local digits = type(text) == "string" and #text == 16 and text:match("^!unlinkConsole ([1-5])$")
    if text ~= "!unlinkConsole" and not digits then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local row = digits and tonumber(digits)
    local listing = row and consoleListings[ply]
    local expires = listing and listing.expires
    local console
    local function unavailable()
        ply:ChatPrint("That console row is unavailable or expired. Use !listConsoles, !findConsoles or !nearConsoles again, then !unlinkConsole <row>.")
        return ""
    end
    if row then
        -- Keep the original private lease and entity across resolver callbacks.
        console = listing and listing.rows[row]
        if slicerListedConsole(ply, row) ~= console or not console then return unavailable() end
    else
        console = ply:GetEyeTrace().Entity
    end
    local information = IsValid(console) and console:GetClass() == "consoleent" and console.SlicerCreator == ply
        and normalizeSlicerInformation(console.SlicerInformation)
    if not information or information.fileType ~= "tools" or console.SlicerInformation.inUse
        or slicerConsoleHasActiveSession(console) then
        ply:ChatPrint(row and "That listed console cannot be unlinked. It must be your configured, idle tools console with a registered live door."
            or "Look at one of your configured, idle tools consoles and type !unlinkConsole.")
        return ""
    end
    local label, door, message = inspectionLabel(console), console.SlicerDoor
    if door == nil then
        message = row and "has no door link. !listConsoles again; find this console, then !setEntity <row>."
            or "has no door link. Use !setEntity to select it."
    elseif not IsValid(door) then
        message = row and "door no longer available. !listConsoles again; find this console, then !resetLink <row>."
            or "previous door is no longer available. Use !resetLink on this console."
    elseif not supportedDoors[door:GetClass()] or linkedDoors[door] ~= console then
        message = "no registered link can be confirmed; nothing was changed."
    else
        -- A replacement page cannot authorize an earlier request, even for
        -- the same entity. Recheck the original deadline immediately before mutation.
        if row and (consoleListings[ply] ~= listing or listing.rows[row] ~= console
            or CurTime() >= expires or consoleListings[ply] ~= listing) then return unavailable() end
        -- Relinquish only this proven association before native input can
        -- remove the console or reenter linking. Never roll back over a new link.
        console.SlicerDoor, linkedDoors[door] = nil, nil
        local sent = pcall(door.Fire, door, "Unlock")
        message = sent
            and (row and "old link cleared; Unlock sent. If still unlinked, !listConsoles; find it; !setEntity <row>"
                or "old link cleared; Unlock sent. If still unlinked, use !setEntity here, then on a door.")
            or "old link cleared; Unlock failed. Check the previous door before using !setEntity."
    end
    -- Native input may remove either entity. Report the captured old association
    -- without inspecting the console again or promising physical door movement.
    if IsValid(ply) then ply:ChatPrint(label .. message) end
    return ""
end)

local function inspectConsoleLink(console, information)
    local label = inspectionLabel(console)
    if console.SlicerInformation == nil then return label .. "needs setup. Use it to configure it." end
    if not information then return label .. "invalid configuration; no registered link can be confirmed." end
    if information.fileType ~= "tools" then
        return label .. "configured for " .. information.fileType .. "; door linking is for tools consoles."
    end
    local door = console.SlicerDoor
    if door == nil then return label .. "has no door link." end
    if not IsValid(door) then
        return label .. "previous door is no longer available. When idle, use !resetLink on this console."
    end
    if not supportedDoors[door:GetClass()] or linkedDoors[door] ~= console then
        return label .. "no registered link can be confirmed in this server session."
    end
    return label .. "registered link to " .. door:GetClass() .. " (current ID #" .. door:GetCreationID() .. ")."
end

hook.Add("PlayerSay", "slicerInspectLink", function(ply, text)
    if text ~= "!inspectLink" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local target = ply:GetEyeTrace().Entity
    local message = "Look at one of your consoles or its registered door and type !inspectLink."
    if IsValid(target) then
        if target:GetClass() == "consoleent" and target.SlicerCreator == ply then
            -- Validation returns a separate copy; inspection never normalizes
            -- saved data or repairs a missing link, selection, ticket or session.
            message = inspectConsoleLink(target, normalizeSlicerInformation(target.SlicerInformation))
        elseif supportedDoors[target:GetClass()] then
            local console = linkedDoors[target]
            if IsValid(console) and console:GetClass() == "consoleent"
                and console.SlicerCreator == ply and console.SlicerDoor == target then
                local information = normalizeSlicerInformation(console.SlicerInformation)
                if information and information.fileType == "tools" then
                    message = inspectConsoleLink(console, information)
                end
            end
        end
    end
    -- One private line stays below 255 bytes even with a 128-byte name and
    -- maximum native IDs. No weapon, busy-state claim or network/UI is needed.
    ply:ChatPrint(message)
    return ""
end)

local listConsolesCommand = "!listConsoles"
local nearConsolesCommand = "!nearConsoles"
local consolesPerPage = 5

-- Only ASCII A-Z fold. Preserve every other saved byte, independently of
-- locale, Unicode normalization and display-only control cleanup.
local function foldConsoleName(name)
    return (name:gsub("[A-Z]", function(character)
        return string.char(string.byte(character) + 32)
    end))
end

local function validConsoleQuery(query)
    return query and #query > 0 and #query <= 128 and query:sub(1, 1) ~= " " and query:sub(-1) ~= " "
        and not query:find("[%z\1-\31\127]") and not query:find("\194[\128-\159]") and not query:find("\226\128[\168\169]")
end

local function matchesConsoleState(console, state)
    if state == "setup" then return console.SlicerInformation == nil end
    if state == "reserved" then return slicerConsoleHasActiveSession(console) end
    local information = normalizeSlicerInformation(console.SlicerInformation)
    if not information or information.fileType ~= "tools" then return false end
    local door = console.SlicerDoor
    if state == "unlinked" then return door == nil end
    if state == "linked" then
        return IsValid(door) and supportedDoors[door:GetClass()] and linkedDoors[door] == console
    end
    return door ~= nil and (not IsValid(door) or not supportedDoors[door:GetClass()] or linkedDoors[door] ~= console)
end

local function finiteConsoleNumber(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
end

-- Reply ownership lasts only for this synchronous command. A nested status
-- request retires the outer reply without changing the hacking reservation.
local hackStatusReplies = {}
hook.Add("PlayerSay", "slicerHackStatus", function(ply, text)
    if text ~= "!hackStatus" then return end
    if ply == nil then return "" end
    local reply, session = {}, sessions[ply]
    local console = session and session.console
    hackStatusReplies[ply] = reply
    local function current(requireConsole)
        if hackStatusReplies[ply] ~= reply then return false end
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
        if requireConsole and (not IsValid(console) or console:GetClass() ~= "consoleent") then return false end
        -- Check private identity last, after engine accessors can reenter.
        return hackStatusReplies[ply] == reply and sessions[ply] == session
            and (not session or session.console == console)
    end
    -- Recognized status stays private even if an accessor or ChatPrint fails.
    pcall(function()
        if not current(false) then return end
        if not session then
            ply:ChatPrint("You are not in a hacking session.")
            return
        end
        local validConsole = IsValid(console) and console:GetClass() == "consoleent"
        local deadline, now = session.completeAt, CurTime()
        local remaining = finiteConsoleNumber(deadline) and finiteConsoleNumber(now) and deadline - now
        if not validConsole or not finiteConsoleNumber(remaining) then
            if current(false) then
                ply:ChatPrint("Your hacking session status is unavailable. Use !quitConsole to leave it, then use the console again.")
            end
            return
        end
        local information = console.SlicerInformation
        local name = type(information) == "table" and information.name
        local label = "You have a current hacking session."
        if type(name) == "string" and #name <= 128 and string.Trim(name) ~= "" then
            label = "Your hacking session: console '" .. inspectionText(name) .. "'."
        end
        local messages = {
            label,
            remaining > 0
                and "Server minimum wait: " .. string.format("%.17g", math.ceil(remaining)) .. " seconds remaining."
                or "Server minimum wait has elapsed; this does not mean the hack is complete.",
            "Finish the terminal steps, or use !quitConsole to leave your session. The server does not track your current screen or countdown.",
        }
        for _, message in ipairs(messages) do
            if not current(true) then return end
            ply:ChatPrint(message)
        end
    end)
    if hackStatusReplies[ply] == reply then hackStatusReplies[ply] = nil end
    return ""
end)

-- GetPos may be unavailable on a retiring entity. Copy finite native vector
-- coordinates once, so later samples cannot mutate the request's distances.
local function consolePositionSnapshot(entity)
    local ok, x, y, z = pcall(function()
        local position = entity:GetPos()
        return position.x, position.y, position.z
    end)
    if ok and finiteConsoleNumber(x) and finiteConsoleNumber(y) and finiteConsoleNumber(z) then
        return {x = x, y = y, z = z}
    end
end

local function showConsolePage(ply, page, query, state, origin, mode)
    local files = mode == "files"
    -- An in-progress file page has no usable rows. Reuse the catalogue's
    -- identity so any newer catalogue request retires this private reply.
    local listing = files and {rows = {}, expires = 0}
    if listing then consoleListings[ply] = listing end
    local function current(console)
        if not files then return true end
        if consoleListings[ply] ~= listing then return false end
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive()
            or (console and (not IsValid(console) or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply)) then
            -- A partial reply must not leave unseen rows usable. Never retire
            -- a newer catalogue installed by an accessor or feedback callback.
            if consoleListings[ply] == listing then consoleListings[ply] = nil end
            return false
        end
        return consoleListings[ply] == listing
    end
    -- Enumerate every live owned console, including deferred setup and copies
    -- missing from the configuration registry. Sort only our separate array.
    local consoles = {}
    local distances = origin and {}
    local foldedQuery = query and foldConsoleName(query)
    for _, console in ipairs(ents.FindByClass("consoleent")) do
        if IsValid(console) and console:GetClass() == "consoleent" and console.SlicerCreator == ply then
            local matches
            if files then
                local saved = console.SlicerInformation
                -- Validation may trim/case-fold its returned copy. Match the
                -- captured raw fields, not that copy or display-only cleanup.
                local captured = type(saved) == "table" and {name = saved.name, delay = saved.delay,
                    fileName = saved.fileName, fileType = saved.fileType}
                matches = normalizeSlicerInformation(captured) and (foldConsoleName(captured.fileName):find(foldedQuery, 1, true)
                    or foldConsoleName(captured.fileType):find(foldedQuery, 1, true))
                if not current(console) then return end
            else
                local name = query and type(console.SlicerInformation) == "table" and console.SlicerInformation.name or nil
                matches = (not state or matchesConsoleState(console, state)) and (not query or (type(name) == "string"
                    and #name <= 128 and string.Trim(name) ~= "" and foldConsoleName(name):find(foldedQuery, 1, true)))
            end
            if matches then
                consoles[#consoles + 1] = console
                if distances then
                    local position = consolePositionSnapshot(console)
                    if position then
                        local x, y, z = position.x - origin.x, position.y - origin.y, position.z - origin.z
                        local distance = x * x + y * y + z * z
                        if finiteConsoleNumber(distance) then distances[console] = distance end
                    end
                end
            end
        end
    end
    table.sort(consoles, function(first, second)
        if distances then
            local firstDistance, secondDistance = distances[first], distances[second]
            if firstDistance ~= secondDistance then
                if firstDistance == nil then return false end
                if secondDistance == nil then return true end
                return firstDistance < secondDistance
            end
        end
        local firstID, secondID = first:GetCreationID(), second:GetCreationID()
        if firstID == secondID then return first:EntIndex() < second:EntIndex() end
        return firstID < secondID
    end)
    if not current() then return end

    local total = #consoles
    local pages = math.ceil(total / consolesPerPage)
    local messages = {}
    if total == 0 then
        messages[1] = files and "No matching saved filename/folder in valid configurations. Use !listConsoles for all your consoles, including invalid or unset configurations."
            or origin and query and ("No matching console names (" .. state .. ") for '" .. query .. "'. Use !nearConsoles 1 " .. state .. " for all in that state.")
            or query and state and ("No matching console names in state '" .. state .. "'. Use !listConsoles 1 " .. state .. " for all consoles in that state.")
            or query and "No matching console names. Use !listConsoles for all your consoles, including those needing setup."
            or state and ("You have no consoles matching state '" .. state .. "'.")
            or "You have no consoles."
    elseif page > pages then
        messages[1] = files and ("Search page must be between 1 and " .. pages .. ". Use !findConsoleFiles <page> <text>.")
            or origin and query and ("Search page must be between 1 and " .. pages .. ". Use !nearConsoles <page> " .. state .. " " .. query)
            or origin and ("Console page must be between 1 and " .. pages .. ". Use !nearConsoles <page>" .. (state and " " .. state or "") .. ".")
            or query and state and ("Search page must be between 1 and " .. pages .. ". Use !listConsoles <page> " .. state .. " <text>.")
            or query and ("Search page must be between 1 and " .. pages .. ". Use !findConsoles <page> <text>.")
            or ("Console page must be between 1 and " .. pages .. ". Use !listConsoles <page>" .. (state and " " .. state or "") .. ".")
    else
        messages[1] = (files and "Your matching consoles (saved filename/folder; valid configurations): page "
            or origin and ((query and "Your matching consoles" or "Your consoles") .. " (nearest-first request snapshot" .. (state and "; " .. state or "") .. "): page ")
            or query and state and ("Your matching consoles (" .. state .. "): page ")
            or query and "Your matching consoles: page " or state and ("Your consoles (" .. state .. "): page ")
            or "Your consoles: page ") .. page .. " of " .. pages
            .. " (" .. total .. (query and " matches" or " total") .. "). Locate: !locateConsole <row>."
        if files then messages[1] = messages[1] .. " Inspect: !inspectConsole <row>." end
        local first = (page - 1) * consolesPerPage + 1
        local rows = {}
        for i = first, math.min(first + consolesPerPage - 1, total) do
            local console = consoles[i]
            if not current(console) then return end
            rows[#rows + 1] = console
            messages[#messages + 1] = #rows .. ". " .. inspectConsoleLink(console, normalizeSlicerInformation(console.SlicerInformation))
            if not current(console) then return end
        end
        local expires = CurTime() + listingLifetime
        if not current() then return end
        if files then listing.rows, listing.expires = rows, expires
        else consoleListings[ply] = {rows = rows, expires = expires} end
        if page < pages then
            messages[#messages + 1] = files and ("Next page: !findConsoleFiles " .. (page + 1) .. " " .. query)
                or origin and ("Next page: !nearConsoles " .. (page + 1) .. (state and " " .. state or "") .. (query and " " .. query or "."))
                or query and state and ("Next page: !listConsoles " .. (page + 1) .. " " .. state .. " " .. query)
                or query and ("Next page: !findConsoles " .. (page + 1) .. " " .. query)
                or ("Next page: !listConsoles " .. (page + 1) .. (state and " " .. state or "") .. ".")
        elseif page > 1 then
            messages[#messages + 1] = files and ("First page: !findConsoleFiles 1 " .. query)
                or origin and ("First page: !nearConsoles" .. (state and " 1 " .. state or "") .. (query and " " .. query or "."))
                or query and state and ("First page: !listConsoles 1 " .. state .. " " .. query)
                or query and ("First page: !findConsoles 1 " .. query)
                or state and ("First page: !listConsoles 1 " .. state .. ".") or "First page: !listConsoles."
        end
    end
    -- Prepare the complete reply before ChatPrint callbacks can remove or
    -- change an entity. Every row retains inspection's existing byte budget.
    for _, message in ipairs(messages) do
        if not current() then return end
        if files then
            for _, console in ipairs(listing.rows) do if not current(console) then return end end
        end
        ply:ChatPrint(message)
    end
end

hook.Add("PlayerSay", "slicerListConsoles", function(ply, text)
    if text ~= listConsolesCommand and not text:find("^!listConsoles%s") then return end
    if ply ~= nil then consoleListings[ply] = nil end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end

    local page, state, query = 1
    if text ~= listConsolesCommand then
        -- Bound the whole command before extraction or conversion. Optional
        -- state names are exact lowercase words, with one ASCII space per gap.
        -- The longest combined form is 162 bytes, including a 128-byte query.
        local suffix = #text <= 162 and text:sub(#listConsolesCommand + 1) or ""
        local digits = suffix:match("^ ([1-9][0-9]*)$")
        if not digits then digits, state = suffix:match("^ ([1-9][0-9]*) ([a-z]+)$") end
        if not digits then digits, state, query = suffix:match("^ ([1-9][0-9]*) ([a-z]+) (.+)$") end
        if not digits or #digits > 7 or (state and state ~= "setup" and state ~= "unlinked" and state ~= "unconfirmed" and state ~= "linked" and state ~= "reserved") then
            ply:ChatPrint("Usage: !listConsoles, !listConsoles <page>, or !listConsoles <page> <state> (1-7 digits, no leading zero; setup, unlinked, unconfirmed, linked, reserved).")
            return ""
        end
        if query and state == "setup" then
            ply:ChatPrint("Usage: !listConsoles <page> setup. Setup consoles have no saved name to search.")
            return ""
        end
        if query and not validConsoleQuery(query) then
            ply:ChatPrint("Usage: !listConsoles <page> <unlinked|unconfirmed|linked|reserved> <text> (1-7 page digits, no leading zero; 1-128 text bytes, no edge spaces or controls).")
            return ""
        end
        page = tonumber(digits)
    end

    showConsolePage(ply, page, query, state)
    return ""
end)

hook.Add("PlayerSay", "slicerFindConsoles", function(ply, text)
    if text ~= "!findConsoles" and not text:find("^!findConsoles%s") then return end
    if ply ~= nil then consoleListings[ply] = nil end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end

    -- Bound the complete command before extracting, converting or folding.
    -- The explicit page keeps numeric names and the remaining literal text
    -- unambiguous, with no quoting, escaping, wildcard or retained-query state.
    local page, query
    if #text <= 150 then page, query = text:match("^!findConsoles ([1-9][0-9]*) (.+)$") end
    if not page or #page > 7 or not validConsoleQuery(query) then
        ply:ChatPrint("Usage: !findConsoles <page> <text> (1-7 page digits, no leading zero; 1-128 text bytes, no edge spaces or controls).")
        return ""
    end
    showConsolePage(ply, tonumber(page), query)
    return ""
end)

hook.Add("PlayerSay", "slicerFindConsoleFiles", function(ply, text)
    if type(text) ~= "string" or (text ~= "!findConsoleFiles" and not text:find("^!findConsoleFiles%s")) then return end
    if ply ~= nil then consoleListings[ply] = nil end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end

    local page, query
    if #text <= 154 then page, query = text:match("^!findConsoleFiles ([1-9][0-9]*) (.+)$") end
    if not page or #page > 7 or not validConsoleQuery(query) then
        ply:ChatPrint("Usage: !findConsoleFiles <page> <text> (1-7 page digits, no leading zero; 1-128 text bytes, no edge spaces or controls).")
        return ""
    end
    showConsolePage(ply, tonumber(page), query, nil, nil, "files")
    return ""
end)

hook.Add("PlayerSay", "slicerNearConsoles", function(ply, text)
    if text ~= nearConsolesCommand and not text:find("^!nearConsoles%s") then return end
    if ply ~= nil then consoleListings[ply] = nil end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end

    local page, state, query = 1
    if text ~= nearConsolesCommand then
        -- Match list's explicit page/state/literal tail and byte admission.
        -- The longest command is 162 bytes, including a 128-byte query.
        local suffix = #text <= 162 and text:sub(#nearConsolesCommand + 1) or ""
        local digits = suffix:match("^ ([1-9][0-9]*)$")
        if not digits then digits, state = suffix:match("^ ([1-9][0-9]*) ([a-z]+)$") end
        if not digits then digits, state, query = suffix:match("^ ([1-9][0-9]*) ([a-z]+) (.+)$") end
        if not digits or #digits > 7 or (state and state ~= "setup" and state ~= "unlinked" and state ~= "unconfirmed" and state ~= "linked" and state ~= "reserved") then
            ply:ChatPrint("Usage: !nearConsoles, !nearConsoles <page>, or !nearConsoles <page> <state> (1-7 digits, no leading zero; setup, unlinked, unconfirmed, linked, reserved).")
            return ""
        end
        if query and state == "setup" then
            ply:ChatPrint("Usage: !nearConsoles <page> setup. Setup consoles have no saved name to search.")
            return ""
        end
        if query and not validConsoleQuery(query) then
            ply:ChatPrint("Usage: !nearConsoles <page> <unlinked|unconfirmed|linked|reserved> <text> (1-7 page digits, no leading zero; 1-128 text bytes, no edge spaces or controls).")
            return ""
        end
        page = tonumber(digits)
    end
    local origin = consolePositionSnapshot(ply)
    if not origin then
        ply:ChatPrint(query and ("Your position is unavailable. Retry: !nearConsoles " .. page .. " " .. state .. " " .. query)
            or ("Your position is unavailable. Try !nearConsoles" .. (state and " " .. page .. " " .. state or "") .. " again."))
        return ""
    end
    showConsolePage(ply, page, query, state, origin)
    return ""
end)

-- Row numbers belong only to this player's last displayed page. Exact entity
-- references, rather than wrapping IDs or names, retain their identity.
-- Selection is shared by locating and editing; it grants no edit authority.
function slicerListedConsole(ply, row)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then
        if ply ~= nil then consoleListings[ply] = nil end
        return
    end
    if type(row) ~= "number" or row % 1 ~= 0 or row < 1 or row > 5 then return end
    local listing = consoleListings[ply]
    if listing and CurTime() >= listing.expires then consoleListings[ply], listing = nil, nil end
    local console = listing and listing.rows[row]
    if not IsValid(console) or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply then return end
    return console
end

hook.Add("PlayerSay", "slicerInspectConsole", function(ply, text)
    local row = type(text) == "string" and #text == 17 and text:match("^!inspectConsole ([1-5])$")
    if not row then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local console = slicerListedConsole(ply, tonumber(row))
    if not console then
        ply:ChatPrint("That console row is unavailable or expired. Use !listConsoles, !findConsoles or !nearConsoles again, then !inspectConsole <row>.")
        return ""
    end
    local information = console.SlicerInformation
    -- Validate separate captured fields, keeping the original saved spelling.
    -- Inspection grants no ticket and does not require an idle console.
    local saved = type(information) == "table" and {
        name = information.name, delay = information.delay,
        fileType = information.fileType, fileName = information.fileName,
    } or nil
    local label, messages = inspectionLabel(console, saved)
    if information == nil then
        messages = {label .. "needs setup. Use it to configure it."}
    elseif not normalizeSlicerInformation(saved) then
        messages = {label .. "invalid configuration."}
    else
        -- Match the editor's exact round-trip representation of the base delay.
        local delay = tostring(saved.delay)
        if tonumber(delay) ~= saved.delay then delay = string.format("%.17g", saved.delay) end
        messages = {
            label .. "saved configuration:",
            "Folder: " .. saved.fileType .. "; configured base delay: " .. delay .. " seconds.",
            "Saved filename (no extension): '" .. inspectionText(saved.fileName) .. "'.",
        }
    end
    -- Capture all lines before ChatPrint can remove or edit the entity. No
    -- saved-state reads after feedback starts can mix two configurations.
    for _, message in ipairs(messages) do ply:ChatPrint(message) end
    return ""
end)

hook.Add("PlayerSay", "slicerSetupListedConsole", function(ply, text)
    local digits = #text == 15 and text:match("^!setupConsole ([1-5])$")
    if not digits then return end
    local row = tonumber(digits)
    -- Capture the actual page object, so a callback that prints a newer page
    -- cannot authorize this earlier request even when the row is identical.
    local listing = ply ~= nil and consoleListings[ply] or nil
    local console = listing and listing.rows[row] or nil
    local function actorCurrent()
        if not IsValid(ply) or not ply:IsPlayer() or not IsValid(ply) then return false end
        return ply:Alive() and IsValid(ply)
    end
    local function rowCurrent()
        return listing ~= nil and consoleListings[ply] == listing and listing.rows[row] == console
            and CurTime() < listing.expires and consoleListings[ply] == listing
    end
    local function refuse(unavailable)
        if actorCurrent() then
            ply:ChatPrint(unavailable
                and "That console row is unavailable or expired. Use !listConsoles, !findConsoles or !nearConsoles again, then !setupConsole <row>."
                or "That listed console is not eligible for initial setup. It must be your unconfigured, unreserved console with a unique runtime name.")
        end
        return ""
    end
    if not actorCurrent() then return "" end
    if not rowCurrent() or not IsValid(console) or console:GetClass() ~= "consoleent"
        or not IsValid(console) or console.SlicerCreator ~= ply then return refuse(true) end

    -- IDs only check this operation's consistency; the stored reference alone
    -- chooses the entity. Check validity between callback-capable accessors.
    local name = console:GetName()
    if not IsValid(console) then return refuse(true) end
    local creationID = console:GetCreationID()
    if not IsValid(console) then return refuse(true) end
    local entityIndex = console:EntIndex()
    if type(name) ~= "string" or #name == 0 or #name > 256 or name:find("%z") then return refuse(false) end
    local function entityCurrent()
        if not IsValid(console) or console:GetClass() ~= "consoleent" or not IsValid(console)
            or console.SlicerCreator ~= ply or console.SlicerInformation ~= nil then return false end
        local currentName = console:GetName()
        if not IsValid(console) then return false end
        local currentID = console:GetCreationID()
        if not IsValid(console) then return false end
        local currentIndex = console:EntIndex()
        return IsValid(console) and currentName == name and currentID == creationID and currentIndex == entityIndex
            and console.SlicerCreator == ply and console.SlicerInformation == nil
    end
    local function current()
        if not actorCurrent() or not rowCurrent() then return false end
        if type(slicerListedConsole) ~= "function" or slicerListedConsole(ply, row) ~= console
            or not entityCurrent() or slicerConsoleHasActiveSession(console) then return false end
        -- Initial forms and saves use this raw name. Include configured owned
        -- siblings in the ambiguity check; foreign creators have separate forms.
        local matches, candidate = 0, nil
        for _, sibling in ipairs(ents.FindByClass("consoleent")) do
            if IsValid(sibling) and sibling:GetClass() == "consoleent" and IsValid(sibling)
                and sibling.SlicerCreator == ply then
                local siblingName = sibling:GetName()
                if IsValid(sibling) and sibling.SlicerCreator == ply and siblingName == name then
                    matches, candidate = matches + 1, sibling
                end
            end
        end
        -- Scan/accessor callbacks may remove, reconfigure, rename or relist.
        -- Recheck the captured target and lease before any opening is emitted.
        return matches == 1 and candidate == console and entityCurrent() and actorCurrent()
            and IsValid(console) and console.SlicerCreator == ply and console.SlicerInformation == nil
            and not slicerConsoleHasActiveSession(console) and rowCurrent()
    end
    if not current() then return refuse(not rowCurrent() or not IsValid(console) or console.SlicerCreator ~= ply) end
    -- No target-name accessor runs after the final guard inside openSetup.
    if not openSetup(ply, console, {name = name, current = current}) then return refuse(not rowCurrent()) end
    return ""
end)

hook.Add("PlayerSay", "slicerLocateConsole", function(ply, text)
    if text ~= "!locateConsole" and not text:find("^!locateConsole%s") then return end
    if text == "!locateConsole pending" then
        -- Keep this exact-pointer path independent of catalogue lease cleanup.
        -- Native accessor/reply failures still consume recognized private chat.
        pcall(function()
            if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
            local console = ply.SlicerPendingConsole
            local live = console ~= nil and IsValid(console)
            local creator, class
            if live then
                creator = console.SlicerCreator
                class = console:GetClass()
            end
            local message = "You have no pending door-link selection."
            local label, position
            if console ~= nil then
                message = "Your pending door-link selection is unavailable. Use !cancelLink, or !setEntity on an eligible console to select again."
                if live and class == "consoleent" and creator == ply then
                    local information = console.SlicerInformation
                    local name = type(information) == "table" and information.name
                    label = "Console"
                    if type(name) == "string" and #name <= 128 and string.Trim(name) ~= "" then
                        label = label .. " '" .. inspectionText(name) .. "'"
                    end
                    local getID = console.GetCreationID
                    local id = type(getID) == "function" and getID(console)
                    if type(id) == "number" and id >= 0 and id <= 10000000 and id == math.floor(id) then
                        label = label .. " (current ID #" .. string.format("%.0f", id) .. ")"
                    end
                    local center = console:WorldSpaceCenter()
                    local x, y, z
                    if center ~= nil then x, y, z = center.x, center.y, center.z end
                    local function finite(value)
                        return type(value) == "number" and value == value and value > -math.huge and value < math.huge
                    end
                    if finite(x) and finite(y) and finite(z) and #label <= 240 then
                        position = Vector(x, y, z)
                        message = nil
                    else
                        message = "Your pending console's position is unavailable. Try !locateConsole pending again later."
                    end
                end
            end
            -- Finish all display/accessor reads before the final identity guard.
            -- Never restore a selection changed synchronously by an accessor.
            local feedback = message and ply.ChatPrint
            if (console ~= nil and IsValid(console)) ~= live then return end
            if live and (console:GetClass() ~= class or console.SlicerCreator ~= creator or not IsValid(console)) then return end
            if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
            if ply.SlicerPendingConsole ~= console then return end
            if message then feedback(ply, message); return end
            net.Start("SlicerConsoleLocation")
                net.WriteBool(true)
                net.WriteString(label)
                net.WriteVector(position)
            net.Send(ply)
        end)
        return ""
    end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then
        if ply ~= nil then consoleListings[ply] = nil end
        return ""
    end
    if text == "!locateConsole clear" then
        net.Start("SlicerConsoleLocation")
            net.WriteBool(false)
        net.Send(ply)
        return ""
    end
    local row = #text == 16 and text:match("^!locateConsole ([1-5])$")
    if not row then
        ply:ChatPrint("Usage: !locateConsole <row> (1-5 from your last catalogue page), !locateConsole pending, or !locateConsole clear.")
        return ""
    end
    local console = slicerListedConsole(ply, tonumber(row))
    if not console then
        ply:ChatPrint("That console row is unavailable or expired. Use !listConsoles or !findConsoles again, then !locateConsole <row>.")
        return ""
    end
    net.Start("SlicerConsoleLocation")
        net.WriteBool(true)
        net.WriteString(inspectionLabel(console):sub(1, -3))
        net.WriteVector(console:WorldSpaceCenter())
    net.Send(ply)
    return ""
end)

local nextListingCleanup = 0
hook.Add("Think", "slicerExpireConsoleListings", function()
    local now = CurTime()
    if now < nextListingCleanup then return end
    nextListingCleanup = now + 5
    for ply, listing in pairs(consoleListings) do
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() or now >= listing.expires then
            consoleListings[ply] = nil
        end
    end
end)

hook.Add("PlayerUse", "isUsingOurObject", function(ply, ent)
    if IsValid(linkedDoors[ent]) then
        net.Start("PlayerAlert")
        net.Send(ply)
        return false
    end
    -- Return nil for unrelated entities so other addons can handle the hook.
end)

local function canComplete(ply, console, isDoor)
    local session = sessions[ply]
    if not session or session.console ~= console or not IsValid(console) then return false end
    if console:GetCreationID() ~= session.consoleCreationID or console:EntIndex() ~= session.consoleIndex
        or not IsValid(ply) or ply:GetCreationID() ~= session.playerCreationID or ply:EntIndex() ~= session.playerIndex then
        releaseSession(ply, true)
        return false
    end
    local information = console.SlicerInformation
    local validType = information and (isDoor
        and information.fileType == "tools" and IsValid(console.SlicerDoor)
        or not isDoor and (information.fileType == "data" or information.fileType == "server"))
    if not hasHackingTool(ply) or CurTime() < session.completeAt or not validType then
        -- The client has closed its completed countdown. Do not strand this
        -- authenticated session if a tool or other requirement changed.
        releaseSession(ply, true)
        ply:ChatPrint("Hacking was not completed. Equip the hacking tool and use the console again to retry.")
        return false
    end
    return true
end

local function finishConsole(ply, console)
    local saved = console.SlicerInformation
    local information = {name = saved.name, fileName = saved.fileName, fileType = saved.fileType}
    local intel, failure = slicerIntel.Award(ply, console, information)
    if failure then
        releaseSession(ply, true)
        ply:ChatPrint(failure)
        return
    end
    releaseSession(ply, false)
    console:Remove() -- OnRemove unlocks only this console's linked door.
    net.Start("SlicerCompleted")
        net.WriteString(information.name)
        net.WriteString(information.fileName)
        net.WriteString(information.fileType)
        net.WriteString(ply:GetName())
    net.Send(ply)
    if intel then slicerIntel.Send(ply, intel, false) end
end

net.Receive("PlayerActivatedDoor", function(_, ply)
    local console = net.ReadEntity()
    if not canComplete(ply, console, true) then return end
    finishConsole(ply, console)
end)

net.Receive("destroyOnServer", function(_, ply)
    local console = net.ReadEntity()
    if not canComplete(ply, console, false) then return end
    finishConsole(ply, console)
end)

function ENT:OnRemove()
    slicerIntel.ClearBody(self)
    retireSlicerInitialSetup(self)
    retireSlicerSetupEdit(self)
    for ply, session in pairs(sessions) do
        if session.console == self then releaseSession(ply, true) end
    end
    if IsValid(self.SlicerDoor) and linkedDoors[self.SlicerDoor] == self then
        linkedDoors[self.SlicerDoor] = nil
        self.SlicerDoor:Fire("Unlock")
    end
    if IsValid(self.SlicerCreator) and self.SlicerCreator.SlicerPendingConsole == self then
        self.SlicerCreator.SlicerPendingConsole = nil
    end
    for i = #spawnedEntities, 1, -1 do
        if spawnedEntities[i].entity == self then table.remove(spawnedEntities, i) end
    end
end

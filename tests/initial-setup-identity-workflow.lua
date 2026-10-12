-- Real callbacks and Remove/Spawn/SetName reproduce supported external name reuse.
-- Ordinary Remove/Spawn is a passing control; native creation-ID wrap is not reproduced.
return function(gmod, test, equal)
    -- Verbatim guard/reply/receiver and token validator from sv_config.lua at
    -- 8dc78c3a8ff8e0be9c4dea81ede7814e05e2637a. Only the private receipt map is
    -- supplied as a dependency; normalization and native APIs use the host.
    -- Raw bytes between fixture delimiters SHA-256: d247ae4bc856fd72c3fd0e48890cf6169d542325b8feea6b18246c00cd4f5f46
    local frozenOldHandler = [====[
local function validInitialSetupToken(token)
    return type(token) == "string" and #token <= 16 and token:match("^[1-9]%d*$") ~= nil
        and (#token < 16 or token <= "9007199254740991")
end

local initialSetupReceipts = {}
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
    -- Commit the receipt before any response can reenter. Identity length only
    -- limits recovery storage, never changes the original setup admission.
    if token ~= nil then
        initialSetupReceipts[target] = nil
        if #entityName <= 256 then
            initialSetupReceipts[target] = {player = ply, creationID = target:GetCreationID(), entityIndex = target:EntIndex(),
                token = token, fields = {name, delay, fileType, fileName, entityName},
                name = information.name, fileType = information.fileType}
        end
    end
    initialSetupReply(ply, token, {ok = true, name = information.name, fileType = information.fileType})
end)

]====]
    local unpackValues = table.unpack or unpack
    local function deliver(to, packet, sender) to.receive(packet.name, sender, unpackValues(packet.values)) end
    local function form(client, packet)
        local first, result, entries = #client.panels + 1, {}, {}
        deliver(client, packet)
        for i = first, #client.panels do
            local p = client.panels[i]
            if p.class == "DFrame" then result.frame = p
            elseif p.class == "DTextEntry" then entries[#entries + 1] = p
            elseif p.class == "DComboBox" then result.folder = p
            elseif p.class == "DLabel" then result.status = p
            elseif p.text == "Done" then result.done = p
            elseif p.text == "Set up later" then result.close = p end
        end
        result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        return result
    end
    local function fill(f, folder)
        f.name:SetText("  Original draft  "); f.delay:SetText("2.5")
        f.file:SetText("  Raw file  "); f.folder.selected = folder or "tools"
    end
    local function fixture(listed)
        local s, c = gmod.new(), gmod.client(); local p = s.player(); local a = s.console(p)
        if listed then s.fire("PlayerSay", p, "!listConsoles"); s.fire("PlayerSay", p, "!setupConsole 1") end
        return s, c, p, a, form(c, s.lastMessage("PlayerSpawnedConsole"))
    end
    for _, reuse in ipairs({false, true}) do
        test("identity stale listed draft after Remove/Spawn" .. (reuse and "/SetName" or " control"), function()
            local s, c, p, a, f = fixture(true); fill(f)
            local oldName = a:GetName(); a:Remove(); local b = s.console(p)
            if reuse then b:SetName(oldName) else assert(b:GetName() ~= oldName) end
            local choice = s.console(p); s.configure(p, choice, "tools"); p.SlicerPendingConsole = choice
            f.done:DoClick(); local packet = c.lastMessage("AdminFinishedCreation"); deliver(s, packet, p)
            equal(b.SlicerInformation, nil, "A's old draft must never configure replacement B")
            equal(p.SlicerPendingConsole, choice); equal(s.lastMessage("SlicerInitialSetupReply").values[2].ok, false)
            s.receive("SlicerInitialSetupStatusRequest", p, packet.values[1])
            equal(s.lastMessage("SlicerInitialSetupStatusReply").values[2].confirmed, false)
        end)
    end
    test("identity using replacement with reused name opens a separate blank form", function()
        local s, c, p, a, f = fixture(true); fill(f); local name = a:GetName()
        a:Remove(); local b = s.console(p); b:SetName(name); s.open(p, b)
        local fresh = form(c, s.lastMessage("PlayerSpawnedConsole"))
        assert(fresh.frame, "Replacement must not raise the old form")
        equal(fresh.name:GetValue(), ""); equal(f.name:GetValue(), "  Original draft  "); equal(f.frame.valid, true)
        fill(fresh, "data"); fresh.done:DoClick(); deliver(s, c.lastMessage("AdminFinishedCreation"), p)
        equal(b.SlicerInformation.fileType, "data"); equal(a.SlicerInformation, nil)
    end)
    test("identity removed accepted receipt never migrates to replacement", function()
        local s, c, p, a, f = fixture(); fill(f); f.done:DoClick()
        local packet = c.lastMessage("AdminFinishedCreation"); deliver(s, packet, p)
        local name = a:GetName(); a:Remove(); local b = s.console(p); b:SetName(name)
        s.receive("SlicerInitialSetupStatusRequest", p, packet.values[1])
        equal(s.lastMessage("SlicerInitialSetupStatusReply").values[2].confirmed, false); equal(b.SlicerInformation, nil)
    end)
    for _, folder in ipairs({"data", "server", "tools"}) do
        test("identity " .. folder .. " dropped acceptance confirms frozen draft after edit and list expiry", function()
            local s, c, p, a, f = fixture(true); fill(f, folder); s.now = 61
            f.done:DoClick(); local packet = c.lastMessage("AdminFinishedCreation"); deliver(s, packet, p)
            local reply = s.lastMessage("SlicerInitialSetupReply"); equal(reply.values[2].ok, true)
            equal(type(packet.values[1][5]), "table"); equal(reply.values[2].targetToken, packet.values[1][5].targetToken)
            p.target = a; s.fire("PlayerSay", p, "!editConsole")
            local edit = s.lastMessage("SlicerSetupEditOpen")
            s.receive("SlicerSetupEditSave", p, a, edit.values[3], {name="Later edit",delay=7,fileName="Later"})
            local later = s.console(p); s.configure(p, later, "tools"); p.SlicerPendingConsole = later
            f.done:DoClick(); local query = c.lastMessage("SlicerInitialSetupStatusRequest"); deliver(s, query, p)
            local status = s.lastMessage("SlicerInitialSetupStatusReply"); equal(status.values[2].confirmed, true)
            equal(status.values[2].name, "original draft"); equal(a.SlicerInformation.name, "later edit")
            equal(p.SlicerPendingConsole, later); deliver(c, status); equal(f.frame.valid, false)
        end)
    end
    test("identity actual frozen old handler rejects modern form without fallback mutation",function()
        local s,c,p,a,f=fixture(); fill(f)
        local chunk
        if _VERSION=="Lua 5.1" then chunk=assert(loadstring(frozenOldHandler)); setfenv(chunk,s)
        else chunk=assert(load(frozenOldHandler,"@baseline-8dc78c3-initial-handler","t",s)) end
        chunk(); f.done:DoClick(); local packet=c.lastMessage("AdminFinishedCreation")
        equal(type(packet.values[1][5]),"table"); deliver(s,packet,p)
        local rejected=s.lastMessage("SlicerInitialSetupReply"); equal(rejected.values[2].ok,false)
        equal(rejected.values[2].targetToken,nil); equal(a.SlicerInformation,nil)
        equal(#s.returnSpawnedEntities(),0); equal(p.SlicerPendingConsole,nil)
        deliver(c,rejected); equal(f.name.editable,false); equal(f.frame.valid,true)
        local saves=0; for _,m in ipairs(c.messages) do if m.name=="AdminFinishedCreation" then saves=saves+1 end end
        equal(saves,1,"An unbound rejection must never trigger a legacy fallback")
        local legacy={"Legacy",2,"data","File",a:GetName(),"2"}; s.receive("AdminFinishedCreation",p,legacy)
        equal(s.lastMessage("SlicerInitialSetupReply").values[2].ok,true); equal(a.SlicerInformation.name,"legacy")
    end)
    test("identity an old two-field receiver reads the unchanged prefix from a new server",function()
        local s,c,p,a=fixture(); local observedPlayer,observedName
        c.net.Receive("PlayerSpawnedConsole",function() observedPlayer=c.net.ReadEntity(); observedName=c.net.ReadString() end)
        s.open(p,a); local packet=s.lastMessage("PlayerSpawnedConsole"); equal(#packet.values,3)
        deliver(c,packet); equal(observedPlayer,p); equal(observedName,a:GetName())
        -- This array-host check cannot establish native unread-suffix tolerance.
    end)

    test("identity simulated numeric ID reuse cannot transfer modern target authority",function()
        -- API-double model only. This deliberately reuses both numeric getters;
        -- no native ID exhaustion, wrap timing or entity-index reuse is claimed.
        local s,c,p,a,f=fixture(true); fill(f)
        local name,id,index=a:GetName(),a:GetCreationID(),a:EntIndex(); a:Remove()
        local b=s.console(p); b.id=id; b.EntIndex=function() return index end; b:SetName(name)
        s.open(p,b); local fresh=form(c,s.lastMessage("PlayerSpawnedConsole"))
        assert(fresh.frame); equal(fresh.name:GetValue(),"")
        f.done:DoClick(); local stale=c.lastMessage("AdminFinishedCreation"); deliver(s,stale,p)
        equal(s.lastMessage("SlicerInitialSetupReply").values[2].ok,false); equal(b.SlicerInformation,nil)
        fill(fresh,"data"); fresh.done:DoClick(); local current=c.lastMessage("AdminFinishedCreation")
        assert(current.values[1][5].targetToken~=stale.values[1][5].targetToken)
        deliver(s,current,p); equal(b.SlicerInformation.fileType,"data")
    end)

end

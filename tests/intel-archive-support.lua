-- Archive-only host seams. These encode application bytes, not native GMod
-- framing; all product handlers/panel callbacks are the included addon source.
return function(gmod, equal)
    local H = {requestName = "SlicerIntelArchiveRequest", replyName = "SlicerIntelArchiveReply"}
    local unpackValues = table.unpack or unpack
    function H.z(value) return value .. "\0" end
    function H.request(op, token, award)
        return string.char(op) .. H.z(token) .. H.z(award or "")
    end
    function H.entry(award, name, file, folder, body)
        return {award = award, consoleName = name or "terminal", fileName = file or "secret",
            fileType = folder or "data", body = body or "Literal clue"}
    end
    function H.recordBytes(record, body)
        local bytes = H.z(record.award) .. H.z(record.consoleName) .. H.z(record.fileName)
            .. string.char(record.fileType == "data" and 0 or 1)
        return bytes .. (body and H.z(record.body) or "")
    end
    function H.reply(op, token, status, data)
        local bytes = string.char(op) .. H.z(token) .. string.char(status)
        if status ~= 0 then return bytes end
        if op == 1 then
            bytes = bytes .. string.char(#data)
            for _, record in ipairs(data) do bytes = bytes .. H.recordBytes(record, false) end
            return bytes
        end
        return bytes .. H.recordBytes(data, true)
    end
    -- Independent fixture decoder: proves the actual bytes sent and exact EOF.
    function H.decode(bytes, request)
        local cursor = 1
        local function byte()
            assert(cursor <= #bytes, "Missing wire byte")
            local value = bytes:byte(cursor); cursor = cursor + 1; return value
        end
        local function str()
            local stop = assert(bytes:find("\0", cursor, true), "Missing wire terminator")
            local value = bytes:sub(cursor, stop - 1); cursor = stop + 1; return value
        end
        local result = {op = byte(), token = str()}
        if request then result.award = str()
        else
            result.status = byte()
            if result.status == 0 then
                local function record(body)
                    local row = {award = str(), consoleName = str(), fileName = str(), folder = byte()}
                    if body then row.body = str() end
                    return row
                end
                if result.op == 1 then
                    result.count, result.entries = byte(), {}
                    for i = 1, result.count do result.entries[i] = record(false) end
                elseif result.op == 2 then result.record = record(true)
                else error("Unexpected reply operation") end
            end
        end
        equal(cursor, #bytes + 1, "Wire schema consumes every actual byte")
        return result
    end
    function H.packets(env, name, first)
        local found = {}
        for i = first or 1, #env.messages do
            if env.messages[i].name == name then found[#found + 1] = env.messages[i] end
        end
        return found
    end
    function H.wire(env)
        local start, writeString, send = env.net.Start, env.net.WriteString, env.net.Send
        env.archiveStarts, env.archiveReads, env.archiveReadBytes = 0, 0, 0
        env.archivePooled = true
        env.util.NetworkStringToID = function(name)
            return name == H.requestName and env.archivePooled and 1 or 0
        end
        function env.net.Start(name)
            if name == H.requestName or name == H.replyName then
                env.archiveStarts = env.archiveStarts + 1
                if env.archiveFail == "start" then error("modeled Start failure") end
            end
            start(name)
            if name == H.requestName or name == H.replyName then env.outgoing.bytes = "" end
        end
        function env.net.WriteUInt(value, width)
            equal(width, 8, "Archive UInt fields use exactly eight bits")
            assert(value >= 0 and value <= 255 and value % 1 == 0)
            if env.archiveFail == "write" then error("modeled write failure") end
            assert(env.outgoing.bytes, "UInt8 outside archive")
            env.outgoing.bytes = env.outgoing.bytes .. string.char(value)
            table.insert(env.outgoing.values, value)
        end
        function env.net.WriteString(value)
            if env.outgoing.bytes then
                if env.archiveFail == "write" then error("modeled write failure") end
                -- net.WriteString is NUL terminated: embedded NUL ends a field.
                local stop = value:find("\0", 1, true)
                env.outgoing.bytes = env.outgoing.bytes .. H.z(stop and value:sub(1, stop - 1) or value)
            end
            writeString(value)
        end
        function env.net.Send(player)
            if env.outgoing.bytes and env.archiveFail == "send" then error("modeled send failure") end
            send(player)
        end
        function env.net.SendToServer() env.net.Send("server") end
        function env.net.ReadData(count)
            env.archiveReads = env.archiveReads + 1
            env.archiveReadBytes = env.archiveReadBytes + count
            assert(type(count) == "number" and count >= 0 and count % 1 == 0)
            local bytes = assert(env.archiveIncoming, "Raw archive receive required")
            local result = bytes:sub(env.archiveCursor, env.archiveCursor + count - 1)
            env.archiveCursor = env.archiveCursor + count
            if env.archiveReadTransform then return env.archiveReadTransform(result) end
            return result
        end
        function env.receiveBytes(name, sender, bytes, bits)
            env.archiveIncoming, env.archiveCursor = bytes, 1
            assert(env.receivers[name], "Missing receiver: " .. name)(bits or #bytes * 8, sender)
            env.archiveIncoming = nil
        end
        return env
    end
    function H.server() return H.wire(gmod.new()) end
    function H.client()
        local env = H.wire(gmod.client())
        env.ScrW, env.ScrH = function() return 640 end, function() return 480 end
        env.archiveClock, env.archiveTimers, env.archiveTimerID = 0, {}, 0
        local function schedule(delay, callback)
            env.archiveTimerID = env.archiveTimerID + 1
            env.archiveTimers[#env.archiveTimers + 1] = {due = env.archiveClock + delay, callback = callback}
        end
        env.timer.Simple = schedule
        function env.advanceArchive(seconds)
            env.archiveClock = env.archiveClock + seconds
            local ready, waiting = {}, {}
            for _, timer in ipairs(env.archiveTimers) do
                if timer.due <= env.archiveClock then ready[#ready + 1] = timer
                else waiting[#waiting + 1] = timer end
            end
            env.archiveTimers = waiting
            for _, timer in ipairs(ready) do timer.callback() end
        end
        local create = env.vgui.Create
        function env.vgui.Create(class, parent)
            if env.archivePanelFail == class then error("modeled panel creation failure") end
            local panel = create(class, parent)
            function panel:SetPos(x, y) self.x, self.y = x, y end
            function panel:SetSize(width, height) self.width, self.height = width, height end
            if class == "DComboBox" then
                panel.choices, panel.sortItems = {}, true
                function panel:SetSortItems(value) self.sortItems = value end
                function panel:SetValue(value) self.text = value end
                function panel:Clear() self.choices, self.selected, self.selectedID = {}, nil, nil; self.text = "" end
                function panel:AddChoice(label, data, select)
                    self.choices[#self.choices + 1] = {label = label, data = data}
                    if self.sortItems then table.sort(self.choices, function(a, b) return a.label < b.label end) end
                    if select then self:ChooseOptionID(#self.choices) end
                    return #self.choices
                end
                function panel:GetOptionData(index) return self.choices[index] and self.choices[index].data end
                function panel:GetSelectedID() return self.selectedID end
                function panel:ChooseOptionID(index)
                    local choice = assert(self.choices[index], "Missing choice")
                    self.selected, self.selectedID, self.text = choice.label, index, choice.label
                    if self.OnSelect then self:OnSelect(index, choice.label, choice.data) end
                end
            end
            return panel
        end
        return env
    end
    function H.fixture()
        local env = H.server()
        return env, env.player(), env.player(), env.player()
    end
    function H.add(env, owner, body, folder, name, file)
        local console = env.console(owner)
        local info = assert(env.configure(owner, console, folder or "data"))
        if name then info.name = name end
        if file then info.fileName = file end
        if body then assert(env.slicerIntel.SetBody(console, body)) end
        return console
    end
    function H.finish(env, player, console, operation)
        local before = #env.messages
        env.open(player, console)
        env.now = env.now + console.SlicerInformation.delay * (operation == "PlayerActivatedDoor" and 1 or 2)
        env.receive(operation or "destroyOnServer", player, console)
        return H.packets(env, "SlicerIntel", before + 1)[1]
    end
    function H.award(env, owner, player, body, folder, name, file)
        local console = H.add(env, owner, body or "Literal clue", folder, name, file)
        local packet = assert(H.finish(env, player, console), "Genuine completion did not award")
        equal(console.removed, true)
        return packet, console
    end
    function H.ask(env, player, operation, award, advance)
        if advance ~= false then env.now = env.now + 1 end
        env.archiveRequestSerial = (env.archiveRequestSerial or 0) + 1
        local token = tostring(env.archiveRequestSerial)
        local before = #env.messages
        env.receiveBytes(H.requestName, player, H.request(operation, token, award))
        local packets = H.packets(env, H.replyName, before + 1)
        assert(#packets <= 1, "One request cannot send a batch")
        local packet = packets[1]
        if packet then
            equal(packet.player, player, "Reply is private to authenticated sender")
            return H.decode(packet.bytes), packet
        end
    end
    function H.deliver(client, packet)
        if packet.bytes then client.receiveBytes(packet.name, nil, packet.bytes)
        else client.receive(packet.name, nil, unpackValues(packet.values)) end
    end
    function H.latest(env, award, body)
        env.receive("SlicerIntel", nil, award or "1", "terminal", "secret", "data", body or "Latest clue", false)
    end
    function H.frames(env, title)
        local found = {}
        for _, panel in ipairs(env.panels) do
            if panel.class == "DFrame" and panel.valid and panel:IsVisible() and not panel:IsMarkedForDeletion()
                and (not title or panel.title == title) then found[#found + 1] = panel end
        end
        return found
    end
    function H.savedButton(env)
        for i = #env.panels, 1, -1 do
            local panel = env.panels[i]
            if panel.class == "DButton" and panel.text == "Saved intel" and panel.valid
                and panel.parent.valid and panel.parent:IsVisible() and not panel.parent:IsMarkedForDeletion() then return panel end
        end
        error("Missing live latest-reader Saved intel control")
    end
    function H.archive(env)
        local frames = H.frames(env, "Saved mission intel"); equal(#frames, 1)
        local view = {frame = frames[1]}
        local entries, labels = {}, {}
        for _, child in ipairs(view.frame.children) do
            if child.class == "DComboBox" then view.selector = child
            elseif child.class == "DButton" and child.text == "Refresh" then view.refresh = child
            elseif child.class == "DTextEntry" then entries[#entries + 1] = child
            elseif child.class == "DLabel" then labels[#labels + 1] = child end
        end
        view.metadata, view.body, view.status, view.footer = entries[1], entries[2], labels[1], labels[2]
        assert(view.selector and view.refresh and view.metadata and view.body and view.status and view.footer)
        return view
    end
    function H.open(client)
        H.savedButton(client):DoClick()
        return H.archive(client), H.lastRequest(client)
    end
    function H.lastRequest(client)
        local packet = assert(client.lastMessage(H.requestName), "Missing archive request")
        local request = H.decode(packet.bytes, true); request.packet = packet
        equal(#packet.bytes <= 35, true)
        return request
    end
    function H.list(client, request, entries)
        client.receiveBytes(H.replyName, nil, H.reply(1, request.token, 0, entries))
    end
    function H.body(client, request, record)
        client.receiveBytes(H.replyName, nil, H.reply(2, request.token, 0, record))
    end
    function H.roundtrip(server, player, client, request, advance)
        if advance ~= false then server.now = server.now + 1 end
        local before = #server.messages
        server.receiveBytes(H.requestName, player, request.packet.bytes)
        local packets = H.packets(server, H.replyName, before + 1)
        equal(#packets, 1); equal(packets[1].player, player)
        H.deliver(client, packets[1])
        return H.decode(packets[1].bytes), packets[1]
    end
    function H.setAwardSerial(env, value)
        for i = 1, 40 do
            local name = debug.getupvalue(env.slicerIntel.Award, i)
            if not name then break end
            if name == "awardSerial" then
                equal(debug.setupvalue(env.slicerIntel.Award, i, value), "awardSerial"); return
            end
        end
        error("Missing existing serial boundary seam")
    end
    return H
end

-- Ten registered controller cases. Codec, panel and timer seams are isolated.
return function(gmod, test, equal)
    local H = dofile("tests/intel-archive-support.lua")(gmod, equal)
    local function fixture()
        local client = H.client(); H.latest(client)
        return client
    end
    local function requests(client) return #H.packets(client, H.requestName) end
    local function contains(text, part) assert(text:find(part, 1, true), "Missing guidance: " .. part) end
    local function loaded(client, entries)
        local view, request = H.open(client)
        H.list(client, request, entries)
        return view
    end

    test("C1 Saved intel opens one archive and refocuses it without refetch or selection loss", function()
        local client = fixture(); equal(requests(client), 0)
        local latest = H.savedButton(client)
        local view, request = H.open(client)
        equal(request.op, 1); equal(request.award, ""); equal(requests(client), 1)
        equal(view.status.text, "Loading saved intel..."); equal(view.body.text, "")
        local entry = H.entry("1")
        H.list(client, request, {entry}); view.selector:ChooseOptionID(1)
        H.body(client, H.lastRequest(client), entry)
        local sent, panels, popups = requests(client), #client.panels, view.frame.popupCalls
        latest:DoClick()
        equal(requests(client), sent); equal(#client.panels, panels); equal(H.archive(client).frame, view.frame)
        equal(view.frame.popupCalls, popups + 1); equal(view.selector:GetOptionData(view.selector:GetSelectedID()), "1")
        equal(view.body.text, entry.body)
        latest.parent:Close(); equal(H.archive(client).frame, view.frame)
        view.frame:Close(); local before = #client.panels
        latest:DoClick(); equal(#client.panels, before, "A closed reader callback cannot open an archive")
        H.latest(client, "2", "New latest")
        latest:DoClick(); equal(#H.frames(client, "Saved mission intel"), 0, "A replaced reader callback remains inert")
        H.open(client); equal(requests(client), sent + 1)
    end)

    test("C2 metadata choices preserve newest-first numeric award order exact data and safe duplicate labels", function()
        local client = fixture()
        local entries = {H.entry("11", "[name unavailable]", "[name unavailable]"),
            H.entry("10", "[name unavailable]", "[name unavailable]"), H.entry("9", "café 日本語", "café 日本語", "server")}
        local view = loaded(client, entries)
        equal(view.selector.sortItems, false); equal(#view.selector.choices, 3)
        for i, entry in ipairs(entries) do
            equal(view.selector:GetOptionData(i), entry.award)
            contains(view.selector.choices[i].label, "#" .. entry.award .. " — ")
            contains(view.selector.choices[i].label, entry.consoleName)
            contains(view.selector.choices[i].label, entry.fileName .. (entry.fileType == "data" and ".data" or ".sys"))
        end
        equal(view.body.text, ""); equal(view.metadata.text, ""); equal(requests(client), 1)
        equal(view.status.text, "Select a saved clue to read it."); contains(view.footer.text, "Saved 3/10")
        equal(view.metadata.editable, false); equal(view.body.editable, false)
        equal(view.metadata.multiline, true); equal(view.body.multiline, true)
        view.selector:ChooseOptionID(3)
        equal(H.lastRequest(client).award, "9"); contains(view.metadata.text, "café 日本語")
    end)

    test("C3 body replies require matching operation token award and projected metadata before literal display", function()
        local client = fixture()
        local a = H.entry("2", "[name unavailable]", "[name unavailable]", "server", "<b>https://example.invalid</b>\n/run[no] café\tclue")
        local b = H.entry("1", "[name unavailable]", "[name unavailable]", "server", "Other immutable body")
        local view = loaded(client, {a, b}); view.selector:ChooseOptionID(1)
        local request, count = H.lastRequest(client), requests(client)
        client.receiveBytes(H.replyName, nil, H.reply(1, request.token, 0, {a}))
        H.body(client, {token = "999"}, a); equal(view.body.text, ""); equal(view.status.text, "Loading clue...")
        H.body(client, request, b); equal(view.body.text, ""); contains(view.status.text, "could not be displayed")
        view.selector:ChooseOptionID(1); request = H.lastRequest(client)
        local wrong = H.entry(a.award, "different", a.fileName, a.fileType, a.body)
        H.body(client, request, wrong); equal(view.body.text, "")
        view.selector:ChooseOptionID(1); request = H.lastRequest(client)
        wrong = H.entry(a.award, a.consoleName, "different", a.fileType, a.body)
        H.body(client, request, wrong); equal(view.body.text, "")
        view.selector:ChooseOptionID(1); request = H.lastRequest(client)
        wrong = H.entry(a.award, a.consoleName, a.fileName, "data", a.body)
        H.body(client, request, wrong); equal(view.body.text, "")
        view.selector:ChooseOptionID(1); request = H.lastRequest(client)
        H.body(client, request, a); equal(view.body.text, a.body); equal(view.body.OnEnter, nil)
        equal(#client.chatMessages, 0); equal(requests(client), count + 4)
        view.selector:ChooseOptionID(2); equal(view.body.text, "")
        H.body(client, H.lastRequest(client), b); equal(view.body.text, b.body)
    end)

    test("C4 selecting A then B accepts only B in either response order without reply focus", function()
        local client = fixture(); local a, b = H.entry("2", "A", "a", "data", "A body"), H.entry("1", "B", "b", "data", "B body")
        local view = loaded(client, {a, b})
        for _, bFirst in ipairs({false, true}) do
            if bFirst then view.refresh:DoClick(); H.list(client, H.lastRequest(client), {a, b}) end
            view.selector:ChooseOptionID(1); local pendingA = H.lastRequest(client)
            local count = requests(client); view.selector:ChooseOptionID(1); equal(requests(client), count)
            view.selector:ChooseOptionID(2); local pendingB = H.lastRequest(client)
            count = requests(client); view.selector:ChooseOptionID(2); equal(requests(client), count)
            local focus, popup = #client.focusCalls, view.frame.popupCalls
            if bFirst then H.body(client, pendingB, b); H.body(client, pendingA, a)
            else H.body(client, pendingA, a); equal(view.body.text, ""); H.body(client, pendingB, b) end
            equal(view.body.text, "B body"); equal(#client.focusCalls, focus); equal(view.frame.popupCalls, popup)
            view.selector:ChooseOptionID(2); equal(requests(client), count, "Displayed current choice sends nothing")
            H.body(client, pendingB, b); equal(view.body.text, "B body"); equal(view.frame.popupCalls, popup)
        end
    end)

    test("C5 Refresh supersedes pending list and read and only its newest snapshot can commit", function()
        local client = fixture(); local a, b = H.entry("1"), H.entry("2", "New", "new")
        local view, first = H.open(client)
        view.refresh:DoClick(); local second = H.lastRequest(client)
        H.list(client, first, {a}); equal(#view.selector.choices, 0)
        H.list(client, second, {a}); view.selector:ChooseOptionID(1); local oldBody = H.lastRequest(client)
        view.refresh:DoClick(); local newest = H.lastRequest(client)
        equal(view.body.text, ""); equal(view.metadata.text, ""); equal(#view.selector.choices, 0)
        H.list(client, newest, {b}); H.body(client, oldBody, a); H.list(client, second, {a})
        equal(#view.selector.choices, 1); equal(view.selector:GetOptionData(1), "2")
        equal(view.body.text, ""); equal(view.metadata.text, ""); equal(requests(client), 4)
        view.selector:ChooseOptionID(1); H.body(client, H.lastRequest(client), b); equal(view.body.text, b.body)
    end)

    test("C6 deferred close and reopen isolate tokens frames late replies and stale cleanup", function()
        local client = fixture(); local entry = H.entry("1")
        local old, oldRequest = H.open(client)
        client.deferPanelRemoval = true; old.frame:Close()
        local current, newRequest = H.open(client)
        assert(current.frame ~= old.frame); assert(tonumber(newRequest.token) > tonumber(oldRequest.token))
        equal(old.frame.valid, true, "Deferred native removal interval is exercised")
        H.list(client, oldRequest, {entry}); equal(#current.selector.choices, 0)
        old.frame:OnClose(); old.frame:OnRemove()
        H.list(client, newRequest, {entry}); equal(H.archive(client).frame, current.frame)
        current.selector:ChooseOptionID(1); local pending = H.lastRequest(client)
        current.frame:Remove(); local nextView, nextRequest = H.open(client)
        H.body(client, pending, entry); equal(nextView.body.text, "")
        current.frame:OnRemove(); H.list(client, nextRequest, {entry})
        equal(H.archive(client).frame, nextView.frame); equal(#nextView.selector.choices, 1)
    end)

    test("C7 absent pooling and dropped replies give bounded manual retry with one five-second timeout", function()
        local client = fixture(); client.archivePooled = false
        H.savedButton(client):DoClick(); local view = H.archive(client)
        equal(requests(client), 0); equal(client.archiveStarts, 0); equal(#client.archiveTimers, 0)
        equal(view.status.text, "Saved intel is unavailable on this server. You can still use !readIntel.")
        client.archivePooled = true; view.refresh:DoClick(); local dropped = H.lastRequest(client)
        equal(#client.archiveTimers, 1); client.advanceArchive(4.999); equal(view.status.text, "Loading saved intel...")
        client.advanceArchive(0.001); equal(view.status.text, "No reply received. Refresh/select again.")
        local messages = requests(client); client.advanceArchive(50); equal(requests(client), messages)
        H.list(client, dropped, {H.entry("1")}); equal(#view.selector.choices, 0)
        view.refresh:DoClick(); local retry = H.lastRequest(client); assert(retry.token ~= dropped.token)
        local entry = H.entry("1"); H.list(client, retry, {entry}); view.selector:ChooseOptionID(1)
        local bodyRequest = H.lastRequest(client); client.advanceArchive(5)
        equal(view.status.text, "No reply received. Refresh/select again."); equal(view.body.text, "")
        H.body(client, bodyRequest, entry); equal(view.body.text, "")
        messages = requests(client); view.selector:ChooseOptionID(1); equal(requests(client), messages + 1)
        H.body(client, H.lastRequest(client), entry); equal(view.body.text, entry.body)
        client.advanceArchive(5); equal(view.status.text, "Saved clue loaded.")
    end)

    test("C8 guarded transport and presentation failures retire only the captured attempt", function()
        for _, stage in ipairs({"start", "write", "send"}) do
            local client = fixture(); local latest = H.savedButton(client).parent
            client.archiveFail = stage; H.savedButton(client):DoClick(); local view = H.archive(client)
            equal(requests(client), 0); equal(#client.archiveTimers, 0)
            equal(view.status.text, "Saved intel could not be requested. Refresh/select again.")
            equal(latest.valid, true); equal(#H.frames(client, latest.title), 1)
            client.archiveFail = nil; view.refresh:DoClick(); equal(requests(client), 1)
            H.list(client, H.lastRequest(client), {}); equal(view.status.text, "Select a saved clue to read it.")
        end
        do
            local client = fixture(); client.archivePanelFail = "DComboBox"
            H.savedButton(client):DoClick(); equal(#H.frames(client, "Saved mission intel"), 0)
            equal(requests(client), 0); equal(#client.chatMessages, 1)
            client.archivePanelFail = nil; H.open(client); equal(requests(client), 1)
        end
        do
            local client = fixture(); local send = client.net.SendToServer
            client.net.SendToServer = function()
                send(); H.list(client, H.lastRequest(client), {H.entry("1")})
                error("failure after synchronous success")
            end
            local view = H.open(client)
            equal(#view.selector.choices, 1); equal(view.status.text, "Select a saved clue to read it.")
            equal(#client.archiveTimers, 0); equal(requests(client), 1)
        end
        do
            local client = fixture(); local send = client.net.SendToServer
            local old
            client.net.SendToServer = function()
                send(); old = H.lastRequest(client); client.net.SendToServer = send
                H.archive(client).refresh:DoClick()
                error("failure after replacement request")
            end
            local view = H.open(client); local replacement = H.lastRequest(client)
            assert(old.token ~= replacement.token); equal(requests(client), 2); equal(#client.archiveTimers, 1)
            H.list(client, old, {H.entry("1")}); equal(#view.selector.choices, 0)
            H.list(client, replacement, {H.entry("2")}); equal(view.selector:GetOptionData(1), "2")
        end
        do
            local client = fixture(); local view, request = H.open(client)
            local add = view.selector.AddChoice
            view.selector.AddChoice = function() error("modeled choice rendering failure") end
            H.list(client, request, {H.entry("1")}); contains(view.status.text, "could not be displayed")
            view.selector.AddChoice = add; view.refresh:DoClick()
            H.list(client, H.lastRequest(client), {H.entry("1")}); view.selector:ChooseOptionID(1)
            local setText = view.body.SetText
            view.body.SetText = function() error("modeled body rendering failure") end
            H.body(client, H.lastRequest(client), H.entry("1")); contains(view.status.text, "could not be displayed")
            view.body.SetText = setText; view.selector:ChooseOptionID(1)
            H.body(client, H.lastRequest(client), H.entry("1")); equal(view.body.text, "Literal clue")
        end
        do
            local client = fixture(); local view, request = H.open(client)
            local add = view.selector.AddChoice
            view.selector.AddChoice = function(self, ...)
                self.AddChoice = add; view.refresh:DoClick(); error("stale presentation failure")
            end
            H.list(client, request, {H.entry("1")}); local replacement = H.lastRequest(client)
            assert(replacement.token ~= request.token); equal(view.status.text, "Loading saved intel...")
            H.list(client, replacement, {H.entry("2")}); equal(view.selector:GetOptionData(1), "2")
            view.selector:ChooseOptionID(1); local oldRead = H.lastRequest(client)
            local visible = view.frame.IsVisible
            view.frame.IsVisible = function(self)
                self.IsVisible = visible; view.refresh:DoClick(); return visible(self)
            end
            H.body(client, oldRead, H.entry("2"))
            equal(view.body.text, ""); equal(view.status.text, "Loading saved intel...")
            H.list(client, H.lastRequest(client), {H.entry("3")})
            equal(view.selector:GetOptionData(1), "3")
        end
    end)

    test("C9 malformed archive bytes reject atomically including exact budgets unsafe names and noncanonical bodies", function()
        local client = fixture(); local view = H.open(client)
        local safe = H.entry("1", "café 日本語", "[name unavailable]")
        local function reject(make, correlated, bits)
            view.refresh:DoClick(); local request = H.lastRequest(client)
            local bytes = make(request.token)
            local before, reads = requests(client), client.archiveReads
            client.receiveBytes(H.replyName, nil, bytes, bits and bits(bytes) or nil)
            equal(#view.selector.choices, 0); equal(view.body.text, ""); equal(view.metadata.text, "")
            equal(requests(client), before)
            if correlated then contains(view.status.text, "could not be displayed") end
            if bits and #bytes > 4392 then equal(client.archiveReads, reads, "Oversize is refused before buffering") end
        end
        local malformed = {
            function(t) return H.reply(1, t, 0, {safe, safe}) end,
            function(t) return H.reply(1, t, 0, {H.entry("01")}) end,
            function(t) return H.reply(1, t, 0, {H.entry("9007199254740992")}) end,
            function(t) return H.reply(1, t, 0, {H.entry(string.rep("9", 17))}) end,
            function(t) return H.reply(1, t, 0, {H.entry("1", "bad\255")}) end,
            function(t) return H.reply(1, t, 0, {H.entry("1", "bad\0name")}) end,
            function(t) return H.reply(1, t, 0, {H.entry("1", "bad\nname")}) end,
            function(t) return H.reply(1, t, 0, {H.entry("1", "bad\194\128")}) end,
            function(t) return H.reply(1, t, 0, {H.entry("1", string.rep("n", 129))}) end,
            function(t) return H.reply(1, t, 0, {H.entry("1", "safe", string.rep("f", 129))}) end,
            function(t) return H.reply(1, t, 0, {safe}):sub(1, -2) .. string.char(2) end,
            function(t) return string.char(1) .. H.z(t) .. string.char(0, 11) end,
            function(t) return string.char(1) .. H.z(t) .. string.char(0) end,
            function(t) return H.reply(1, t, 0, {safe}):sub(1, -2) end,
            function(t) return H.reply(1, t, 0, {safe}) .. "x" end,
            function(t) return H.reply(1, t, 3) end,
            function(t) return H.reply(1, t, 1) .. "x" end,
            function(t) return string.char(1) .. H.z(t) .. string.char(0, 1) .. H.z("1") .. "unterminated" end,
            function(t) return H.reply(1, t, 0, {}) .. string.rep("x", 2781) end,
        }
        for _, make in ipairs(malformed) do reject(make, true) end
        local make = function(t) return H.reply(1, t, 0, {safe}) end
        for _, adjustment in ipairs({-1, 1, -8, 8}) do
            reject(make, adjustment == -8, function(bytes) return #bytes * 8 + adjustment end)
        end
        reject(function(t) return H.reply(1, t, 0, {}) .. string.rep("x", 4393) end, false, function(bytes) return #bytes * 8 end)
        reject(function() return string.char(1) .. "unterminated" end, false)
        reject(function(t) return H.reply(1, "999", 0, {safe, safe}) end, false)
        for _, prefix in ipairs({string.char(0) .. H.z("1"), string.char(3) .. H.z("1"),
            string.char(1) .. H.z("0"), string.char(1) .. H.z("01"),
            string.char(1) .. H.z(string.rep("9", 17))}) do
            reject(function() return prefix .. string.char(0, 0) end, false)
        end
        view.refresh:DoClick(); local request = H.lastRequest(client)
        local before = client.archiveReads
        client.archiveReadTransform = function(bytes) return bytes:sub(1, -2) end
        H.list(client, request, {safe}); equal(#view.selector.choices, 0); equal(client.archiveReads, before + 1)
        client.archiveReadTransform = nil
        view.refresh:DoClick(); H.list(client, H.lastRequest(client), {safe, H.entry("2", "[name unavailable]", "[name unavailable]")})
        equal(#view.selector.choices, 2)
        for _, body in ipairs({"", " \t\n", "bad\0body", "bad\255", "bad\194\128", "CR\r\nbody", string.rep("x", 4097)}) do
            view.selector:ChooseOptionID(1); local read = H.lastRequest(client)
            local entry = H.entry(safe.award, safe.consoleName, safe.fileName, safe.fileType, body)
            H.body(client, read, entry); equal(view.body.text, ""); equal(#view.selector.choices, 2)
        end
        view.selector:ChooseOptionID(1); H.body(client, H.lastRequest(client), safe)
        equal(view.body.text, safe.body); contains(view.metadata.text, "café 日本語")
    end)

    test("C10 resize death lifecycle module replacement and serial limits preserve exact ownership", function()
        local client = fixture(); local entry = H.entry("1", "café", "secret", "server", "Saved body")
        local view = loaded(client, {entry}); view.selector:ChooseOptionID(1)
        H.body(client, H.lastRequest(client), entry)
        local sent, focus = requests(client), #client.focusCalls
        for _, size in ipairs({{640, 480}, {1280, 720}, {639, 479}}) do
            client.ScrW, client.ScrH = function() return size[1] end, function() return size[2] end
            client.fire("OnScreenSizeChanged")
            equal(view.body.text, entry.body); equal(view.selector:GetOptionData(view.selector:GetSelectedID()), entry.award)
            equal(requests(client), sent); equal(#client.focusCalls, focus)
            for _, panel in ipairs(view.frame.children) do
                assert(panel.width > 0 and panel.height > 0 and panel.x >= 0 and panel.y >= 0)
                assert(panel.x + panel.width <= view.frame.width and panel.y + panel.height <= view.frame.height)
            end
        end
        client.receive("PlayerDied"); equal(H.archive(client).frame, view.frame); equal(view.body.text, entry.body)
        local holder, serial = client.slicerIntelArchiveSerialState, client.slicerIntelArchiveSerialState.value
        for index, event in ipairs({"ShutDown", "InitPostEntity", "module"}) do
            view.refresh:DoClick(); local late = H.lastRequest(client); local old = view.frame
            client.deferPanelRemoval = true
            if event == "module" then client.include("slicer/cl_intel_archive.lua") else client.fire(event) end
            equal(#H.frames(client, "Saved mission intel"), 0); equal(client.slicerIntelArchiveSerialState, holder)
            H.latest(client, tostring(index + 1), "Latest " .. index)
            view = H.open(client); local current = H.lastRequest(client)
            assert(tonumber(current.token) > serial); serial = tonumber(current.token)
            old:OnRemove(); H.list(client, late, {entry}); equal(#view.selector.choices, 0)
            H.list(client, current, {entry}); equal(H.archive(client).frame, view.frame)
        end
        -- Archive-only replacement keeps the current reader's button route.
        local saved = H.savedButton(client)
        client.include("slicer/cl_intel_archive.lua")
        saved:DoClick(); view = H.archive(client)
        equal(H.savedButton(client), saved)
        H.list(client, H.lastRequest(client), {entry})
        -- Full reader-module replacement makes its captured old button inert.
        client.include("entities/consoleent/cl_init.lua")
        sent = requests(client); saved:DoClick(); equal(requests(client), sent)
        equal(#H.frames(client, "Saved mission intel"), 0)
        H.latest(client, "20", "Fresh module latest"); view = H.open(client)
        -- An old native Remove callback cannot reopen the retiring module.
        local staleOpen, remove = client.slicerOpenIntelArchive, view.frame.Remove
        view.frame.Remove = function(self)
            staleOpen(); return remove(self)
        end
        sent = requests(client); client.include("slicer/cl_intel_archive.lua")
        equal(requests(client), sent); equal(#H.frames(client, "Saved mission intel"), 0)
        view = H.open(client)
        -- A newer include completed during removal owns callbacks afterward.
        remove = view.frame.Remove
        local newestModule, newestReceiver
        view.frame.Remove = function(self)
            local result = remove(self)
            client.include("slicer/cl_intel_archive.lua")
            newestModule, newestReceiver = client.slicerIntelArchiveController, client.receivers[H.replyName]
            H.savedButton(client):DoClick()
            return result
        end
        client.include("slicer/cl_intel_archive.lua")
        equal(client.slicerIntelArchiveController, newestModule)
        equal(client.receivers[H.replyName], newestReceiver)
        view = H.archive(client); H.list(client, H.lastRequest(client), {entry})
        equal(view.selector:GetOptionData(1), entry.award)
        view.frame:Close(); holder.value = 9007199254740990
        view = H.open(client); equal(H.lastRequest(client).token, "9007199254740991")
        local last = H.lastRequest(client); view.frame:Close()
        sent = requests(client); H.savedButton(client):DoClick(); view = H.archive(client)
        equal(requests(client), sent); contains(view.status.text, "unavailable for this connection")
        H.list(client, last, {entry}); equal(#view.selector.choices, 0)
        for _, bad in ipairs({false, -1, 0.5, math.huge, 0/0, "1"}) do
            client.slicerIntelArchiveSerialState = {value = bad}
            client.include("slicer/cl_intel_archive.lua")
            H.savedButton(client):DoClick(); view = H.archive(client)
            equal(requests(client), sent); contains(view.status.text, "unavailable for this connection")
            if bad ~= bad then assert(client.slicerIntelArchiveSerialState.value ~= client.slicerIntelArchiveSerialState.value)
            else equal(client.slicerIntelArchiveSerialState.value, bad) end
        end
        client.slicerIntelArchiveSerialState = nil; client.include("slicer/cl_intel_archive.lua")
        H.savedButton(client):DoClick(); equal(requests(client), sent); equal(client.slicerIntelArchiveSerialState, nil)
        client.slicerIntelArchiveSerialInitialized = nil; client.include("slicer/cl_intel_archive.lua")
        H.savedButton(client):DoClick(); equal(requests(client), sent)
        equal(client.slicerIntelArchiveSerialState, nil); equal(client.slicerIntelArchiveSerialInitialized, nil)
    end)
end

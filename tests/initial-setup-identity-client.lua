-- Optional payload bits here are an API double, not native wire/padding evidence.
return function(gmod, test, equal)
    local function form(c, p, name, suffix)
        local first, f, entries = #c.panels + 1, {}, {}
        if suffix == nil then c.receive("PlayerSpawnedConsole", nil, p, name)
        else c.receive("PlayerSpawnedConsole", nil, p, name, suffix) end
        for i=first,#c.panels do
            local v=c.panels[i]
            if v.class=="DFrame" then f.frame=v elseif v.class=="DTextEntry" then entries[#entries+1]=v
            elseif v.class=="DComboBox" then f.folder=v elseif v.class=="DLabel" then f.status=v
            elseif v.text=="Done" then f.done=v elseif v.text=="Set up later" then f.close=v end
        end
        f.name,f.delay,f.file=entries[1],entries[2],entries[3]; return f
    end
    local function fill(f) f.name:SetText("  Draft  "); f.delay:SetText("2.5"); f.file:SetText("  File  "); f.folder.selected="data" end
    local function fixture() local c=gmod.client(); local p=gmod.new().player(); return c,p,form(c,p,"same","slicer-initial-v2:1") end
    test("identity modern and legacy maps and same-name tokens remain independent",function()
        local c,p,a=fixture(); fill(a)
        local b=form(c,p,"same","slicer-initial-v2:2"); assert(b.frame,"New target requires an independent form"); equal(b.name:GetValue(),"")
        local legacy=form(c,p,"same"); assert(legacy.frame); fill(legacy); legacy.done:DoClick()
        equal(c.lastMessage("AdminFinishedCreation").values[1][5],"same")
        equal(form(c,p,"same","slicer-initial-v2:1").frame,nil); equal(a.name:GetValue(),"  Draft  ")
        equal(form(c,p,"contradiction","slicer-initial-v2:1").frame,nil)
        a.done:DoClick(); local d=c.lastMessage("AdminFinishedCreation").values[1][5]
        equal(type(d),"table"); equal(d.version,2); equal(d.targetToken,"1"); equal(d.originalName,"same")
    end)
    for _,suffix in ipairs({"","slicer-initial-v2:","slicer-initial-v3:1","slicer-initial-v2:01","slicer-initial-v2:9007199254740992","junk"}) do
        test("identity present malformed suffix refuses writable form "..suffix,function()
            local c=gmod.client(); local p=gmod.new().player(); equal(form(c,p,"name",suffix).frame,nil)
            assert(#p.chats>0,"Unavailable modern setup needs a notice")
        end)
    end
    test("identity suffix detection uses bits rather than rounded bytes or empty read",function()
        local c=gmod.client(); local p=gmod.new().player()
        c.net.BytesLeft=function() return 1,0 end
        assert(form(c,p,"legacy").frame,"Zero remaining bits is an absent suffix")
        c.net.BytesLeft=function() return 0,1 end
        equal(form(c,p,"truncated","").frame,nil,"One remaining bit is malformed, not legacy")
        c.net.BytesLeft=function() return 0,nil end
        equal(form(c,p,"unknown").frame,nil,"Missing bit count cannot imply absence")
    end)
    test("identity immutable descriptor and bound responses preserve uncertainty",function()
        local c,p,f=fixture(); fill(f); f.done:DoClick()
        local packet=c.lastMessage("AdminFinishedCreation"); local fields=packet.values[1]; local request=fields[6]
        equal(type(fields[5]),"table"); fields[5].targetToken="9"; fields[5].originalName="mutated"; fields[1]="mutated"
        for _,result in ipairs({{ok=false,message="old server"},{ok=true,name="draft",fileType="data"},{ok=false,message="other",targetToken="2"}}) do
            c.receive("SlicerInitialSetupReply",nil,request,result); equal(f.frame.valid,true); equal(f.name.editable,false)
        end
        assert(f.status.text:lower():find("bound",1,true),"Unbound result needs explicit uncertainty guidance")
        f.done:DoClick(); local q=c.lastMessage("SlicerInitialSetupStatusRequest").values[1]
        equal(q[1],"  Draft  "); equal(q[5].targetToken,"1"); equal(q[5].originalName,"same")
        q[5].targetToken="8"; c.now=2; f.done:DoClick(); equal(c.lastMessage("SlicerInitialSetupStatusRequest").values[1][5].targetToken,"1")
        c.receive("SlicerInitialSetupStatusReply",nil,request,{confirmed=true,name="draft",fileType="data",targetToken="1"})
        equal(f.frame.valid,false)
    end)
    test("identity close and reinclude retain exact form ownership and new request serial",function()
        local c,p,f=fixture(); fill(f); f.done:DoClick(); local old=c.lastMessage("AdminFinishedCreation").values[1]
        c.include("entities/consoleent/cl_init.lua"); equal(form(c,p,"same","slicer-initial-v2:1").frame,nil)
        f.close:DoClick(); local fresh=form(c,p,"same","slicer-initial-v2:1"); assert(fresh.frame); equal(fresh.name:GetValue(),"")
        fill(fresh); fresh.done:DoClick(); local current=c.lastMessage("AdminFinishedCreation").values[1]; assert(current[6]~=old[6])
        c.receive("SlicerInitialSetupReply",nil,old[6],{ok=true,name="draft",fileType="data",targetToken="1"}); equal(fresh.frame.valid,true)
        c.receive("SlicerInitialSetupReply",nil,current[6],{ok=false,message="Correct fields",targetToken="1"}); equal(fresh.name.editable,true)
        fresh.done:DoClick(); assert(c.lastMessage("AdminFinishedCreation").values[1][6]~=current[6])
    end)
    test("identity modern send and query callbacks own frozen request before reentry",function()
        local c,p,f=fixture(); fill(f); local send=c.net.SendToServer; local entered=0
        c.net.SendToServer=function()
            local name=c.outgoing.name; entered=entered+1
            f.done:DoClick(); send()
            if name=="SlicerInitialSetupStatusRequest" then
                local q=c.lastMessage(name).values[1]
                c.receive("SlicerInitialSetupStatusReply",nil,q[6],{confirmed=true,name="draft",fileType="data",targetToken="1"})
            end
        end
        f.done:DoClick(); equal(entered,1); equal(f.name.editable,false)
        f.done:DoClick(); equal(entered,2); equal(f.frame.valid,false)
        equal(#c.messages,2,"Reentrant Done must send neither duplicate save nor duplicate query")
    end)
    for _,retirement in ipairs({"Close","Remove"}) do
        test("identity modern "..retirement.." retires before native cleanup reopens same token",function()
            local c=gmod.client(); local p=gmod.new().player(); local create=c.vgui.Create; local old,fresh
            c.vgui.Create=function(class,parent)
                local panel=create(class,parent)
                if class=="DFrame" then
                    local native=panel[retirement]
                    panel[retirement]=function(self)
                        if old and self==old.frame then
                            fresh=form(c,p,"same","slicer-initial-v2:1"); assert(fresh.frame,"Old map ownership must already be retired")
                        end
                        return native(self)
                    end
                end
                return panel
            end
            old=form(c,p,"same","slicer-initial-v2:1"); fill(old); old.done:DoClick()
            local request=c.lastMessage("AdminFinishedCreation").values[1][6]
            old.frame[retirement](old.frame); equal(fresh.name:GetValue(),"")
            c.receive("SlicerInitialSetupReply",nil,request,{ok=true,name="draft",fileType="data",targetToken="1"})
            equal(fresh.frame.valid,true)
        end)
    end
    test("identity modern query cooldown and exhausted request serial never resend",function()
        local c,p,f=fixture(); fill(f); c.slicerInitialSetupSerial=9007199254740990; f.done:DoClick()
        equal(c.lastMessage("AdminFinishedCreation").values[1][6],"9007199254740991")
        f.done:DoClick(); local count=#c.messages; f.done:DoClick(); equal(#c.messages,count)
        c.now=2; f.done:DoClick(); equal(#c.messages,count+1)
        f.close:DoClick(); local fresh=form(c,p,"same","slicer-initial-v2:1"); fill(fresh); fresh.done:DoClick()
        equal(#c.messages,count+1); equal(fresh.name.editable,true)
        assert(fresh.status.text:find("unavailable",1,true))
    end)

end

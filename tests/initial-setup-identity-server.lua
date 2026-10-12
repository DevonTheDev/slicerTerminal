return function(gmod, test, equal)
    local function token(s) local v=s.lastMessage("PlayerSpawnedConsole").values[3]; return type(v)=="string" and v:match("^slicer%-initial%-v2:(.+)$") or "1" end
    local function fixture() local s=gmod.new(); local p=s.player(); local a=s.console(p); return s,p,a,{" Raw ",2,"tools"," File ",{version=2,targetToken=token(s),originalName=a:GetName()},"1"} end
    local function save(s,p,f) s.receive("AdminFinishedCreation",p,f); return s.lastMessage("SlicerInitialSetupReply") end
    local function status(s,p,f) s.receive("SlicerInitialSetupStatusRequest",p,f); return s.lastMessage("SlicerInitialSetupStatusReply").values[2] end
    test("identity server spawn Use and listing retain one target token",function()
        local s,p,a,f=fixture(); local first=s.lastMessage("PlayerSpawnedConsole")
        equal(#first.values,3); equal(first.values[1],p); equal(first.values[2],a:GetName())
        for i=1,8 do s.open(p,a); equal(token(s),f[5].targetToken) end
        s.fire("PlayerSay",p,"!listConsoles"); s.fire("PlayerSay",p,"!setupConsole 1"); equal(token(s),f[5].targetToken)
        local b=s.console(p); assert(token(s)~=f[5].targetToken); equal(b.SlicerInformation,nil)
    end)
    test("identity modern acceptance is bound and duplicate never replaces evidence",function()
        local s,p,a,f=fixture(); local reply=save(s,p,f); equal(reply.values[2].ok,true); equal(reply.values[2].targetToken,f[5].targetToken)
        equal(a.SlicerInformation.name,"raw"); equal(#s.returnSpawnedEntities(),1); equal(p.SlicerPendingConsole,a)
        local choice=s.console(p); p.SlicerPendingConsole=choice
        equal(save(s,p,f).values[2].ok,false); equal(p.SlicerPendingConsole,choice); equal(#s.returnSpawnedEntities(),1)
        equal(status(s,p,f).confirmed,true); equal(status(s,p,f).targetToken,f[5].targetToken)
        local legacy=s.table.Copy(f); legacy[5]=f[5].originalName; equal(status(s,p,legacy).confirmed,false)
    end)
    for _,change in ipairs({"remove","owner","name","class","creation","index","configured"}) do
        test("identity target mismatch retires ticket permanently "..change,function()
            local s,p,a,f=fixture(); local undo
            if change=="remove" then a:Remove(); undo=function() a.valid=true end
            elseif change=="owner" then a.SlicerCreator=s.player(); undo=function() a.SlicerCreator=p end
            elseif change=="name" then a:SetName("changed"); undo=function() a:SetName(f[5].originalName) end
            elseif change=="class" then a.class="prop_physics"; undo=function() a.class="consoleent" end
            elseif change=="creation" then local id=a.id; a.id=id+100; undo=function() a.id=id end
            elseif change=="index" then local old=a.EntIndex; a.EntIndex=function() return 900 end; undo=function() a.EntIndex=old end
            else a.SlicerInformation={}; undo=function() a.SlicerInformation=nil end end
            equal(save(s,p,f).values[2].ok,false); undo(); equal(save(s,p,f).values[2].ok,false)
            s.open(p,a); assert(token(s)~=f[5].targetToken,"Observed mismatch must require fresh authority")
        end)
    end
    test("identity transient reservation ambiguity and invalid fields preserve target authority",function()
        local s,p,a,f=fixture(); local session=s.slicerConsoleHasActiveSession
        s.slicerConsoleHasActiveSession=function(c) return c==a end; equal(save(s,p,f).values[2].ok,false); s.slicerConsoleHasActiveSession=session
        local b=s.console(p); b:SetName(a:GetName()); equal(save(s,p,f).values[2].ok,false); b:Remove()
        f[2]=0; equal(save(s,p,f).values[2].ok,false); f[2]=2; equal(save(s,p,f).values[2].ok,true)
    end)
    test("identity foreign authenticated player cannot consume owner's ticket",function()
        local s,p,a,f=fixture(); equal(save(s,s.player(),f).values[2].ok,false); equal(a.SlicerInformation,nil)
        p.alive=false; equal(save(s,p,f).values[2].ok,true,"In-flight save retains valid-player admission")
    end)
    for _,change in ipairs({"version","extra descriptor","missing descriptor","extra outer","missing request","bad token","unknown token","original name","raw name nul"}) do
        test("identity malformed descriptor refuses without legacy fallback "..change,function()
            local s,p,a,f=fixture()
            if change=="version" then f[5].version="2" elseif change=="extra descriptor" then f[5].extra=true
            elseif change=="missing descriptor" then f[5].version=nil elseif change=="extra outer" then f[7]=true
            elseif change=="missing request" then f[6]=nil elseif change=="bad token" then f[5].targetToken="01"
            elseif change=="unknown token" then f[5].targetToken="9000" elseif change=="original name" then f[5].originalName="other"
            else f[5].originalName="bad\0name" end
            save(s,p,f); equal(a.SlicerInformation,nil); equal(#s.returnSpawnedEntities(),0)
        end)
    end
    for i=1,6 do
        test("identity receipt requires raw field equality "..i,function()
            local s,p,a,f=fixture(); equal(save(s,p,f).values[2].ok,true)
            local changed=s.table.Copy(f)
            if i==1 then changed[i]="raw" elseif i==2 then changed[i]=3 elseif i==3 then changed[i]="data"
            elseif i==4 then changed[i]="file" elseif i==5 then changed[5].originalName="other" else changed[i]="2" end
            equal(status(s,p,changed).confirmed,false); equal(status(s,p,f).confirmed,true)
        end)
    end
    for _,event in ipairs({"death","disconnect","OnDuplicated","PostEntityPaste","reinclude"}) do
        test("identity pending and receipt lifecycle "..event,function()
            local s,p,a,f=fixture(); local b=s.console(p); local pending={"Next",2,"data","Next",{version=2,targetToken=token(s),originalName=b:GetName()},"2"}
            equal(save(s,p,f).values[2].ok,true)
            if event=="death" then s.fire("PlayerDeath",p)
            elseif event=="disconnect" then s.fire("PlayerDisconnected",p)
            elseif event=="reinclude" then s.include("autorun/server/sv_config.lua")
            else a[event](a,p); b[event](b,p) end
            equal(status(s,p,f).confirmed,event=="death"); equal(save(s,p,pending).values[2].ok,event=="death")
        end)
    end
    test("identity observed rename retires pending but historical receipt survives rename",function()
        local s,p,a,f=fixture(); equal(save(s,p,f).values[2].ok,true); a:SetName("later")
        equal(status(s,p,f).confirmed,true)
    end)
    for _,bad in ipairs({9007199254740991,-1,0.5,"bad",false}) do
        test("identity exhausted or corrupt server serial fails closed "..tostring(bad),function()
            local s=gmod.new(); s.slicerInitialSetupTargetSerial=bad; s.include("autorun/server/sv_config.lua")
            local p=s.player(); local a=s.console(p)
            equal(s.lastMessage("PlayerSpawnedConsole").values[3],"slicer-initial-v2:")
            equal(a.SlicerInformation,nil)
        end)
    end
    test("identity config reinclude keeps target serial monotonic and retires old registry",function()
        local s,p,a,f=fixture(); s.include("autorun/server/sv_config.lua"); s.open(p,a)
        assert(token(s)~=f[5].targetToken); equal(save(s,p,f).values[2].ok,false)
    end)
    for _,change in ipairs({"duplicate","remove","configure","reinclude","reopen","disconnect"}) do
        test("identity one-time reentrant scan "..change,function()
            local s,p,a,f=fixture(); local find=s.ents.FindByClass; local entered=false; local replies=#s.messages
            s.ents.FindByClass=function(class)
                if not entered then
                    entered=true
                    if change=="duplicate" then s.receive("AdminFinishedCreation",p,s.table.Copy(f)); equal(#s.messages,replies,"Nested duplicate must not unlock outer form")
                    elseif change=="remove" then a:Remove()
                    elseif change=="configure" then s.configure(p,a,"data")
                    elseif change=="reinclude" then s.include("autorun/server/sv_config.lua")
                    elseif change=="reopen" then s.open(p,a)
                    else s.fire("PlayerDisconnected",p) end
                end
                return find(class)
            end
            local r=save(s,p,f); assert(entered,"Real scan boundary must execute")
            equal(r.values[2].ok,change=="duplicate" or change=="reopen")
            equal(#s.returnSpawnedEntities(),(change=="duplicate" or change=="reopen" or change=="configure") and 1 or 0)
            equal(status(s,p,f).confirmed,change=="duplicate" or change=="reopen")
        end)
    end
    test("identity tokenless legacy rewrite preserves modern history; correlated rewrite replaces it",function()
        local s,p,a,f=fixture(); equal(save(s,p,f).values[2].ok,true)
        a.SlicerInformation=nil
        s.receive("AdminFinishedCreation",p,{"Later",3,"data","Later",a:GetName()})
        equal(a.SlicerInformation.name,"later"); equal(status(s,p,f).confirmed,true)
        local legacy={"Later",3,"data","Later",a:GetName(),f[6]}; equal(status(s,p,legacy).confirmed,false)
        a.SlicerInformation=nil; save(s,p,legacy)
        equal(status(s,p,f).confirmed,false); equal(status(s,p,legacy).confirmed,true)
    end)
    test("identity legacy acceptance consumes pending modern authority without modern evidence",function()
        local s,p,a,f=fixture(); local legacy={f[1],f[2],f[3],f[4],a:GetName(),f[6]}
        equal(save(s,p,legacy).values[2].ok,true); equal(status(s,p,f).confirmed,false)
        equal(status(s,p,legacy).confirmed,true); a.SlicerInformation=nil
        equal(save(s,p,f).values[2].ok,false)
    end)

    test("identity fresh issuance stops before getters after reentrant removal",function()
        local s,p,a=fixture(); s.include("autorun/server/sv_config.lua")
        local get=a.GetCreationID; local entered=false
        function a:GetCreationID()
            assert(self.valid,"Creation getter used after removal"); local id=get(self)
            if not entered then entered=true; self:Remove() end
            return id
        end
        function a:EntIndex() assert(self.valid,"Index getter used after removal"); return 3 end
        s.open(p,a); equal(entered,true); equal(a.SlicerInformation,nil)
        equal(s.lastMessage("PlayerSpawnedConsole").values[3],"slicer-initial-v2:")
    end)
    test("identity save stops before getters after reentrant actor removal",function()
        local s,p,a,f=fixture(); local isPlayer=p.IsPlayer; local calls=0
        function p:IsPlayer() calls=calls+1; if calls==2 then a:Remove() end; return isPlayer(self) end
        local get=a.GetCreationID
        function a:GetCreationID() assert(self.valid,"Creation getter used after actor removed target"); return get(self) end
        equal(save(s,p,f).values[2].ok,false); equal(a.SlicerInformation,nil); equal(#s.returnSpawnedEntities(),0)
    end)
    for _,change in ipairs({"owner","class","creation","index"}) do
        test("identity receipt context invalidation cannot revive historical evidence "..change,function()
            local s,p,a,f=fixture(); equal(save(s,p,f).values[2].ok,true); local undo
            if change=="owner" then a.SlicerCreator=s.player(); undo=function() a.SlicerCreator=p end
            elseif change=="class" then a.class="prop_physics"; undo=function() a.class="consoleent" end
            elseif change=="creation" then local id=a.id; a.id=id+10; undo=function() a.id=id end
            else local old=a.EntIndex; a.EntIndex=function() return 800 end; undo=function() a.EntIndex=old end end
            equal(status(s,p,f).confirmed,false); undo(); equal(status(s,p,f).confirmed,false)
        end)
    end
    test("identity target and sender receipt substitutions cannot confirm",function()
        local s,p,a,f=fixture(); equal(save(s,p,f).values[2].ok,true)
        equal(status(s,s.player(),f).confirmed,false)
        local changed=s.table.Copy(f); changed[5].targetToken="9999"; equal(status(s,p,changed).confirmed,false)
        equal(status(s,p,f).confirmed,true)
    end)
    test("identity server serial reaches maximum once and repeated opens do not allocate",function()
        local s=gmod.new(); s.slicerInitialSetupTargetSerial=9007199254740990; local p=s.player(); local a=s.console(p)
        equal(token(s),"9007199254740991"); s.open(p,a); equal(token(s),"9007199254740991")
        s.console(p); equal(s.lastMessage("PlayerSpawnedConsole").values[3],"slicer-initial-v2:")
        equal(s.slicerInitialSetupTargetSerial,9007199254740991)
    end)

    test("identity malformed oversized target token is never reflected in a response",function()
        local s,p,a,f=fixture(); f[5].targetToken=string.rep("1",65500)
        assert(save(s,p,f).values[2].targetToken==nil,"Malformed target token must not be echoed by save")
        assert(status(s,p,f).targetToken==nil,"Malformed target token must not be echoed by status"); equal(a.SlicerInformation,nil)
    end)

end

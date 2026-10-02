include("entities/consoleent/shared.lua")

-- A terminal has several independent frames, timers and Think hooks. Tear all
-- of them down together so death, quitting and completion cannot leave a timer
-- reopening a closed terminal or updating a removed panel.
local function closeConsoleUI()
    for _, panel in pairs({firstPage, secondPage, insideData, insideServer, insideTools}) do
        if IsValid(panel) then panel:Remove() end
    end
    firstPage, secondPage, insideData, insideServer, insideTools = nil, nil, nil, nil, nil
    for _, name in ipairs({
        "AccessDelay", "DownloadDataFile", "DownloadServerFile",
        "firstPageGlitch", "firstPageReturn", "secondPageGlitch", "secondPageReturn",
        "dataPageGlitch", "dataPageReturn",
    }) do
        timer.Remove(name)
    end
    for _, name in ipairs({"printDelay", "downloadDataFile", "downloadServerFile"}) do
        hook.Remove("Think", name)
    end
end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code draws the console entities model for the client
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

-- Draws the entity model
function ENT:Draw()

    self:DrawModel()

    local ang = self:GetAngles()

    ang:RotateAroundAxis(self:GetAngles():Up(), 90)
    ang:RotateAroundAxis(self:GetAngles():Right(), -90)

    cam.Start3D2D(self:GetPos(), ang, 0.1)

        draw.SimpleText("<CONSOLE>", "ConsoleFont", -480, -850, Color(255, 0, 0, 255))

    cam.End3D2D()

end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code sets up our custom font
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

surface.CreateFont("HackingFont", {
    font = "Data Control",
    size = 15,
})

surface.CreateFont("FolderFont", {
    font = "Data Control",
    size = 60

})

surface.CreateFont("ConsoleFont", {
    font = "Data Control",
    size = 500

})


--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code sets up the editable fields for the GM/Admin who spawned the entity
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

-- START OF ADMIN UI
net.Receive("PlayerSpawnedConsole", function()

    local callingPlayer = net.ReadEntity() -- Accesses the player who spawned the console
    local sentConsoleName = net.ReadString() -- Accesses the spawned console

    -- Sets up the background frame
    local initialParent = vgui.Create("DFrame")
    initialParent:SetSize(ScrW(), ScrH())
    initialParent:Center()
    initialParent:ShowCloseButton(false)
    initialParent:MakePopup()
    initialParent:SetTitle("")
    initialParent:SetDeleteOnClose(true)
    initialParent:SetDraggable(false)
    function initialParent.Paint(self, w, h)
        draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
    end

    -- Allows the spawner to give the file path
    local fileType = vgui.Create("DComboBox", initialParent)
    fileType:AddChoice("data", nil, false, nil)
    fileType:AddChoice("server", nil, false, nil)
    fileType:AddChoice("tools", nil, false, nil)
    fileType:SetSize(200, 100)
    fileType:Center()

    -- Allows the spawner to give the console a name
    local consoleNameFrame = vgui.Create("DTextEntry", initialParent)
    consoleNameFrame:AllowInput(true)
    consoleNameFrame:SetPlaceholderText("Enter Console Name Here")
    consoleNameFrame:SetPlaceholderColor(Color(150, 150, 150, 200))
    consoleNameFrame:SetSize(200, 100)
    consoleNameFrame:SetPos(fileType:GetX(), fileType:GetY() - 200)
    consoleNameFrame:SetTextColor(Color(0, 0, 0, 255))

    -- Allows the spawner to give the time for the slice
    local slicerTime = vgui.Create("DTextEntry", initialParent)
    slicerTime:AllowInput(true)
    slicerTime:SetPlaceholderText("Enter Slice Time here (Seconds)")
    slicerTime:SetPlaceholderColor(Color(150, 150, 150, 200))
    slicerTime:SetSize(200, 100)
    slicerTime:SetPos(fileType:GetX(), fileType:GetY() - 100)
    slicerTime:SetTextColor(Color(0, 0, 0, 255))

    -- Allows the spawner to name the file
    local fileName = vgui.Create("DTextEntry", initialParent)
    fileName:AllowInput(true)
    fileName:SetPlaceholderText("Enter File Name here (No extension)")
    fileName:SetPlaceholderColor(Color(150, 150, 150, 200))
    fileName:SetSize(200, 100)
    fileName:SetPos(fileType:GetX(), fileType:GetY() + 100)
    fileName:SetTextColor(Color(0, 0, 0, 255))

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code adds a finished button to the panel, which when clicked checks to see if all the fields are valid.
    If the fields are valid, the code will send all the information to the server so all clients have access to it and close the frame.
    If the fields are invalid, the admin will be alerted.
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    -- Adds a finish button that assigns the values to the variables and runs a check on the file type
    local finishButton = vgui.Create("DButton", initialParent)
    finishButton:SetSize(200, 100)
    finishButton:SetPos(fileType:GetX(), fileType:GetY() + 300)
    finishButton:SetText("Done")
    function finishButton.DoClick()
        -- Read this form at submission time; focus callbacks and globals can
        -- miss the latest edit or leak values into another console's setup.
        local enteredConsoleName = consoleNameFrame:GetValue()
        local enteredSliceDelay = tonumber(slicerTime:GetValue())
        local enteredFileType = fileType:GetSelected()
        local enteredFileName = fileName:GetValue()

        -- Match the server's field rules so invalid entries remain editable.
        -- The server still authenticates the creator and validates the packet.
        if #enteredConsoleName > 128 or string.Trim(enteredConsoleName) == ""
            or #enteredFileName > 128 or string.Trim(enteredFileName) == ""
            or enteredSliceDelay == nil or enteredSliceDelay != enteredSliceDelay
            or enteredSliceDelay <= 0 or enteredSliceDelay == math.huge
            or (enteredFileType != "data" and enteredFileType != "server" and enteredFileType != "tools") then
            callingPlayer:ChatPrint("One or more fields is invalid")
            return
        end

        local consoleInformation = {enteredConsoleName, enteredSliceDelay, enteredFileType, enteredFileName, sentConsoleName}
        net.Start("AdminFinishedCreation")
            net.WriteTable(consoleInformation)
        net.SendToServer()
        initialParent:Close()

        if enteredFileType == "tools" then
            callingPlayer:ChatPrint("Please type !setEntity when looking at a door to link the console.")
            net.Start("ServerWaitingForEntity")
                net.WriteEntity(callingPlayer)
            net.SendToServer()
        end
    end
end)

-- END OF ADMIN UI


--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code creates the UI for the hacking console. It accesses the information send to the server through a net.receive function
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

-- START OF HACKING UI

net.Receive("ServerSendsEntityInformation", function() -- Frames open

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code sets up the local variables and assigns them to the values sent by the server
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    
    local usedConsole = net.ReadEntity()
    local callingPlayer = net.ReadEntity()

    local consoleInfo = net.ReadTable()
    --[[
    Output of this table is
    name
    delay
    fileType
    fileName
    inUse
    --]]

    local consoleName = net.ReadString()

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    PURPOSE

    This code checks to see if the client has the hacking tool, and if so begins to draw the hacking UI
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    local upperBound = 7
    local lowerBound = 3
if(!consoleInfo["inUse"]) then

    surface.PlaySound("code_welcome.wav")

    net.Start("updateInUse")
        net.WriteString(consoleName)
    net.SendToServer()

    -- Creates the parent frame that we can close
   firstPage = vgui.Create("DFrame")
   firstPage:SetPos(0, 0)
   firstPage:SetSize(ScrW(), ScrH())
   firstPage:MakePopup()
   firstPage:SetDraggable(false)
   firstPage:SetTitle("")
   firstPage:ShowCloseButton(false)
   function firstPage.Paint(self, w, h)
       draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
   end


   -- Set the background image for the hacking UI
   local backgroundImage = vgui.Create("DImage", firstPage)
   backgroundImage:SetSize(ScrW(), ScrH())
   backgroundImage:SetPos(0, 0)
   backgroundImage:SetImage("vgui/consoleframe1.png")
   -- Creates the glitch effect for the console background
   timer.Create("firstPageGlitch", math.random(lowerBound, upperBound), 0, function()
       backgroundImage:SetImage("vgui/consoleframe2.png")
       timer.Create("firstPageReturn", 0.5, 1, function()
           backgroundImage:SetImage("vgui/consoleframe1.png")
       end)
   end)

   local findFileLabel1 = vgui.Create("DLabel", firstPage)
   findFileLabel1:SetFont("FolderFont")
   findFileLabel1:SetText("Locate file '" .. consoleInfo["fileName"] .. "'")
   findFileLabel1:SetSize(findFileLabel1:GetTextSize())
   findFileLabel1:SetTextColor(Color(255, 0, 0, 255))
   findFileLabel1:SetPos(-ScrW() - findFileLabel1:GetTextSize(), 100)
   
   findFileLabel1:MoveTo((ScrW()/2) - findFileLabel1:GetTextSize()/2, 105, 1, 0.2, 1)


   -- Prints the console identifier to the top
   local consoleNameLabel = vgui.Create("DLabel", firstPage)
   consoleNameLabel:SetFont("FolderFont")
   consoleNameLabel:SetText(consoleInfo["name"])
   consoleNameLabel:SetPos(0, 0)
   consoleNameLabel:SetSize(ScrW(), 100)
   consoleNameLabel:SetContentAlignment(5)

   -- Paints the banner
   function consoleNameLabel.Paint(self, w, h)
       draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
   end


   -- Creates the username and password "inputs"
   local userBox = vgui.Create("DTextEntry", firstPage)
   userBox:SetFont("HackingFont")
   userBox:SetPlaceholderText("User ID")
   userBox:SetPlaceholderColor(Color(140, 140, 140, 220))
   userBox:SetSize(100, 25)
   userBox:SetPos((ScrW()/2) - 50, (ScrH()/2) - 12.5)
   userBox:SetEditable(false) -- Stops the player being able to interact with the console

   local passBox = vgui.Create("DTextEntry", firstPage)
   passBox:SetFont("HackingFont")
   passBox:SetPlaceholderText("Password ID")
   passBox:SetPlaceholderColor(Color(140, 140, 140, 220))
   passBox:SetSize(100, 25)
   passBox:SetPos((ScrW()/2) - 50, (ScrH()/2) + 12.5)
   passBox:SetEditable(false) -- Stops the player being able to interact with the console

   -- Creates the access terminal
   local inputTerminal1 = vgui.Create("DTextEntry", firstPage)
   inputTerminal1:SetFont("HackingFont")
   inputTerminal1:SetPlaceholderText("Run Commands Here...")
   inputTerminal1:SetPlaceholderColor(Color(140, 140, 140, 220))
   inputTerminal1:SetSize(ScrW(), 100)
   inputTerminal1:SetPos(5, ScrH()-100)
   inputTerminal1:SetTextColor(Color(36, 209, 36, 255))
   inputTerminal1:SetPaintBackground(false)
   inputTerminal1:SetCursorColor(Color(36, 209, 36, 255))

   inputTerminal1.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
       self:SetPlaceholderText("")
   end
   
   function inputTerminal1:OnEnter()

    surface.PlaySound("code_enter.wav")

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code checks to see if the entered value is equal to the quit command, and then quits the console
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

       -- Quits the console
       if(string.lower(inputTerminal1:GetValue()) == "/q[" .. consoleInfo["name"] .. "]") then
           closeConsoleUI()
           net.Start("playerQuitConsole")
               net.WriteEntity(callingPlayer)
               net.WriteEntity(usedConsole)
           net.SendToServer()
           return
       end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code checks to see if the entered value is equal to the access command, and then runs the countdown timer and loads the next page
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

       if(string.lower(inputTerminal1:GetValue()) == "/a[" .. consoleInfo["name"] .. "]") then
           timer.Create("AccessDelay", consoleInfo["delay"], 1, function()
               timer.Remove("AccessDelay")
               
--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code sets up the second page of the console
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

               firstPage:Remove() -- Removes the login terminal
               timer.Remove("firstPageGlitch") -- Removes the glitch effect so errors are thrown
               timer.Remove("firstPageReturn") -- Removes the glitch effect so errors are thrown

                surface.PlaySound("code_accessgranted.wav")

               -- Creates the parent frame that we can close
               secondPage = vgui.Create("DFrame")
               secondPage:SetPos(0, 0)
               secondPage:SetSize(ScrW(), ScrH())
               secondPage:MakePopup()
               secondPage:SetDraggable(false)
               secondPage:SetTitle("")
               secondPage:ShowCloseButton(false)
               function secondPage.Paint(self, w, h)
                   draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
               end


               -- Set the background image for the hacking UI
               local backgroundImage = vgui.Create("DImage", secondPage)
               backgroundImage:SetSize(ScrW(), ScrH())
               backgroundImage:SetPos(0, 0)
               backgroundImage:SetImage("vgui/consoleframe1.png")
               -- Creates the glitch effect for the console background
               timer.Create("secondPageGlitch", math.random(lowerBound, upperBound), 0, function()
                   backgroundImage:SetImage("vgui/consoleframe2.png")
                   timer.Create("secondPageReturn", 0.5, 1, function()
                       backgroundImage:SetImage("vgui/consoleframe1.png")
                   end)
               end)

               local findFileLabel2 = vgui.Create("DLabel", secondPage)
               findFileLabel2:SetFont("FolderFont")
               findFileLabel2:SetText("Locate file '" .. consoleInfo["fileName"] .. "'")
               findFileLabel2:SetSize(findFileLabel2:GetTextSize())
               findFileLabel2:SetTextColor(Color(255, 0, 0, 255))
               findFileLabel2:SetPos((ScrW()/2) - findFileLabel2:GetTextSize()/2, 105)


               -- Prints the console identifier to the top
               local consoleNameLabel = vgui.Create("DLabel", secondPage)
               consoleNameLabel:SetFont("FolderFont")
               consoleNameLabel:SetText(consoleInfo["name"])
               consoleNameLabel:SetPos(0, 0)
               consoleNameLabel:SetSize(ScrW(), 100)
               consoleNameLabel:SetContentAlignment(5)

               -- Paints the banner
               function consoleNameLabel.Paint(self, w, h)
                   draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
               end


               -- Creates the images to display the different folders
               local dataFolderImage = vgui.Create("DImage", secondPage)
               dataFolderImage:SetSize(512, 512)
               dataFolderImage:Center()
               dataFolderImage:SetImage("vgui/folder1.png")

               local serverFolderImage = vgui.Create("DImage", secondPage)
               serverFolderImage:SetSize(512, 512)
               serverFolderImage:SetPos(dataFolderImage:GetX() + 600, dataFolderImage:GetY())
               serverFolderImage:SetImage("vgui/folder2.png")

               local toolsFolderImage = vgui.Create("DImage", secondPage)
               toolsFolderImage:SetSize(512, 512)
               toolsFolderImage:SetPos(dataFolderImage:GetX() - 600, dataFolderImage:GetY())
               toolsFolderImage:SetImage("vgui/folder3.png")

               -- Creates the access terminal
               local inputTerminal2 = vgui.Create("DTextEntry", secondPage)
               inputTerminal2:SetFont("HackingFont")
               inputTerminal2:SetPlaceholderText("Run Commands Here...")
               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
               inputTerminal2:SetSize(ScrW(), 100)
               inputTerminal2:SetPos(5, ScrH()-100)
               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
               inputTerminal2:SetPaintBackground(false)
               inputTerminal2:SetCursorColor(Color(36, 209, 36, 255))

               inputTerminal2.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                   self:SetPlaceholderText("")
               end

               inputTerminal2.OnLoseFocus = function(self)
                   self:SetPlaceholderText("Run Commands Here...")
                   self:SetPlaceholderColor(Color(140, 140, 140, 220))
               end
               
               function inputTerminal2:OnEnter()

                surface.PlaySound("code_enter.wav")
--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code checks to see if the entered value is equal to the a function and then runs that function
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

local acceptedFolders = {
   "{_data}",
   "{_server}",
   "{_tools}",
}

local filenames = {
   "hitlist",
   "consoleLogs",
   "important",
}

                   if(string.lower(inputTerminal2:GetValue()) == "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1]) then

                       timer.Stop("secondPageGlitch") -- Removes the glitch effect so errors aren't thrown
                       timer.Stop("secondPageReturn") -- Removes the glitch effect so errors aren't thrown

                       -- Creates the parent frame that we can close
                       insideData = vgui.Create("DFrame")
                       insideData:SetPos(0, 0)
                       insideData:SetSize(ScrW(), ScrH())
                       insideData:MakePopup()
                       insideData:SetDraggable(false)
                       insideData:SetTitle("")
                       insideData:ShowCloseButton(false)
                       function insideData.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
                       end


                       -- Set the background image for the hacking UI
                       local dataBackgroundImage = vgui.Create("DImage", insideData)
                       dataBackgroundImage:SetSize(ScrW(), ScrH())
                       dataBackgroundImage:SetPos(0, 0)
                       dataBackgroundImage:SetImage("vgui/consoleframe1.png")
                       -- Creates the glitch effect for the console background
                       timer.Create("dataPageGlitch", math.random(lowerBound, upperBound), 0, function()
                           dataBackgroundImage:SetImage("vgui/consoleframe2.png")
                           timer.Create("dataPageReturn", 0.5, 1, function()
                               dataBackgroundImage:SetImage("vgui/consoleframe1.png")
                           end)
                       end)

                       local findFileLabel3 = vgui.Create("DLabel", insideData)
                       findFileLabel3:SetFont("FolderFont")
                       findFileLabel3:SetText("Locate file '" .. consoleInfo["fileName"] .. "'")
                       findFileLabel3:SetSize(findFileLabel3:GetTextSize())
                       findFileLabel3:SetTextColor(Color(255, 0, 0, 255))
                       findFileLabel3:SetPos((ScrW()/2) - findFileLabel3:GetTextSize()/2, 105)
                        

                       -- Prints the console identifier to the top
                       local dataNameLabel = vgui.Create("DLabel", insideData)
                       dataNameLabel:SetFont("FolderFont")
                       dataNameLabel:SetText(consoleInfo["name"] .. "/" .. acceptedFolders[1])
                       dataNameLabel:SetPos(0, 0)
                       dataNameLabel:SetSize(ScrW(), 100)
                       dataNameLabel:SetContentAlignment(5)

                       -- Paints the banner
                       function dataNameLabel.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
                       end  

                       if(consoleInfo["fileType"] == "data") then
                           local dataRequiredFile = vgui.Create("DTextEntry", insideData)
                           dataRequiredFile:SetSize(300, 100)
                           dataRequiredFile:Center()
                           dataRequiredFile:SetFont("HackingFont")
                           dataRequiredFile:SetText(string.upper(consoleInfo["fileName"]) .. ".data")
                           dataRequiredFile:SetEditable(false)

                           local randomFile1 = vgui.Create("DTextEntry", insideData)
                           randomFile1:SetSize(300, 100)
                           randomFile1:SetPos(dataRequiredFile:GetX(), dataRequiredFile:GetY() - 100)
                           randomFile1:SetFont("HackingFont")
                           for k, v in pairs(filenames) do
                               if v != consoleInfo["fileName"] then
                                   randomFile1:SetText(v .. ".data")
                                   table.RemoveByValue(filenames, v)
                               end
                           end

                           local randomFile2 = vgui.Create("DTextEntry", insideData)
                           randomFile2:SetSize(300, 100)
                           randomFile2:SetPos(dataRequiredFile:GetX(), dataRequiredFile:GetY() + 100)
                           randomFile2:SetFont("HackingFont")
                           for k, v in pairs(filenames) do
                               if v != consoleInfo["fileName"] then
                                   randomFile2:SetText(v .. ".data")
                                   table.RemoveByValue(filenames, v)
                               end
                           end
                       else
                           local randomFile1 = vgui.Create("DTextEntry", insideData)
                           randomFile1:SetSize(300, 100)
                           randomFile1:Center()
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetEditable(false)
                           randomFile1:SetText("consoleLogs.data")

                           local randomFile2 = vgui.Create("DTextEntry", insideData)
                           randomFile2:SetSize(300, 100)
                           randomFile2:SetPos(randomFile1:GetX(), randomFile1:GetY() - 100)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetEditable(false)
                           randomFile2:SetText("recentlyDeleted.data")

                           local randomFile3 = vgui.Create("DTextEntry", insideData)
                           randomFile3:SetSize(300, 100)
                           randomFile3:SetPos(randomFile1:GetX(), randomFile1:GetY() + 100)
                           randomFile3:SetFont("HackingFont")
                           randomFile3:SetEditable(false)
                           randomFile3:SetText("cleaningLog.data")
                       end

                       secondPage:Hide()

                       -- Creates the access terminal
                       local dataInputTerminal = vgui.Create("DTextEntry", insideData)
                       dataInputTerminal:SetFont("HackingFont")
                       dataInputTerminal:SetPlaceholderText("Run Commands Here...")
                       dataInputTerminal:SetPlaceholderColor(Color(140, 140, 140, 220))
                       dataInputTerminal:SetSize(ScrW(), 100)
                       dataInputTerminal:SetPos(5, ScrH()-100)
                       dataInputTerminal:SetTextColor(Color(36, 209, 36, 255))
                       dataInputTerminal:SetPaintBackground(false)
                       dataInputTerminal:SetCursorColor(Color(36, 209, 36, 255))

                       dataInputTerminal.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                           self:SetPlaceholderText("")
                       end

                       dataInputTerminal.OnLoseFocus = function(self)
                           self:SetPlaceholderText("Run Commands Here...")
                           self:SetPlaceholderColor(Color(140, 140, 140, 220))
                       end

                       function dataInputTerminal.OnEnter()

                            surface.PlaySound("code_enter.wav")

                           if(string.lower(dataInputTerminal:GetValue()) == "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1]) then
                               insideData:Remove()
                               insideData = nil
                               timer.Remove("dataPageGlitch")
                               timer.Remove("dataPageReturn")

                               -- Resets the input terminal
                               inputTerminal2:SetPlaceholderText("Run Commands Here...")
                               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
                               inputTerminal2:SetText("")
                               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
                               timer.Start("secondPageGlitch")
                               secondPage:Show() -- Shows the previous page
                               return
                           end
                           if(string.lower(dataInputTerminal:GetValue()) == "/d" .. acceptedFolders[1] .. "/" .. consoleInfo["fileName"] .. ".data") then
                               if(consoleInfo["fileType"] == "data") then
                                   timer.Create("DownloadDataFile", consoleInfo["delay"], 1, function()
                                       closeConsoleUI()

                                       net.Start("destroyOnServer")
                                           net.WriteEntity(usedConsole) -- Allows us to delete the console on server side
                                       net.SendToServer()

                                       -- chat.AddText already targets the local player.
                                       chat.AddText(Color(255, 251, 0), "[" .. string.upper(consoleInfo["name"]) .. "]: ", Color(255, 255, 255, 255), callingPlayer:GetName() .. " has downloaded '" .. consoleInfo["fileName"] .. ".data'")
                                   end)
                                   hook.Add("Think", "downloadDataFile", function()
                                       if(timer.Exists("DownloadDataFile")) then
                                           local timeLeft = math.Round(timer.TimeLeft("DownloadDataFile"), 2) -- Sets the time left = to 2 decimal places (aesthetics)
                                           dataInputTerminal:SetEditable(false) -- Prevents the player typing in the box once the countdown has started
                                           dataInputTerminal:SetText("")
                                           if(timeLeft > 0.01) then
                                               dataInputTerminal:SetPlaceholderColor(Color(36, 209, 36, 255))
                                               dataInputTerminal:SetPlaceholderText("Time to download: " .. timeLeft .. " seconds") -- Counts down for the player
                                           end 
                                       end
                                   
                                   end)
                               end
                           end
                           if(string.lower(dataInputTerminal:GetValue()) != "/d" .. acceptedFolders[1] .. "/" .. consoleInfo["fileName"] .. ".data" and string.lower(dataInputTerminal:GetValue()) != "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1]) then
                            dataInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                            dataInputTerminal:SetText("")
                            dataInputTerminal:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                            end
                       end

                   end

                   if(string.lower(inputTerminal2:GetValue()) == "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2]) then

                       timer.Stop("secondPageGlitch") -- Removes the glitch effect so errors aren't thrown
                       timer.Stop("secondPageReturn") -- Removes the glitch effect so errors aren't thrown

                       -- Creates the parent frame that we can close
                       insideServer = vgui.Create("DFrame")
                       insideServer:SetPos(0, 0)
                       insideServer:SetSize(ScrW(), ScrH())
                       insideServer:MakePopup()
                       insideServer:SetDraggable(false)
                       insideServer:SetTitle("")
                       insideServer:ShowCloseButton(false)
                       function insideServer.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
                       end


                       -- Set the background image for the hacking UI
                       local serverBackgroundImage = vgui.Create("DImage", insideServer)
                       serverBackgroundImage:SetSize(ScrW(), ScrH())
                       serverBackgroundImage:SetPos(0, 0)
                       serverBackgroundImage:SetImage("vgui/consoleframe1.png")
                       -- Creates the glitch effect for the console background
                       timer.Create("dataPageGlitch", math.random(lowerBound, upperBound), 0, function()
                           serverBackgroundImage:SetImage("vgui/consoleframe2.png")
                           timer.Create("dataPageReturn", 0.5, 1, function()
                               serverBackgroundImage:SetImage("vgui/consoleframe1.png")
                           end)
                       end)

                       local findFileLabel4 = vgui.Create("DLabel", insideServer)
                       findFileLabel4:SetFont("FolderFont")
                       findFileLabel4:SetText("Locate file '" .. consoleInfo["fileName"] .. "'")
                       findFileLabel4:SetSize(findFileLabel4:GetTextSize())
                       findFileLabel4:SetTextColor(Color(255, 0, 0, 255))
                       findFileLabel4:SetPos((ScrW()/2) - findFileLabel4:GetTextSize()/2, 105)


                       -- Prints the console identifier to the top
                       local serverNameLabel = vgui.Create("DLabel", insideServer)
                       serverNameLabel:SetFont("FolderFont")
                       serverNameLabel:SetText(consoleInfo["name"] .. "/" .. acceptedFolders[2])
                       serverNameLabel:SetPos(0, 0)
                       serverNameLabel:SetSize(ScrW(), 100)
                       serverNameLabel:SetContentAlignment(5)

                       -- Paints the banner
                       function serverNameLabel.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
                       end  

                       if(consoleInfo["fileType"] == "server") then
                           local serverRequiredFile = vgui.Create("DTextEntry", insideServer)
                           serverRequiredFile:SetSize(300, 100)
                           serverRequiredFile:Center()
                           serverRequiredFile:SetFont("HackingFont")
                           serverRequiredFile:SetText(string.upper(consoleInfo["fileName"]) .. ".sys")
                           serverRequiredFile:SetEditable(false)

                           local randomFile1 = vgui.Create("DTextEntry", insideServer)
                           randomFile1:SetSize(300, 100)
                           randomFile1:SetPos(serverRequiredFile:GetX(), serverRequiredFile:GetY() - 100)
                           randomFile1:SetFont("HackingFont")
                           for k, v in pairs(filenames) do
                               if v != consoleInfo["fileName"] then
                                   randomFile1:SetText(v .. ".sys")
                                   table.RemoveByValue(filenames, v)
                               end
                           end

                           local randomFile2 = vgui.Create("DTextEntry", insideServer)
                           randomFile2:SetSize(300, 100)
                           randomFile2:SetPos(serverRequiredFile:GetX(), serverRequiredFile:GetY() + 100)
                           randomFile2:SetFont("HackingFont")
                           for k, v in pairs(filenames) do
                               if v != consoleInfo["fileName"] then
                                   randomFile2:SetText(v .. ".sys")
                                   table.RemoveByValue(filenames, v)
                               end
                           end
                       else
                           local randomFile1 = vgui.Create("DTextEntry", insideServer)
                           randomFile1:SetSize(300, 100)
                           randomFile1:Center()
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetEditable(false)
                           randomFile1:SetText("updateCheck.sys")

                           local randomFile2 = vgui.Create("DTextEntry", insideServer)
                           randomFile2:SetSize(300, 100)
                           randomFile2:SetPos(randomFile1:GetX(), randomFile1:GetY() - 100)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetEditable(false)
                           randomFile2:SetText("connections.sys")

                           local randomFile3 = vgui.Create("DTextEntry", insideServer)
                           randomFile3:SetSize(300, 100)
                           randomFile3:SetPos(randomFile1:GetX(), randomFile1:GetY() + 100)
                           randomFile3:SetFont("HackingFont")
                           randomFile3:SetEditable(false)
                           randomFile3:SetText("idCheck.sys")
                       end

                       secondPage:Hide()

                       -- Creates the access terminal
                       local serverInputTerminal = vgui.Create("DTextEntry", insideServer)
                       serverInputTerminal:SetFont("HackingFont")
                       serverInputTerminal:SetPlaceholderText("Run Commands Here...")
                       serverInputTerminal:SetPlaceholderColor(Color(140, 140, 140, 220))
                       serverInputTerminal:SetSize(ScrW(), 100)
                       serverInputTerminal:SetPos(5, ScrH()-100)
                       serverInputTerminal:SetTextColor(Color(36, 209, 36, 255))
                       serverInputTerminal:SetPaintBackground(false)
                       serverInputTerminal:SetCursorColor(Color(36, 209, 36, 255))

                       serverInputTerminal.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                           self:SetPlaceholderText("")
                       end

                       serverInputTerminal.OnLoseFocus = function(self)
                           self:SetPlaceholderText("Run Commands Here...")
                           self:SetPlaceholderColor(Color(140, 140, 140, 220))
                       end

                       function serverInputTerminal.OnEnter()

                        surface.PlaySound("code_enter.wav")

                           if(string.lower(serverInputTerminal:GetValue()) == "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2]) then
                               insideServer:Remove()
                               insideServer = nil
                               timer.Remove("dataPageGlitch")
                               timer.Remove("dataPageReturn")

                               -- Resets the input terminal
                               inputTerminal2:SetPlaceholderText("Run Commands Here...")
                               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
                               inputTerminal2:SetText("")
                               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
                               timer.Start("secondPageGlitch")
                               secondPage:Show() -- Shows the previous page
                               return
                           end
                           if(string.lower(serverInputTerminal:GetValue()) == "/d" .. acceptedFolders[2] .. "/" .. consoleInfo["fileName"] .. ".sys") then
                               if(consoleInfo["fileType"] == "server") then
                                   timer.Create("DownloadServerFile", consoleInfo["delay"], 1, function()
                                       closeConsoleUI()

                                       net.Start("destroyOnServer")
                                           net.WriteEntity(usedConsole) -- Allows us to delete the console on server side
                                       net.SendToServer()

                                       -- chat.AddText already targets the local player.
                                       chat.AddText(Color(255, 251, 0), "[" .. string.upper(consoleInfo["name"]) .. "]: ", Color(255, 255, 255, 255), callingPlayer:GetName() .. " has downloaded '" .. consoleInfo["fileName"] .. ".sys'")
                                   end)
                                   hook.Add("Think", "downloadServerFile", function()
                                       if(timer.Exists("DownloadServerFile")) then
                                           local timeLeft = math.Round(timer.TimeLeft("DownloadServerFile"), 2) -- Sets the time left = to 2 decimal places (aesthetics)
                                           serverInputTerminal:SetEditable(false) -- Prevents the player typing in the box once the countdown has started
                                           serverInputTerminal:SetText("")
                                           if(timeLeft > 0.01) then
                                            serverInputTerminal:SetPlaceholderColor(Color(36, 209, 36, 255))
                                            serverInputTerminal:SetPlaceholderText("Time to download: " .. timeLeft .. " seconds") -- Counts down for the player
                                           end 
                                       end
                                   
                                   end)
                               end
                           end
                           if(string.lower(serverInputTerminal:GetValue()) != "/d" .. acceptedFolders[2] .. "/" .. consoleInfo["fileName"] .. ".sys" and string.lower(serverInputTerminal:GetValue()) != "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2]) then
                            serverInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                            serverInputTerminal:SetText("")
                            serverInputTerminal:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                            end
                       end

                   end

                   if(string.lower(inputTerminal2:GetValue()) == "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3]) then

                       timer.Stop("secondPageGlitch") -- Removes the glitch effect so errors aren't thrown
                       timer.Stop("secondPageReturn") -- Removes the glitch effect so errors aren't thrown

                       -- Creates the parent frame that we can close
                       insideTools = vgui.Create("DFrame")
                       insideTools:SetPos(0, 0)
                       insideTools:SetSize(ScrW(), ScrH())
                       insideTools:MakePopup()
                       insideTools:SetDraggable(false)
                       insideTools:SetTitle("")
                       insideTools:ShowCloseButton(false)
                       function insideTools.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 0))
                       end


                       -- Set the background image for the hacking UI
                       local toolsBackgroundImage = vgui.Create("DImage", insideTools)
                       toolsBackgroundImage:SetSize(ScrW(), ScrH())
                       toolsBackgroundImage:SetPos(0, 0)
                       toolsBackgroundImage:SetImage("vgui/consoleframe1.png")
                       -- Creates the glitch effect for the console background
                       timer.Create("dataPageGlitch", math.random(lowerBound, upperBound), 0, function()
                           toolsBackgroundImage:SetImage("vgui/consoleframe2.png")
                           timer.Create("dataPageReturn", 0.5, 1, function()
                               toolsBackgroundImage:SetImage("vgui/consoleframe1.png")
                           end)
                       end)

                       local findFileLabel5 = vgui.Create("DLabel", insideTools)
                       findFileLabel5:SetFont("FolderFont")
                       findFileLabel5:SetText("Locate file '" .. consoleInfo["fileName"] .. "'")
                       findFileLabel5:SetSize(findFileLabel5:GetTextSize())
                       findFileLabel5:SetTextColor(Color(255, 0, 0, 255))
                       findFileLabel5:SetPos((ScrW()/2) - findFileLabel5:GetTextSize()/2, 105)


                       -- Prints the console identifier to the top
                       local toolsNameLabel = vgui.Create("DLabel", insideTools)
                       toolsNameLabel:SetFont("FolderFont")
                       toolsNameLabel:SetText(consoleInfo["name"] .. "/" .. acceptedFolders[3])
                       toolsNameLabel:SetPos(0, 0)
                       toolsNameLabel:SetSize(ScrW(), 100)
                       toolsNameLabel:SetContentAlignment(5)

                       -- Paints the banner
                       function toolsNameLabel.Paint(self, w, h)
                           draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 150))
                       end  

                       if(consoleInfo["fileType"] == "tools") then
                           local toolsRequiredFile = vgui.Create("DTextEntry", insideTools)
                           toolsRequiredFile:SetSize(300, 100)
                           toolsRequiredFile:Center()
                           toolsRequiredFile:SetFont("HackingFont")
                           toolsRequiredFile:SetText(string.upper(consoleInfo["fileName"]) .. ".exe")
                           toolsRequiredFile:SetEditable(false)

                           local randomFile1 = vgui.Create("DTextEntry", insideTools)
                           randomFile1:SetSize(300, 100)
                           randomFile1:SetPos(toolsRequiredFile:GetX(), toolsRequiredFile:GetY() - 100)
                           randomFile1:SetFont("HackingFont")
                           for k, v in pairs(filenames) do
                               if v != consoleInfo["fileName"] then
                                   randomFile1:SetText(v .. ".exe")
                                   table.RemoveByValue(filenames, v)
                               end
                           end

                           local randomFile2 = vgui.Create("DTextEntry", insideTools)
                           randomFile2:SetSize(300, 100)
                           randomFile2:SetPos(toolsRequiredFile:GetX(), toolsRequiredFile:GetY() + 100)
                           randomFile2:SetFont("HackingFont")
                           for k, v in pairs(filenames) do
                               if v != consoleInfo["fileName"] then
                                   randomFile2:SetText(v .. ".sys")
                                   table.RemoveByValue(filenames, v)
                               end
                           end
                       else
                           local randomFile1 = vgui.Create("DTextEntry", insideTools)
                           randomFile1:SetSize(300, 100)
                           randomFile1:Center()
                           randomFile1:SetFont("HackingFont")
                           randomFile1:SetEditable(false)
                           randomFile1:SetText("mainControl.exe")

                           local randomFile2 = vgui.Create("DTextEntry", insideTools)
                           randomFile2:SetSize(300, 100)
                           randomFile2:SetPos(randomFile1:GetX(), randomFile1:GetY() - 100)
                           randomFile2:SetFont("HackingFont")
                           randomFile2:SetEditable(false)
                           randomFile2:SetText("washingMachine.exe")

                           local randomFile3 = vgui.Create("DTextEntry", insideTools)
                           randomFile3:SetSize(300, 100)
                           randomFile3:SetPos(randomFile1:GetX(), randomFile1:GetY() + 100)
                           randomFile3:SetFont("HackingFont")
                           randomFile3:SetEditable(false)
                           randomFile3:SetText("breathing.exe")
                       end

                       secondPage:Hide()

                       -- Creates the access terminal
                       local toolsInputTerminal = vgui.Create("DTextEntry", insideTools)
                       toolsInputTerminal:SetFont("HackingFont")
                       toolsInputTerminal:SetPlaceholderText("Run Commands Here...")
                       toolsInputTerminal:SetPlaceholderColor(Color(140, 140, 140, 220))
                       toolsInputTerminal:SetSize(ScrW(), 100)
                       toolsInputTerminal:SetPos(5, ScrH()-100)
                       toolsInputTerminal:SetTextColor(Color(36, 209, 36, 255))
                       toolsInputTerminal:SetPaintBackground(false)
                       toolsInputTerminal:SetCursorColor(Color(36, 209, 36, 255))

                       toolsInputTerminal.OnGetFocus = function(self) -- Clears the text when the player clicks on the box
                           self:SetPlaceholderText("")
                       end

                       toolsInputTerminal.OnLoseFocus = function(self)
                           self:SetPlaceholderText("Run Commands Here...")
                           self:SetPlaceholderColor(Color(140, 140, 140, 220))
                       end

                       function toolsInputTerminal.OnEnter()

                        surface.PlaySound("code_enter.wav")

                           if(string.lower(toolsInputTerminal:GetValue()) == "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3]) then
                               insideTools:Remove()
                               insideTools = nil
                               timer.Remove("dataPageGlitch")
                               timer.Remove("dataPageReturn")

                               -- Resets the input terminal
                               inputTerminal2:SetPlaceholderText("Run Commands Here...")
                               inputTerminal2:SetPlaceholderColor(Color(140, 140, 140, 220))
                               inputTerminal2:SetText("")
                               inputTerminal2:SetTextColor(Color(36, 209, 36, 255))
                               timer.Start("secondPageGlitch")
                               secondPage:Show() -- Shows the previous page
                               return
                           end
                           if(string.lower(toolsInputTerminal:GetValue()) == "/r" .. acceptedFolders[3] .. "/" .. consoleInfo["fileName"] .. ".exe") then
                               if(consoleInfo["fileType"] == "tools") then
                                   closeConsoleUI()

                                   net.Start("PlayerActivatedDoor")
                                       net.WriteEntity(usedConsole) -- Allows us to delete the console on server side
                                   net.SendToServer()

                                   -- chat.AddText already targets the local player.
                                   chat.AddText(Color(255, 251, 0), "[" .. string.upper(consoleInfo["name"]) .. "]: ", Color(255, 255, 255, 255), callingPlayer:GetName() .. " has executed '" .. consoleInfo["fileName"] .. ".exe'")
                                   return
                               end
                           end
                           if(string.lower(toolsInputTerminal:GetValue()) != "//[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3] and string.lower(toolsInputTerminal:GetValue()) != "/r" .. acceptedFolders[3] .. "/" .. consoleInfo["fileName"] .. ".exe") then
                            toolsInputTerminal:SetPlaceholderColor(Color(255, 0, 0, 255))
                            toolsInputTerminal:SetText("")
                            toolsInputTerminal:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                            end
                       end
                   end

                   -- Quits the console
                   if(string.lower(inputTerminal2:GetValue()) == "/q[" .. consoleInfo["name"] .. "]") then
                       closeConsoleUI()
                       net.Start("playerQuitConsole")
                            net.WriteEntity(callingPlayer)
                            net.WriteEntity(usedConsole)
                        net.SendToServer()
                        return
                   end

                   -- Runs an error message for input terminal 2
                   if(string.lower(inputTerminal2:GetValue()) != "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[3] and string.lower(inputTerminal2:GetValue()) != "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[2] and string.lower(inputTerminal2:GetValue()) != "/a[" .. consoleInfo["name"] .. "]/" .. acceptedFolders[1] and string.lower(inputTerminal2:GetValue()) != "/q[" .. consoleInfo["name"] .. "]") then
                    inputTerminal2:SetPlaceholderColor(Color(255, 0, 0, 255))
                    inputTerminal2:SetText("")
                    inputTerminal2:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
                    end
               end

           end) 

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code creates the countdown timer for the initial access
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
            hook.Add("Think", "printDelay", function() -- Runs this function every tick of the server
                if(timer.Exists("AccessDelay")) then
                    local timeLeft = math.Round(timer.TimeLeft("AccessDelay"), 2) -- Sets the time left = to 2 decimal places (aesthetics)
                    inputTerminal1:SetEditable(false) -- Prevents the player typing in the box once the countdown has started
                    inputTerminal1:SetText("")
                    if(timeLeft > 0.01) then
                        inputTerminal1:SetPlaceholderColor(Color(36, 209, 36, 255))
                        inputTerminal1:SetPlaceholderText("Time to access: " .. timeLeft .. " seconds") -- Counts down for the player
                    end
                    if(timeLeft <= 0.01) then
                        inputTerminal1:SetPlaceholderColor(Color(36, 209, 36, 255))
                        inputTerminal1:SetPlaceholderText("Access Granted") -- Counts down for the player
                    end
                end
            end)
        end

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code runs an error command if they inputs dont match the required values
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        if(string.lower(inputTerminal1:GetValue()) != "/a[" .. consoleInfo["name"] .. "]" and string.lower(inputTerminal1:GetValue()) != "/q[" .. consoleInfo["name"] .. "]") then
            inputTerminal1:SetPlaceholderColor(Color(255, 0, 0, 255))
            inputTerminal1:SetText("")
            inputTerminal1:SetPlaceholderText("[ERROR] - INCORRECT COMMAND")
        end

    end
else
    callingPlayer:ChatPrint("This console is being used by someone else")
end
end)

   

-- END OF HACKING UI

--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code creates a UI for the player if they try to access a locked door
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
local printPanel = true

net.Receive("PlayerAlert", function()

    if(printPanel == true) then
        local alertMessage = vgui.Create("DLabel")
        alertMessage:SetFont("FolderFont")
        alertMessage:SetText("This door is locked. Find a console to open it.")
        alertMessage:SetTextColor(Color(255, 0, 0, 255))
        alertMessage:SetSize(ScrW(), 100)
        alertMessage:SetPos(0, ScrH() - 100)
        alertMessage:SetContentAlignment(5)

        function alertMessage.Paint(self, w, h)
            draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 20, 200))
        end

        printPanel = false

        timer.Create("removeAlert", 4, 1, function()
            alertMessage:Remove()
            printPanel = true
        end)
    end
    
end)


--[[/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
PURPOSE

This code closes the UI if the player has died while in the console
--]]/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
net.Receive("PlayerDied", closeConsoleUI)

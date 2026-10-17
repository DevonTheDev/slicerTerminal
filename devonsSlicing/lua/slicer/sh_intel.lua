-- Shared validation only. Authored bodies and awarded records live server-side.
function normalizeSlicerIntel(value)
    if type(value) ~= "string" then return nil, "Mission intel must be plain text." end
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    if #value > 4096 then return nil, "Mission intel exceeds 4096 bytes. Shorten it before saving." end
    local position = 1
    while position <= #value do
        local first, second = value:byte(position, position + 1)
        if first == 0 or (first < 32 and first ~= 9 and first ~= 10) or first == 127
            or (first == 194 and second and second >= 128 and second <= 159) then
            return nil, "Mission intel contains a control character. Only tabs and newlines are allowed."
        end
        local width = first < 128 and 1 or (first >= 194 and first <= 223 and 2)
            or (first >= 224 and first <= 239 and 3) or (first >= 240 and first <= 244 and 4)
        if not width or position + width - 1 > #value then
            return nil, "Mission intel must contain valid UTF-8 text."
        end
        for offset = 1, width - 1 do
            local byte = value:byte(position + offset)
            if byte < 128 or byte > 191 then return nil, "Mission intel must contain valid UTF-8 text." end
        end
        if (first == 224 and second < 160) or (first == 237 and second > 159)
            or (first == 240 and second < 144) or (first == 244 and second > 143) then
            return nil, "Mission intel must contain valid UTF-8 text."
        end
        position = position + width
    end
    if value:match("^[ \t\n]*$") then return "" end
    return value
end

function validSlicerIntelAward(value)
    return type(value) == "string" and #value <= 16 and value:match("^[1-9]%d*$") ~= nil
        and (#value < 16 or value <= "9007199254740991")
end

-- Archive metadata is a display projection only. Never normalize or rewrite
-- the private award or the existing latest-intel payload.
function slicerIntelArchiveName(value)
    if type(value) ~= "string" or #value > 128 or value:find("[%z\1-\31\127]") then
        return "[name unavailable]"
    end
    -- The body validator checks UTF-8 and C1 controls. Its whitespace-only
    -- return value is irrelevant here: safe edge spaces remain byte-exact.
    if normalizeSlicerIntel(value) == nil then return "[name unavailable]" end
    return value
end

-- Receive lengths already exclude the engine's message-name header. Read a
-- bounded application payload once, then require actual NULs and exact cursor
-- consumption. A missing empty string is never mistaken for a present field.
function slicerIntelArchiveReadPacket(bitLength, maximumBytes)
    if type(bitLength) ~= "number" or bitLength ~= bitLength or bitLength < 0
        or bitLength % 8 ~= 0 or bitLength > maximumBytes * 8 then return end
    local size = bitLength / 8
    local ok, bytes = pcall(net.ReadData, size)
    if not ok or type(bytes) ~= "string" or #bytes ~= size then return end
    local cursor = {position = 1, size = size, failed = false}
    function cursor:byte()
        if self.failed or self.position > self.size then self.failed = true; return end
        local value = bytes:byte(self.position)
        self.position = self.position + 1
        return value
    end
    function cursor:string(cap)
        if self.failed then return end
        local ending = bytes:find("\0", self.position, true)
        if not ending or ending - self.position > cap then self.failed = true; return end
        local value = bytes:sub(self.position, ending - 1)
        self.position = ending + 1
        return value
    end
    function cursor:done()
        return not self.failed and self.position == self.size + 1
    end
    return cursor
end

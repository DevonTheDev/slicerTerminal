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

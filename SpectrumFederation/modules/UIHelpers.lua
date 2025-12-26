-- Grab the namespace
local addonName, SF = ...

-- Helper function to create a tooltip for a button or frame
-- @param frame: The frame to attach the tooltip to
-- @param title: The tooltip title text (required)
-- @param lines: Optional array of additional tooltip lines
-- @return: none
function SF:CreateTooltip(frame, title, lines)
    if not title then
        if SF.Debug then
            SF.Debug:Warn("UI_HELPERS", "CreateTooltip called without a title")
        end
        return
    end
    
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if lines then
            for _, line in ipairs(lines) do
                GameTooltip:AddLine(line, nil, nil, nil, true)
            end
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

-- Helper function to create a horizontal line texture
-- @param parent: The parent frame
-- @param width: Optional width (defaults to 100)
-- @param height: Optional height (defaults to 1)
-- @param r: Red color component (0-1)
-- @param g: Green color component (0-1)
-- @param b: Blue color component (0-1)
-- @param a: Alpha transparency (0-1)
-- @return: The created texture
function SF:CreateHorizontalLine(parent, width, height, r, g, b, a)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(r or 0.5, g or 0.5, b or 0.5, a or 1)
    line:SetHeight(height or 1)
    if width then
        line:SetWidth(width)
    end
    return line
end

-- Helper function to create a section title with horizontal lines
-- @param parent: The parent frame
-- @param titleText: The title text to display
-- @param anchorFrame: The frame to anchor below
-- @param yOffset: Vertical offset from anchor (negative = below)
-- @return: Table with {title, leftLine, rightLine, UpdateLines function}
function SF:CreateSectionTitle(parent, titleText, anchorFrame, yOffset)
    yOffset = yOffset or -20
    
    -- Create title text
    local title = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    title:SetPoint("TOP", anchorFrame, "BOTTOM", 0, yOffset)
    title:SetText(titleText)
    
    -- Create horizontal lines
    local leftLine = self:CreateHorizontalLine(parent)
    leftLine:SetPoint("RIGHT", title, "LEFT", -10, 0)
    
    local rightLine = self:CreateHorizontalLine(parent)
    rightLine:SetPoint("LEFT", title, "RIGHT", 10, 0)
    
    -- Function to update line widths dynamically
    local function UpdateLines()
        local panelWidth = parent:GetWidth()
        if panelWidth and panelWidth > 0 then
            local totalWidth = panelWidth * 0.90
            local textWidth = title:GetStringWidth()
            local lineWidth = (totalWidth - textWidth - 20) / 2  -- 20 is the total gap (10 on each side)
            if lineWidth > 0 then
                leftLine:SetWidth(lineWidth)
                rightLine:SetWidth(lineWidth)
            end
        end
    end
    
    return {
        title = title,
        leftLine = leftLine,
        rightLine = rightLine,
        UpdateLines = UpdateLines
    }
end

-- Helper function to create a button with icon textures
-- @param parent: The parent frame
-- @param size: Button size (width and height)
-- @param normalTexture: Path to normal texture
-- @param highlightTexture: Path to highlight texture
-- @param pushedTexture: Path to pushed texture
-- @return: The created button frame
function SF:CreateIconButton(parent, size, normalTexture, highlightTexture, pushedTexture)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)
    button:SetNormalTexture(normalTexture)
    button:SetHighlightTexture(highlightTexture)
    button:SetPushedTexture(pushedTexture or normalTexture)
    return button
end

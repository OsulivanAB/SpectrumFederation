-- modules/UI/VersionCheck/Window.lua
local addonName, SF = ...

-- luacheck: globals CreateFrame UIParent UIPanelCloseButton C_Timer

SF.VersionCheckWindow = SF.VersionCheckWindow or {}
local Window = SF.VersionCheckWindow

local C = {
	FRAME_NAME = "SpectrumFederationVersionWindow",
	TITLE_HEIGHT = 28,
	TITLE_PADDING_X = 10,
	CONTENT_PADDING = 10,
	DEFAULT_POINT = "CENTER",
	DEFAULT_RELATIVE_POINT = "CENTER",
	DEFAULT_X = 0,
	DEFAULT_Y = 0,
	DEFAULT_WIDTH = 380,
	DEFAULT_HEIGHT = 460,
	MIN_WIDTH = 280,
	MIN_HEIGHT = 220,
	MAX_WIDTH = 720,
	MAX_HEIGHT = 860,
	LOGO_SIZE = 18,
	ICON_BUTTON_SIZE = 20,
	RESIZE_HANDLE_SIZE = 16,
	RESIZE_HANDLE_GAP = 6,
	SCROLLBAR_GAP = 6,
	ROW_HEIGHT = 24,
	ROW_SPACING = 2,
	CLASS_ICON_SIZE = 20,
	STATUS_ICON_SIZE = 16,
	VERSION_WIDTH = 110,
	HEADER_HEIGHT = 18,
	STATUS_HEIGHT = 18,
	MISSING_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}

local LISTENER_KEY = (SF.VersionCheck and SF.VersionCheck.WINDOW_LISTENER_KEY) or "version_window"

local function Clamp(v, minV, maxV)
	v = tonumber(v) or minV
	if v < minV then return minV end
	if v > maxV then return maxV end
	return v
end

local function Round(v)
	v = tonumber(v) or 0
	return math.floor(v + 0.5)
end

local function GetClassIcon(className)
	local token = type(className) == "string" and className:upper() or nil
	if token and SF.WOW_CLASSES and SF.WOW_CLASSES[token] and SF.WOW_CLASSES[token].textureFile then
		return SF.WOW_CLASSES[token].textureFile
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

function Window:_GetWindowStateTable()
	SpectrumFederationDB = SpectrumFederationDB or {}
	SpectrumFederationDB.versionWindow = SpectrumFederationDB.versionWindow or {}
	return SpectrumFederationDB.versionWindow
end

function Window:_ApplyResizeBounds(frame)
	if not frame then return end

	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(C.MIN_WIDTH, C.MIN_HEIGHT, C.MAX_WIDTH, C.MAX_HEIGHT)
	else
		if frame.SetMinResize then frame:SetMinResize(C.MIN_WIDTH, C.MIN_HEIGHT) end
		if frame.SetMaxResize then frame:SetMaxResize(C.MAX_WIDTH, C.MAX_HEIGHT) end
	end
end

function Window:ClampSizeToBounds()
	local f = self._frame
	if not f then return end

	local w, h = f:GetSize()
	f:SetSize(Clamp(w, C.MIN_WIDTH, C.MAX_WIDTH), Clamp(h, C.MIN_HEIGHT, C.MAX_HEIGHT))
end

function Window:EnsureOnScreen()
	local f = self._frame
	if not f then return end

	local uiW = UIParent:GetWidth()
	local uiH = UIParent:GetHeight()
	if not uiW or not uiH or uiW <= 0 or uiH <= 0 then return end

	local left, right, top, bottom = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
	if not left or not right or not top or not bottom then return end

	if left < 0 or right > uiW or bottom < 0 or top > uiH then
		f:ClearAllPoints()
		f:SetPoint(C.DEFAULT_POINT, UIParent, C.DEFAULT_RELATIVE_POINT, C.DEFAULT_X, C.DEFAULT_Y)
	end
end

function Window:LoadState()
	local f = self._frame
	if not f then return end

	local st = self:_GetWindowStateTable()
	local w = Clamp(st.width or C.DEFAULT_WIDTH, C.MIN_WIDTH, C.MAX_WIDTH)
	local h = Clamp(st.height or C.DEFAULT_HEIGHT, C.MIN_HEIGHT, C.MAX_HEIGHT)
	f:SetSize(w, h)

	local point = st.point or C.DEFAULT_POINT
	local relativePoint = st.relativePoint or C.DEFAULT_RELATIVE_POINT
	local x = tonumber(st.x) or C.DEFAULT_X
	local y = tonumber(st.y) or C.DEFAULT_Y
	f:ClearAllPoints()
	f:SetPoint(point, UIParent, relativePoint, x, y)

	if SF.Debug then
		SF.Debug:Verbose("VERSION_CHECK", "LoadState: size=%dx%d, position=%s->%s at (%d,%d)", w, h, point, relativePoint, x, y)
	end

	if C_Timer and C_Timer.After then
		C_Timer.After(0, function()
			self:EnsureOnScreen()
		end)
	else
		self:EnsureOnScreen()
	end
end

function Window:SaveState()
	local f = self._frame
	if not f then return end

	self:ClampSizeToBounds()

	local st = self:_GetWindowStateTable()
	local w, h = f:GetSize()
	local point, _, relPoint, x, y = f:GetPoint(1)

	st.width = Round(w)
	st.height = Round(h)
	st.point = point or C.DEFAULT_POINT
	st.relativePoint = relPoint or C.DEFAULT_RELATIVE_POINT
	st.x = Round(x)
	st.y = Round(y)

	if SF.Debug then
		SF.Debug:Verbose("VERSION_CHECK", "SaveState: size=%dx%d, position=%s->%s at (%d,%d)", st.width, st.height, st.point, st.relativePoint, st.x, st.y)
	end
end

function Window:RequestScrollInsetsUpdate()
	local f = self._frame
	if not f then return end
	if f.__sfScrollInsetsScheduled then return end
	f.__sfScrollInsetsScheduled = true

	local function Run()
		local f2 = self._frame
		if not f2 then return end
		f2.__sfScrollInsetsScheduled = false
		self:UpdateScrollInsets()
	end

	if C_Timer and C_Timer.After then
		C_Timer.After(0, Run)
	else
		Run()
	end
end

function Window:UpdateScrollInsets()
	local f = self._frame
	if not f or not f.Content or not f.Content.Scroll then return end

	local content = f.Content
	local scroll = content.Scroll
	local sb = scroll.ScrollBar

	local range = 0
	if scroll.GetVerticalScrollRange then
		range = scroll:GetVerticalScrollRange() or 0
	end
	local needScroll = range > 0.5

	if sb then
		sb:SetShown(needScroll)
	end
	if not needScroll and scroll.SetVerticalScroll then
		scroll:SetVerticalScroll(0)
	end

	local rightInset = 0
	if needScroll and sb then
		local sbw = sb:GetWidth() or 0
		if sbw < 16 then sbw = 20 end
		rightInset = sbw + C.SCROLLBAR_GAP
	end

	local bottomInset = 0
	if f.ResizeHandle and f.ResizeHandle:IsShown() then
		bottomInset = (f.ResizeHandle:GetHeight() or C.RESIZE_HANDLE_SIZE) + C.RESIZE_HANDLE_GAP
	end

	local topInset = C.HEADER_HEIGHT
	local status = content.StatusText
	if status and status:IsShown() then
		bottomInset = bottomInset + C.STATUS_HEIGHT
	end

	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -topInset)
	scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -rightInset, bottomInset)

	if scroll.GetVerticalScroll and scroll.SetVerticalScroll and scroll.GetVerticalScrollRange then
		local cur = scroll:GetVerticalScroll() or 0
		local maxRange = scroll:GetVerticalScrollRange() or 0
		if cur > maxRange then
			scroll:SetVerticalScroll(maxRange)
		end
	end
end

function Window:_EnsureRow(index)
	self._rows = self._rows or {}
	if self._rows[index] then
		return self._rows[index]
	end

	local child = self._frame.Content.Child
	local row = CreateFrame("Frame", nil, child)
	row:SetHeight(C.ROW_HEIGHT)

	local highlight = row:CreateTexture(nil, "BACKGROUND")
	highlight:SetAllPoints(row)
	highlight:SetColorTexture(1, 1, 1, 0.03)
	row.Highlight = highlight

	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetSize(C.CLASS_ICON_SIZE, C.CLASS_ICON_SIZE)
	icon:SetPoint("LEFT", row, "LEFT", 4, 0)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.Icon = icon

	local missing = row:CreateTexture(nil, "ARTWORK")
	missing:SetSize(C.STATUS_ICON_SIZE, C.STATUS_ICON_SIZE)
	missing:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	missing:SetTexture(C.MISSING_TEXTURE)
	row.Missing = missing

	local version = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	version:SetJustifyH("RIGHT")
	version:SetWidth(C.VERSION_WIDTH)
	version:SetWordWrap(false)
	version:SetMaxLines(1)
	version:SetPoint("RIGHT", missing, "LEFT", -4, 0)
	row.Version = version

	local name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	name:SetMaxLines(1)
	name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
	name:SetPoint("RIGHT", version, "LEFT", -8, 0)
	row.Name = name

	self._rows[index] = row
	self:_ApplyRowStyle(row)
	return row
end

function Window:_ApplyRowStyle(row)
	if not row then return end
	if not (self._fontPath and self._fontSize) then return end
	if row.Name and row.Name.SetFont then
		row.Name:SetFont(self._fontPath, self._fontSize, "")
	end
	if row.Version and row.Version.SetFont then
		row.Version:SetFont(self._fontPath, math.max(8, self._fontSize - 1), "")
	end
end

function Window:ApplyStyle()
	local f = self._frame
	if not f then return end

	local style = SF.LootHelperWindow and SF.LootHelperWindow.Style
	if style and style.ApplyWindowStyle then
		style:ApplyWindowStyle(f)
	end

	if style and style.ResolveFont then
		self._fontPath, self._fontSize = style:ResolveFont()
	end

	if self._fontPath and self._fontSize then
		if f.Title and f.Title.Text and f.Title.Text.SetFont then
			f.Title.Text:SetFont(self._fontPath, self._fontSize + 1, "OUTLINE")
		end
		if f.Content and f.Content.HeaderName and f.Content.HeaderName.SetFont then
			f.Content.HeaderName:SetFont(self._fontPath, math.max(8, self._fontSize - 1), "")
		end
		if f.Content and f.Content.HeaderVersion and f.Content.HeaderVersion.SetFont then
			f.Content.HeaderVersion:SetFont(self._fontPath, math.max(8, self._fontSize - 1), "")
		end
		if f.Content and f.Content.StatusText and f.Content.StatusText.SetFont then
			f.Content.StatusText:SetFont(self._fontPath, math.max(8, self._fontSize - 1), "")
		end
		if f.Content and f.Content.EmptyText and f.Content.EmptyText.SetFont then
			f.Content.EmptyText:SetFont(self._fontPath, self._fontSize, "")
		end
	end

	for _, row in ipairs(self._rows or {}) do
		self:_ApplyRowStyle(row)
	end
end

function Window:_SetStatusText(text)
	local f = self._frame
	if not f or not f.Content or not f.Content.StatusText then return end
	f.Content.StatusText:SetText(text or "")
end

function Window:Refresh()
	local f = self._frame
	if not f or not f.Content then return end

	local snapshot = (SF.VersionCheck and SF.VersionCheck.GetSnapshot and SF.VersionCheck:GetSnapshot()) or {
		rows = {},
		checking = false,
		knownCount = 0,
		totalCount = 0,
		ownVersion = "Unknown",
	}

	if f.Title and f.Title.Text then
		f.Title.Text:SetText("Addon Versions")
	end

	local rows = snapshot.rows or {}
	local child = f.Content.Child
	local y = -2

	if f.Content.EmptyText then
		if #rows == 0 then
			f.Content.EmptyText:SetText("No group members to display.")
			f.Content.EmptyText:Show()
		else
			f.Content.EmptyText:Hide()
		end
	end

	for i, model in ipairs(rows) do
		local row = self:_EnsureRow(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
		row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
		row:Show()

		if row.Icon then
			row.Icon:SetTexture(GetClassIcon(model.class))
		end
		if row.Name then
			row.Name:SetText(model.displayName or model.name or "Unknown")
		end

		local missing = model.status == "missing"
		if row.Missing then
			row.Missing:SetShown(missing)
		end
		if row.Version then
			if missing then
				row.Version:SetText("")
				row.Version:SetTextColor(0.9, 0.25, 0.25)
			elseif model.status == "checking" and not model.version then
				row.Version:SetText("Checking...")
				row.Version:SetTextColor(0.72, 0.72, 0.72)
			else
				row.Version:SetText(model.version or "")
				row.Version:SetTextColor(0.92, 0.92, 0.92)
			end
		end

		y = y - C.ROW_HEIGHT - C.ROW_SPACING
	end

	for i = #rows + 1, #(self._rows or {}) do
		self._rows[i]:Hide()
	end

	local contentHeight = math.max(1, (#rows * (C.ROW_HEIGHT + C.ROW_SPACING)) + 4)
	local contentWidth = (f.Content.Scroll and f.Content.Scroll:GetWidth()) or 1
	child:SetSize(math.max(1, contentWidth), contentHeight)

	if snapshot.checking then
		self:_SetStatusText("Checking who is running Spectrum Federation...")
	else
		self:_SetStatusText(string.format("%d of %d running Spectrum Federation", snapshot.knownCount or 0, snapshot.totalCount or 0))
	end

	self:RequestScrollInsetsUpdate()
end

function Window:Create()
	if self._frame then
		return self._frame
	end

	if SF.Debug then
		SF.Debug:Info("VERSION_CHECK", "Creating addon version window")
	end

	local frame = CreateFrame("Frame", C.FRAME_NAME, UIParent, "BackdropTemplate")
	frame:SetSize(C.DEFAULT_WIDTH, C.DEFAULT_HEIGHT)
	frame:SetPoint(C.DEFAULT_POINT, UIParent, C.DEFAULT_RELATIVE_POINT, C.DEFAULT_X, C.DEFAULT_Y)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:Hide()
	self:_ApplyResizeBounds(frame)

	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 12,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.60)
	frame:SetBackdropBorderColor(0.65, 0.65, 0.65, 0.65)

	local title = CreateFrame("Frame", nil, frame)
	title:SetHeight(C.TITLE_HEIGHT)
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
	title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
	title:EnableMouse(true)
	title:RegisterForDrag("LeftButton")
	title:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	title:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		Window:SaveState()
	end)
	frame.Title = title

	local titleBG = title:CreateTexture(nil, "BACKGROUND")
	titleBG:SetAllPoints(title)
	titleBG:SetColorTexture(0.08, 0.08, 0.08, 0.85)
	title.BG = titleBG

	local logo = title:CreateTexture(nil, "ARTWORK")
	logo:SetSize(C.LOGO_SIZE, C.LOGO_SIZE)
	logo:SetPoint("LEFT", title, "LEFT", C.TITLE_PADDING_X, 0)
	logo:SetTexture("Interface\\AddOns\\SpectrumFederation\\media\\Icons\\SpectrumFederationIcon.tga")
	title.Logo = logo

	local close = CreateFrame("Button", nil, title, "UIPanelCloseButton")
	close:SetPoint("RIGHT", title, "RIGHT", -4, 0)
	close:SetSize(C.ICON_BUTTON_SIZE, C.ICON_BUTTON_SIZE)
	close:SetScript("OnClick", function()
		Window:Hide()
	end)
	title.Close = close

	local titleText = title:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	titleText:SetPoint("LEFT", logo, "RIGHT", 8, 0)
	titleText:SetPoint("RIGHT", close, "LEFT", -8, 0)
	titleText:SetJustifyH("LEFT")
	titleText:SetWordWrap(false)
	titleText:SetMaxLines(1)
	titleText:SetText("Addon Versions")
	title.Text = titleText

	local content = CreateFrame("Frame", nil, frame)
	content:SetPoint("TOPLEFT", frame, "TOPLEFT", C.CONTENT_PADDING, -(C.TITLE_HEIGHT + C.CONTENT_PADDING + 6))
	content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -C.CONTENT_PADDING, C.CONTENT_PADDING)
	frame.Content = content

	local headerName = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	headerName:SetPoint("TOPLEFT", content, "TOPLEFT", 4, 0)
	headerName:SetText("Name")
	headerName:SetTextColor(0.65, 0.78, 0.95, 0.95)
	content.HeaderName = headerName

	local headerVersion = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	headerVersion:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, 0)
	headerVersion:SetText("Version")
	headerVersion:SetTextColor(0.65, 0.78, 0.95, 0.95)
	content.HeaderVersion = headerVersion

	local statusText = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	statusText:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 4, 0)
	statusText:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -20, 0)
	statusText:SetJustifyH("LEFT")
	statusText:SetText("")
	content.StatusText = statusText

	local scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
	content.Scroll = scroll
	scroll:HookScript("OnScrollRangeChanged", function()
		Window:RequestScrollInsetsUpdate()
	end)

	local child = CreateFrame("Frame", nil, scroll)
	child:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)
	content.Child = child

	local emptyText = child:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	emptyText:SetPoint("TOPLEFT", child, "TOPLEFT", 10, -10)
	emptyText:SetPoint("RIGHT", child, "RIGHT", -10, 0)
	emptyText:SetJustifyH("LEFT")
	emptyText:SetJustifyV("TOP")
	emptyText:SetText("")
	emptyText:Hide()
	content.EmptyText = emptyText

	if scroll.HookScript then
		scroll:HookScript("OnSizeChanged", function()
			local w = scroll:GetWidth() or 1
			child:SetWidth(math.max(1, w))
			Window:RequestScrollInsetsUpdate()
		end)
	end

	local resize = CreateFrame("Button", nil, frame)
	resize:SetSize(C.RESIZE_HANDLE_SIZE, C.RESIZE_HANDLE_SIZE)
	resize:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -2, -2)
	resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	resize:SetScript("OnMouseDown", function(_, button)
		if button ~= "LeftButton" then return end
		frame:StartSizing("BOTTOMRIGHT")
	end)
	resize:SetScript("OnMouseUp", function(_, button)
		if button ~= "LeftButton" then return end
		frame:StopMovingOrSizing()
		Window:ClampSizeToBounds()
		Window:SaveState()
		Window:RequestScrollInsetsUpdate()
	end)
	frame.ResizeHandle = resize

	frame:HookScript("OnSizeChanged", function()
		Window:RequestScrollInsetsUpdate()
	end)

	self._frame = frame
	self._rows = {}
	self:LoadState()
	self:ApplyStyle()
	self:RequestScrollInsetsUpdate()
	return frame
end

function Window:IsShown()
	return self._frame and self._frame:IsShown() and true or false
end

function Window:Show()
	self:Create()
	self:ApplyStyle()

	if SF.VersionCheck then
		if SF.VersionCheck.RegisterListener then
			SF.VersionCheck:RegisterListener(LISTENER_KEY, function()
				if Window:IsShown() then
					Window:Refresh()
				end
			end)
		end
		if SF.VersionCheck.RequestRefresh then
			SF.VersionCheck:RequestRefresh("window_show")
		end
	end

	self._frame:Show()
	self:Refresh()

	if SF.Debug then
		SF.Debug:Info("VERSION_CHECK", "Opened addon version window")
	end
end

function Window:Hide()
	if SF.VersionCheck and SF.VersionCheck.UnregisterListener then
		SF.VersionCheck:UnregisterListener(LISTENER_KEY)
	end
	if self._frame then
		self:SaveState()
		self._frame:Hide()
	end
end

function Window:Toggle()
	if self:IsShown() then
		self:Hide()
	else
		self:Show()
	end
end

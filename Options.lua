---------------------------------------------------------------------
-- Options.lua: 图形设置面板（/mynav 或 /mynav config 打开）
---------------------------------------------------------------------
-- 把所有可调项都收进暴雪设置界面（界面 → 插件 → MyNavigate）：
--   启用导航 / 弹窗独占 / 显示动作提示框 / 调试输出 / 白名单、黑名单与按钮黑名单增删
-- 样式沿用暴雪标准设置面板（GameFontNormalLarge + UICheckButtonTemplate +
-- UIPanelButtonTemplate），输入框用 tooltip 边框，与插件的整体观感一致。
---------------------------------------------------------------------
local ADDON, ns = ...

local ACCENT = '|cff739BD0'   -- 插件聊天提示里统一使用的强调色

local panel = CreateFrame('Frame', 'MyNavigateOptionsPanel', UIParent)
panel.name = 'MyNavigate'

-- 设置项较多、内容会超出面板高度，所以放进滚动子帧：右侧会有滚动条
local scroll = CreateFrame('ScrollFrame', 'MyNavigateOptionsScroll', panel, 'UIPanelScrollFrameTemplate')
scroll:SetPoint('TOPLEFT', panel, 'TOPLEFT', 6, -6)
scroll:SetPoint('BOTTOMRIGHT', panel, 'BOTTOMRIGHT', -30, 6)

local content = CreateFrame('Frame', nil, scroll)
content:SetWidth(460)
content:SetHeight(500)
scroll:SetScrollChild(content)

local title = content:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
title:SetPoint('TOPLEFT', 16, -16)
title:SetText('MyNavigate 手柄导航设置')

local desc = content:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
desc:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -8)
desc:SetText('方向键在窗口内移动光标，ABXY 执行动作。下面可以开关功能、设置按键、维护窗口名单与按钮黑名单。')

---------------------------------------------------------------------
-- 复选框生成器（文字用自己创建的 FontString，兼容无名 checkbutton）
---------------------------------------------------------------------
local function CreateCheck(parent, labelText, key, tooltip, onChange)
	local cb = CreateFrame('CheckButton', nil, parent, 'UICheckButtonTemplate')
	cb:SetSize(24, 24)
	local text = cb:CreateFontString(nil, 'ARTWORK', 'GameFontNormal')
	text:SetPoint('LEFT', cb, 'RIGHT', 4, 0)
	text:SetText(labelText)
	-- 让点击文字也能切换勾选
	cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
	cb.text = text
	cb.key = key
	cb:SetScript('OnClick', function(self)
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB[key] = self:GetChecked() and true or false
		if onChange then onChange(MyNavigateDB[key]) end
	end)
	if tooltip then
		cb:SetScript('OnEnter', function(self)
			GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
			GameTooltip:AddLine(tooltip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		cb:SetScript('OnLeave', function() GameTooltip:Hide() end)
	end
	return cb
end

local cbEnabled = CreateCheck(content, '启用导航', 'enabled',
	'关闭后不再接管 1~8 键，它们回到各自的原始绑定', function(on)
		if on then
			ns.Cursor:Refresh()
		else
			ns.navActive = false
			if ns.SetGamepadOverride then ns.SetGamepadOverride(false) end
			ns.Cursor:HideNode()
		end
	end)
cbEnabled:SetPoint('TOPLEFT', desc, 'BOTTOMLEFT', 0, -16)

local cbExclusive = CreateCheck(content, '弹窗 / 下拉独占', 'exclusive',
	'屏幕上出现弹窗或下拉菜单时，只导航它们，忽略其背后的窗口', function()
		ns.Cursor:Refresh()
	end)
cbExclusive:SetPoint('TOPLEFT', cbEnabled, 'BOTTOMLEFT', 0, -6)

local cbHint = CreateCheck(content, '显示动作提示框', 'hint',
	'在光标旁的提示框里显示四个动作键当前的功能', function()
		ns.Cursor:Refresh()
	end)
cbHint:SetPoint('TOPLEFT', cbExclusive, 'BOTTOMLEFT', 0, -6)

local cbDebug = CreateCheck(content, '调试输出', 'debug',
	'在聊天框打印扫描到的面板与节点，便于排查', function(on)
		if on then
			ns.DumpFrames()
			ns.Cursor:Refresh()
		end
	end)
cbDebug:SetPoint('TOPLEFT', cbHint, 'BOTTOMLEFT', 0, -6)

---------------------------------------------------------------------
-- 按键设置：捕获手柄物理键，默认值为当前值
---------------------------------------------------------------------
local keyTitle = content:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
keyTitle:SetPoint('TOPLEFT', cbDebug, 'BOTTOMLEFT', 0, -20)
keyTitle:SetText('按键设置')

local keyHint = content:CreateFontString(nil, 'ARTWORK', 'GameFontHighlight')
keyHint:SetPoint('TOPLEFT', keyTitle, 'BOTTOMLEFT', 0, -8)
keyHint:SetJustifyH('LEFT')
keyHint:SetText('点一下按钮，再直接按下手柄对应的物理键即可（按 ESC 取消）。')

local keyButtons = {}
local function CreateKeyButton(parent, action, labelText)
	local frame = CreateFrame('Frame', nil, parent)
	frame:SetSize(160, 42)

	local label = frame:CreateFontString(nil, 'ARTWORK', 'GameFontNormal')
	label:SetPoint('TOPLEFT', 0, 0)
	label:SetText(labelText)

	local btn = CreateFrame('Button', nil, frame, 'UIPanelButtonTemplate')
	btn:SetSize(120, 22)
	btn:SetPoint('TOPLEFT', label, 'BOTTOMLEFT', 0, -3)
	btn:SetText(ns.GetKey(action))

	btn:SetScript('OnClick', function(self)
		self:SetText('请按下按键...')
		self:EnableKeyboard(true)
	end)
	btn:SetScript('OnKeyDown', function(self, key)
		if key == 'ESCAPE' then
			self:SetText(ns.GetKey(action))
			self:EnableKeyboard(false)
			return
		end
		-- 过滤单独按下的修饰键
		if key == 'LSHIFT' or key == 'RSHIFT' or key == 'LCTRL' or key == 'RCTRL'
			or key == 'LALT' or key == 'RALT' then
			return
		end
		-- 支持组合键（如 SHIFT-ENTER）
		local finalKey = key
		if IsShiftKeyDown() then finalKey = 'SHIFT-' .. finalKey end
		if IsControlKeyDown() then finalKey = 'CTRL-' .. finalKey end
		if IsAltKeyDown() then finalKey = 'ALT-' .. finalKey end

		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB.keys = MyNavigateDB.keys or {}
		MyNavigateDB.keys[action] = finalKey
		self:SetText(finalKey)
		self:EnableKeyboard(false)
		if ns.RefreshBindings then ns.RefreshBindings() end
	end)

	frame.btn = btn
	frame.action = action
	keyButtons[#keyButtons + 1] = frame
	return frame
end

-- 方向键一列
local kbUp = CreateKeyButton(content, 'UP', '上:')
kbUp:SetPoint('TOPLEFT', keyHint, 'BOTTOMLEFT', 0, -10)
local kbDown = CreateKeyButton(content, 'DOWN', '下:')
kbDown:SetPoint('TOPLEFT', kbUp, 'BOTTOMLEFT', 0, -2)
local kbLeft = CreateKeyButton(content, 'LEFT', '左:')
kbLeft:SetPoint('TOPLEFT', kbDown, 'BOTTOMLEFT', 0, -2)
local kbRight = CreateKeyButton(content, 'RIGHT', '右:')
kbRight:SetPoint('TOPLEFT', kbLeft, 'BOTTOMLEFT', 0, -2)

-- 动作键一列
local kbA = CreateKeyButton(content, 'A', 'A (左键):')
kbA:SetPoint('TOPLEFT', kbUp, 'TOPRIGHT', 24, 0)
local kbB = CreateKeyButton(content, 'B', 'B (右键):')
kbB:SetPoint('TOPLEFT', kbA, 'BOTTOMLEFT', 0, -2)
local kbX = CreateKeyButton(content, 'X', 'X (左键):')
kbX:SetPoint('TOPLEFT', kbB, 'BOTTOMLEFT', 0, -2)
local kbY = CreateKeyButton(content, 'Y', 'Y (特殊):')
kbY:SetPoint('TOPLEFT', kbX, 'BOTTOMLEFT', 0, -2)

---------------------------------------------------------------------
-- 滚动键：窗口内长列表翻页，默认 PageUp / PageDown
---------------------------------------------------------------------
local scrollTitle = content:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
scrollTitle:SetPoint('TOPLEFT', kbRight, 'BOTTOMLEFT', 0, -20)
scrollTitle:SetText('滚动按键')

local scrollHint = content:CreateFontString(nil, 'ARTWORK', 'GameFontHighlight')
scrollHint:SetPoint('TOPLEFT', scrollTitle, 'BOTTOMLEFT', 0, -8)
scrollHint:SetJustifyH('LEFT')
scrollHint:SetText('窗口打开时用它翻动长列表（默认 PageUp / PageDown，可改）。')

local kbScrollUp = CreateKeyButton(content, 'SCROLLUP', '上翻:')
kbScrollUp:SetPoint('TOPLEFT', scrollHint, 'BOTTOMLEFT', 0, -10)
local kbScrollDown = CreateKeyButton(content, 'SCROLLDOWN', '下翻:')
kbScrollDown:SetPoint('TOPLEFT', kbScrollUp, 'TOPRIGHT', 24, 0)

---------------------------------------------------------------------
-- 名单区块（导航白名单 / 黑名单共用一套 UI）
---------------------------------------------------------------------
local function Trim(text)
	return (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function RefreshCursor() ns.Cursor:Refresh() end

-- 内容帧高度随实际内容变化（最后一个名单区块的列表会随条目数变高）
local lastListFrame
local function UpdateContentHeight()
	local top = content:GetTop()
	local bottom = lastListFrame and lastListFrame:GetBottom()
	if top and bottom then
		content:SetHeight((top - bottom) + 24)
	end
end

-- 生成一个「名字列表」区块：标题 + 说明 + 输入框 + 增删按钮 + 可点选列表
-- cfg = { key = 存档字段, title = 区块标题, listLabel = 列表标题, hint = 说明, emptyText = 空列表提示 }
local function CreateListSection(parent, anchor, cfg)
	local key = cfg.key

	local title = parent:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
	title:SetPoint('TOPLEFT', anchor, 'BOTTOMLEFT', 0, -24)
	title:SetText(cfg.title)

	local hint = parent:CreateFontString(nil, 'ARTWORK', 'GameFontHighlight')
	hint:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -8)
	hint:SetJustifyH('LEFT')
	hint:SetText(cfg.hint)

	local nameBox = CreateFrame('EditBox', nil, parent)
	nameBox:SetSize(160, 24)
	nameBox:SetPoint('TOPLEFT', hint, 'BOTTOMLEFT', 0, -12)
	nameBox:SetFontObject('ChatFontNormal')
	nameBox:SetAutoFocus(false)
	nameBox:SetTextInsets(5, 5, 0, 0)
	nameBox:SetBackdrop({
		bgFile = 'Interface\\ChatFrame\\ChatFrameBackground',
		edgeFile = 'Interface\\Tooltips\\UI-Tooltip-Border',
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	nameBox:SetBackdropColor(0, 0, 0, 0.8)
	nameBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	nameBox:SetScript('OnEscapePressed', function(self) self:ClearFocus() end)

	-- 列表标题行 + 「删除选中」按钮
	local listHead = parent:CreateFontString(nil, 'ARTWORK', 'GameFontHighlight')
	listHead:SetPoint('TOPLEFT', nameBox, 'BOTTOMLEFT', 0, -14)
	listHead:SetJustifyH('LEFT')
	listHead:SetText(ACCENT .. cfg.listLabel .. '|r')

	local listHint = parent:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
	listHint:SetPoint('TOPLEFT', listHead, 'BOTTOMLEFT', 0, -6)
	listHint:SetJustifyH('LEFT')
	listHint:SetText('点击条目即可选中（再点一次取消），选中后点「删除选中」移除。')

	local delBtn = CreateFrame('Button', nil, parent, 'UIPanelButtonTemplate')
	delBtn:SetSize(88, 22)
	delBtn:SetPoint('LEFT', listHead, 'RIGHT', 10, 0)
	delBtn:SetText('删除选中')
	delBtn:Disable()

	-- 条目列表：每行是一个可点选的按钮，选中时显示淡蓝色底纹
	local listFrame = CreateFrame('Frame', nil, parent)
	listFrame:SetPoint('TOPLEFT', listHint, 'BOTTOMLEFT', 0, -8)
	listFrame:SetWidth(444)
	listFrame:SetHeight(18)

	local rows, selected = {}, nil
	local UpdateList

	local function AcquireRow(i)
		local row = rows[i]
		if not row then
			row = CreateFrame('Button', nil, listFrame)
			row:SetHeight(18)
			row:SetHighlightTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight')
			local text = row:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
			text:SetPoint('LEFT', 6, 0)
			text:SetJustifyH('LEFT')
			row.text = text
			local sel = row:CreateTexture(nil, 'BACKGROUND')
			sel:SetTexture('Interface\\Buttons\\WHITE8X8')
			sel:SetVertexColor(0.45, 0.61, 0.82, 0.35)
			sel:SetAllPoints(row)
			sel:Hide()
			row.sel = sel
			row:SetScript('OnClick', function(self)
				if not self.entryName then return end
				selected = (selected == self.entryName) and nil or self.entryName
				UpdateList()
			end)
			rows[i] = row
		end
		return row
	end

	UpdateList = function()
		local data = MyNavigateDB and MyNavigateDB[key]
		local names = {}
		if data then
			for name in pairs(data) do names[#names + 1] = name end
		end
		table.sort(names)
		-- 选中项已被删掉时清掉选中状态
		if selected and not (data and data[selected]) then selected = nil end

		local n = #names
		if n == 0 then
			local row = AcquireRow(1)
			row.entryName = nil
			row.text:SetText(cfg.emptyText)
			row.sel:Hide()
			row:ClearAllPoints()
			row:SetPoint('TOPLEFT', listFrame, 'TOPLEFT', 0, 0)
			row:SetPoint('RIGHT', listFrame, 'RIGHT', 0, 0)
			row:Show()
			for i = 2, #rows do rows[i]:Hide() end
			listFrame:SetHeight(18)
		else
			for i = 1, n do
				local row = AcquireRow(i)
				row.entryName = names[i]
				row.text:SetText(names[i])
				if selected == names[i] then row.sel:Show() else row.sel:Hide() end
				row:ClearAllPoints()
				if i == 1 then
					row:SetPoint('TOPLEFT', listFrame, 'TOPLEFT', 0, 0)
				else
					row:SetPoint('TOPLEFT', rows[i - 1], 'BOTTOMLEFT', 0, -2)
				end
				row:SetPoint('RIGHT', listFrame, 'RIGHT', 0, 0)
				row:Show()
			end
			for i = n + 1, #rows do rows[i]:Hide() end
			listFrame:SetHeight(n * 18 + (n - 1) * 2)
		end
		if selected then delBtn:Enable() else delBtn:Disable() end
		UpdateContentHeight()
	end

	local addBtn = CreateFrame('Button', nil, parent, 'UIPanelButtonTemplate')
	addBtn:SetSize(64, 22)
	addBtn:SetPoint('LEFT', nameBox, 'RIGHT', 8, 0)
	addBtn:SetText('添加')
	addBtn:SetScript('OnClick', function()
		local name = Trim(nameBox:GetText())
		if name == '' then return end
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB[key] = MyNavigateDB[key] or {}
		MyNavigateDB[key][name] = true
		nameBox:SetText('')
		nameBox:ClearFocus()
		UpdateList()
		RefreshCursor()
	end)

	local removeBtn = CreateFrame('Button', nil, parent, 'UIPanelButtonTemplate')
	removeBtn:SetSize(64, 22)
	removeBtn:SetPoint('LEFT', addBtn, 'RIGHT', 6, 0)
	removeBtn:SetText('移除')
	removeBtn:SetScript('OnClick', function()
		local name = Trim(nameBox:GetText())
		if name == '' or not (MyNavigateDB and MyNavigateDB[key]) then return end
		MyNavigateDB[key][name] = nil
		nameBox:SetText('')
		nameBox:ClearFocus()
		UpdateList()
		RefreshCursor()
	end)

	local clearBtn = CreateFrame('Button', nil, parent, 'UIPanelButtonTemplate')
	clearBtn:SetSize(64, 22)
	clearBtn:SetPoint('LEFT', removeBtn, 'RIGHT', 6, 0)
	clearBtn:SetText('清空')
	clearBtn:SetScript('OnClick', function()
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB[key] = {}
		selected = nil
		UpdateList()
		RefreshCursor()
	end)

	-- 删除选中：移除列表中选中的条目
	delBtn:SetScript('OnClick', function()
		if not selected or not (MyNavigateDB and MyNavigateDB[key]) then return end
		MyNavigateDB[key][selected] = nil
		selected = nil
		UpdateList()
		RefreshCursor()
	end)

	-- 在输入框里回车 = 添加
	nameBox:SetScript('OnEnterPressed', function(self)
		addBtn:GetScript('OnClick')(addBtn)
		self:ClearFocus()
	end)

	return { listFrame = listFrame, update = UpdateList }
end

-- 自定义白名单
local wlSection = CreateListSection(content, kbScrollUp, {
	key = 'extra',
	title = '导航白名单',
	listLabel = '当前自定义白名单：',
	hint = '输入窗口名即可让它成为导航目标（用 /fstack 查看名字，内置白名单已覆盖常见窗口）。',
	emptyText = '（暂无，可在上方输入后点「添加」）',
})
lastListFrame = wlSection.listFrame

-- 自定义黑名单：优先级高于白名单，用来彻底排除某些窗口
local blSection = CreateListSection(content, wlSection.listFrame, {
	key = 'black',
	title = '导航黑名单',
	listLabel = '当前自定义黑名单：',
	hint = '输入窗口名即可把它排除在导航之外（也可用 /mynav unpick 鼠标选取，优先级高于白名单）。',
	emptyText = '（暂无，可在上方输入后点「添加」）',
})
lastListFrame = blSection.listFrame

-- 按钮黑名单：窗口内部的控件（例如不叫 close 的关闭按钮），导航时直接跳过
local nbSection = CreateListSection(content, blSection.listFrame, {
	key = 'nodeBlack',
	title = '导航按钮黑名单',
	listLabel = '当前按钮黑名单：',
	hint = '输入控件帧名即可在导航时跳过它（也可用 /mynav skip 鼠标选取，用 /mynav tree 查名字）。',
	emptyText = '（暂无，可在上方输入后点「添加」）',
})
lastListFrame = nbSection.listFrame

-- 滚动帧尺寸变化时（面板拉伸 / 分辨率变化）重算内容宽度与高度
scroll:SetScript('OnSizeChanged', function(self, width)
	content:SetWidth(width)
	wlSection.listFrame:SetWidth(width - 16)
	blSection.listFrame:SetWidth(width - 16)
	nbSection.listFrame:SetWidth(width - 16)
	UpdateContentHeight()
end)

panel:SetScript('OnShow', function()
	MyNavigateDB = MyNavigateDB or {}
	-- 内容宽度跟随滚动帧，滚动条回到顶部
	content:SetWidth(scroll:GetWidth())
	wlSection.listFrame:SetWidth(scroll:GetWidth() - 16)
	blSection.listFrame:SetWidth(scroll:GetWidth() - 16)
	nbSection.listFrame:SetWidth(scroll:GetWidth() - 16)
	scroll:SetVerticalScroll(0)
	cbEnabled:SetChecked(MyNavigateDB.enabled ~= false)
	cbExclusive:SetChecked(MyNavigateDB.exclusive ~= false)
	cbHint:SetChecked(MyNavigateDB.hint ~= false)
	cbDebug:SetChecked(MyNavigateDB.debug == true)
	for i = 1, #keyButtons do
		keyButtons[i].btn:SetText(ns.GetKey(keyButtons[i].action))
	end
	wlSection.update()
	blSection.update()
	nbSection.update()
end)

if InterfaceOptions_AddCategory then
	InterfaceOptions_AddCategory(panel)
end

-- 打开设置面板（3.3.5 需要调用两次才能正确定位到本面板）
function ns.OpenOptions()
	if not InterfaceOptionsFrame_OpenToCategory then return end
	InterfaceOptionsFrame_OpenToCategory(panel)
	InterfaceOptionsFrame_OpenToCategory(panel)
end

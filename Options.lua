---------------------------------------------------------------------
-- Options.lua: 图形设置面板（/mynav 或 /mynav config 打开）
---------------------------------------------------------------------
-- 把所有可调项都收进暴雪设置界面（界面 → 插件 → MyNavigate）：
--   启用导航 / 弹窗独占 / 显示动作提示框 / 调试输出 / 自定义白名单增删
-- 样式沿用暴雪标准设置面板（GameFontNormalLarge + UICheckButtonTemplate +
-- UIPanelButtonTemplate），输入框用 tooltip 边框，与插件的整体观感一致。
---------------------------------------------------------------------
local ADDON, ns = ...

local NL = string.char(10)
local ACCENT = '|cff739BD0'   -- 插件聊天提示里统一使用的强调色

local panel = CreateFrame('Frame', 'MyNavigateOptionsPanel', UIParent)
panel.name = 'MyNavigate'

local title = panel:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
title:SetPoint('TOPLEFT', 16, -16)
title:SetText('MyNavigate 手柄导航设置')

local desc = panel:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
desc:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -8)
desc:SetText('方向键在窗口内移动光标，ABXY 执行动作。下面可以开关功能、设置按键、维护白名单。')

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

local cbEnabled = CreateCheck(panel, '启用导航', 'enabled',
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

local cbExclusive = CreateCheck(panel, '弹窗 / 下拉独占', 'exclusive',
	'屏幕上出现弹窗或下拉菜单时，只导航它们，忽略其背后的窗口', function()
		ns.Cursor:Refresh()
	end)
cbExclusive:SetPoint('TOPLEFT', cbEnabled, 'BOTTOMLEFT', 0, -6)

local cbHint = CreateCheck(panel, '显示动作提示框', 'hint',
	'在光标旁的提示框里显示四个动作键当前的功能', function()
		ns.Cursor:Refresh()
	end)
cbHint:SetPoint('TOPLEFT', cbExclusive, 'BOTTOMLEFT', 0, -6)

local cbDebug = CreateCheck(panel, '调试输出', 'debug',
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
local keyTitle = panel:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
keyTitle:SetPoint('TOPLEFT', cbDebug, 'BOTTOMLEFT', 0, -20)
keyTitle:SetText('按键设置')

local keyHint = panel:CreateFontString(nil, 'ARTWORK', 'GameFontHighlight')
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
local kbUp = CreateKeyButton(panel, 'UP', '上:')
kbUp:SetPoint('TOPLEFT', keyHint, 'BOTTOMLEFT', 0, -10)
local kbDown = CreateKeyButton(panel, 'DOWN', '下:')
kbDown:SetPoint('TOPLEFT', kbUp, 'BOTTOMLEFT', 0, -2)
local kbLeft = CreateKeyButton(panel, 'LEFT', '左:')
kbLeft:SetPoint('TOPLEFT', kbDown, 'BOTTOMLEFT', 0, -2)
local kbRight = CreateKeyButton(panel, 'RIGHT', '右:')
kbRight:SetPoint('TOPLEFT', kbLeft, 'BOTTOMLEFT', 0, -2)

-- 动作键一列
local kbA = CreateKeyButton(panel, 'A', 'A (左键):')
kbA:SetPoint('TOPLEFT', kbUp, 'TOPRIGHT', 24, 0)
local kbB = CreateKeyButton(panel, 'B', 'B (右键):')
kbB:SetPoint('TOPLEFT', kbA, 'BOTTOMLEFT', 0, -2)
local kbX = CreateKeyButton(panel, 'X', 'X (左键):')
kbX:SetPoint('TOPLEFT', kbB, 'BOTTOMLEFT', 0, -2)
local kbY = CreateKeyButton(panel, 'Y', 'Y (特殊):')
kbY:SetPoint('TOPLEFT', kbX, 'BOTTOMLEFT', 0, -2)

---------------------------------------------------------------------
-- 自定义白名单
---------------------------------------------------------------------
local listTitle = panel:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
listTitle:SetPoint('TOPLEFT', kbRight, 'BOTTOMLEFT', 0, -24)
listTitle:SetText('导航白名单')

local listHint = panel:CreateFontString(nil, 'ARTWORK', 'GameFontHighlight')
listHint:SetPoint('TOPLEFT', listTitle, 'BOTTOMLEFT', 0, -8)
listHint:SetJustifyH('LEFT')
listHint:SetText('输入窗口名即可让它成为导航目标（用 /fstack 查看名字，内置白名单已覆盖常见窗口）。')

local nameBox = CreateFrame('EditBox', nil, panel)
nameBox:SetSize(160, 24)
nameBox:SetPoint('TOPLEFT', listHint, 'BOTTOMLEFT', 0, -12)
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

local listText = panel:CreateFontString(nil, 'ARTWORK', 'GameFontHighlight')
listText:SetPoint('TOPLEFT', nameBox, 'BOTTOMLEFT', 0, -14)
listText:SetJustifyH('LEFT')

local function Trim(text)
	return (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function UpdateList()
	local str = ACCENT .. '当前自定义白名单：|r' .. NL
	local extra = MyNavigateDB and MyNavigateDB.extra
	local n = 0
	if extra then
		for name in pairs(extra) do
			n = n + 1
			str = str .. '  ' .. name .. NL
		end
	end
	if n == 0 then str = str .. '  （暂无，可在上方输入后点「添加」）' end
	listText:SetText(str)
end

local function RefreshCursor() ns.Cursor:Refresh() end

local addBtn = CreateFrame('Button', nil, panel, 'UIPanelButtonTemplate')
addBtn:SetSize(64, 22)
addBtn:SetPoint('LEFT', nameBox, 'RIGHT', 8, 0)
addBtn:SetText('添加')
addBtn:SetScript('OnClick', function()
	local name = Trim(nameBox:GetText())
	if name == '' then return end
	MyNavigateDB = MyNavigateDB or {}
	MyNavigateDB.extra = MyNavigateDB.extra or {}
	MyNavigateDB.extra[name] = true
	nameBox:SetText('')
	nameBox:ClearFocus()
	UpdateList()
	RefreshCursor()
end)

local removeBtn = CreateFrame('Button', nil, panel, 'UIPanelButtonTemplate')
removeBtn:SetSize(64, 22)
removeBtn:SetPoint('LEFT', addBtn, 'RIGHT', 6, 0)
removeBtn:SetText('移除')
removeBtn:SetScript('OnClick', function()
	local name = Trim(nameBox:GetText())
	if name == '' or not (MyNavigateDB and MyNavigateDB.extra) then return end
	MyNavigateDB.extra[name] = nil
	nameBox:SetText('')
	nameBox:ClearFocus()
	UpdateList()
	RefreshCursor()
end)

local clearBtn = CreateFrame('Button', nil, panel, 'UIPanelButtonTemplate')
clearBtn:SetSize(64, 22)
clearBtn:SetPoint('LEFT', removeBtn, 'RIGHT', 6, 0)
clearBtn:SetText('清空')
clearBtn:SetScript('OnClick', function()
	MyNavigateDB = MyNavigateDB or {}
	MyNavigateDB.extra = {}
	UpdateList()
	RefreshCursor()
end)

-- 在输入框里回车 = 添加
nameBox:SetScript('OnEnterPressed', function(self)
	addBtn:GetScript('OnClick')(addBtn)
	self:ClearFocus()
end)

panel:SetScript('OnShow', function()
	MyNavigateDB = MyNavigateDB or {}
	cbEnabled:SetChecked(MyNavigateDB.enabled ~= false)
	cbExclusive:SetChecked(MyNavigateDB.exclusive ~= false)
	cbHint:SetChecked(MyNavigateDB.hint ~= false)
	cbDebug:SetChecked(MyNavigateDB.debug == true)
	for i = 1, #keyButtons do
		keyButtons[i].btn:SetText(ns.GetKey(keyButtons[i].action))
	end
	UpdateList()
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

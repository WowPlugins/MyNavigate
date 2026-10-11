local ADDON, ns = ...

local KEY = ns.KEY
KEY.STATE_UP = 'up'
KEY.STATE_DOWN = 'down'

MyNavigate = ns

local DIRECTION_KEYS = { UP = KEY.UP, DOWN = KEY.DOWN, LEFT = KEY.LEFT, RIGHT = KEY.RIGHT }

local IGNORE = {
	MyNavigateCursor = true, GameTooltip = true, ItemRefTooltip = true,
	ShoppingTooltip1 = true, ShoppingTooltip2 = true, UIErrorsFrame = true,
	ZoneTextFrame = true, SubZoneTextFrame = true, WorldFrame = true,
}
for i = 1, 10 do IGNORE['ChatFrame'..i] = true end

function ns.GetRootFrames()
	local roots = {}
	for _, frame in ipairs({ UIParent:GetChildren() }) do
		local name = frame.GetName and frame:GetName()
		if frame:IsVisible() and not (name and IGNORE[name]) then
			roots[#roots + 1] = frame
		end
	end
	return roots
end

function ns.DumpFrames()
	local kids = { UIParent:GetChildren() }
	ns.Debug('UIParent 子帧数', #kids)
	local named = 0
	for i = 1, #kids do
		local name = kids[i].GetName and kids[i]:GetName()
		if name then
			named = named + 1
			if named <= 40 then
				ns.Debug('  ', name, kids[i]:IsVisible() and 'shown' or 'hidden')
			end
		end
	end
	ns.Debug('命名子帧数', named)
end

function MyNavigate:OnDirection(name)
	local key = DIRECTION_KEYS[name]
	if key then ns.Cursor:UIControl(key, KEY.STATE_DOWN) end
end

function MyNavigate:OnAction(name)
	ns.Cursor:Action(name)
end

local DEFAULT_BINDS = {
	['SHIFT-1'] = 'MYNAV_UP', ['SHIFT-2'] = 'MYNAV_DOWN',
	['SHIFT-3'] = 'MYNAV_LEFT', ['SHIFT-4'] = 'MYNAV_RIGHT',
	['SHIFT-5'] = 'MYNAV_A', ['SHIFT-6'] = 'MYNAV_B',
	['SHIFT-7'] = 'MYNAV_X', ['SHIFT-8'] = 'MYNAV_Y',
}

local function ApplyBinds()
	for key, action in pairs(DEFAULT_BINDS) do SetBinding(key, action) end
	SaveBindings(GetCurrentBindingSet())
end

local function ClearBinds()
	for key in pairs(DEFAULT_BINDS) do SetBinding(key, nil) end
	SaveBindings(GetCurrentBindingSet())
end

local frame = CreateFrame('Frame')
frame:RegisterEvent('PLAYER_LOGIN')
frame:SetScript('OnEvent', function()
	MyNavigateDB = MyNavigateDB or {}
	if not MyNavigateDB.saved then
		MyNavigateDB.saved = {}
		for key in pairs(DEFAULT_BINDS) do
			MyNavigateDB.saved[key] = GetBindingAction(key)
		end
	end
	if MyNavigateDB.enabled == nil then MyNavigateDB.enabled = true end
	if MyNavigateDB.enabled then ApplyBinds() end
end)

local LABELS = {
	UP = '上', DOWN = '下', LEFT = '左', RIGHT = '右',
	A = 'A (左键)', B = 'B (右键)', X = 'X (左键)', Y = 'Y (特殊)',
}
_G['BINDING_HEADER_MYNAV'] = 'MyNavigate 导航'
_G['BINDING_HEADER_MYNAVACT'] = 'MyNavigate 动作'
for name in pairs({ MYNAV_UP = 1, MYNAV_DOWN = 1, MYNAV_LEFT = 1, MYNAV_RIGHT = 1,
	MYNAV_A = 1, MYNAV_B = 1, MYNAV_X = 1, MYNAV_Y = 1 }) do
	_G['BINDING_NAME_'..name] = LABELS[name:sub(7)] or name
end

SLASH_MYNAV1 = '/mynav'
SlashCmdList['MYNAV'] = function(msg)
	msg = (msg or ''):lower()
	if msg == 'on' then
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB.enabled = true
		ApplyBinds()
		print('|cff739BD0MyNavigate|r: 已开启 (Shift1-8)')
	elseif msg == 'off' then
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB.enabled = false
		ClearBinds()
		print('|cff739BD0MyNavigate|r: 已关闭')
	elseif msg == 'reset' then
		for key, old in pairs((MyNavigateDB or {}).saved or {}) do
			SetBinding(key, old ~= '' and old or nil)
		end
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB.saved = nil
		SaveBindings(GetCurrentBindingSet())
		print('|cff739BD0MyNavigate|r: 已恢复原始按键绑定')
	elseif msg == 'debug' then
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB.debug = not MyNavigateDB.debug
		print('|cff739BD0MyNavigate|r: 调试模式'..(MyNavigateDB.debug and '开启' or '关闭'))
		if MyNavigateDB.debug then
			ns.DumpFrames()
			ns.Cursor:Refresh()
		end
	elseif msg == 'dump' then
		MyNavigateDB = MyNavigateDB or {}
		MyNavigateDB.debug = true
		ns.DumpFrames()
	else
		print('|cff739BD0MyNavigate|r: /mynav on|off|debug|dump|reset')
	end
end
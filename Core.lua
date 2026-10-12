---------------------------------------------------------------------
-- Core.lua: 入口 —— 手柄按键拦截、窗口白名单、鼠标选取、斜杠命令
---------------------------------------------------------------------
-- 导航根节点只从「白名单窗口」里取（内置 PANEL_PATTERNS + 用户自定义 extra），
-- 所以一个窗口都不开时不会扫到常驻 HUD，也就不会高亮它们。
---------------------------------------------------------------------
local ADDON, ns = ...

local KEY = ns.KEY
KEY.STATE_UP = 'up'
KEY.STATE_DOWN = 'down'

MyNavigate = ns

local DIRECTION_KEYS = { UP = KEY.UP, DOWN = KEY.DOWN, LEFT = KEY.LEFT, RIGHT = KEY.RIGHT }

-- 可导航窗口白名单（Lua 模式匹配）。
-- 只有名字匹配这些模式的「可见窗口」才会成为导航根节点。
-- 常驻 HUD（动作条、小地图、单位框体等）不在名单内，因此一个窗口都不开时
-- 不会高亮任何东西，也不会把光标跳到 HUD 上。
local PANEL_PATTERNS = {
	-- 背包 / 银行（含 Combuctor 第三方背包）
	'^ContainerFrame%d+$', '^BankFrame$', '^GuildBankFrame$',
	'^CombuctorFrame%d+$', '^CombuctorItem%d+$',
	-- 角色 / 技能 / 天赋 / 声望
	'^CharacterFrame$', '^SpellBookFrame$', '^PlayerTalentFrame$',
	'^SkillsFrame$', '^InspectFrame$',
	-- 任务 / 对话 / 商贩
	'^QuestLogFrame$', '^QuestLogPopupDetailFrame$', '^QuestFrame$',
	'^GossipFrame$', '^MerchantFrame$', '^QuestChoiceFrame$',
	-- 邮件 / 交易 / 制造
	'^MailFrame$', '^OpenMailFrame$', '^SendMailFrame$', '^InboxFrame$',
	'^TradeFrame$', '^TradeSkillFrame$', '^CraftFrame$',
	-- 社交 / 公会 / 团队
	'^FriendsFrame$', '^GuildFrame$', '^GuildInviteFrame$',
	'^WhoFrame$', '^RaidFrame$', '^RaidGroupFrame$',
	-- 地图 / 飞行 / 换装 / PVP / 地下城
	'^WorldMapFrame$', '^TaxiFrame$', '^DressUpFrame$',
	'^PVPFrame$', '^PVPParentFrame$', '^PVEFrame$', '^HonorFrame$',
	'^LFDParentFrame$', '^LFDQueueFrame$', '^LFDRoleCheckPopup$',
	'^LFGDungeonReadyDialog$', '^LFGInvitePopup$',
	-- 系统 / 设置 / 弹窗
	'^GameMenuFrame$', '^HelpFrame$', '^HelpMenuFrame$',
	'^InterfaceOptionsFrame$', '^VideoOptionsFrame$', '^AudioOptionsFrame$',
	'^KeyBindingFrame$', '^MacroFrame$', '^AddonList$',
	'^ChatConfigFrame$', '^ChatMenu$', '^TimeManagerFrame$',
	'^StaticPopup%d+$', '^DropDownList%d+$',
	-- 其它窗口
	'^ItemTextFrame$', '^ItemSocketingFrame$', '^PetitionFrame$',
	'^StableFrame$', '^TabardFrame$', '^BarberShopFrame$',
	'^StackSplitFrame$', '^CoinPickupFrame$', '^TutorialFrame$',
	'^ReadyCheckFrame$', '^SplashFrame$', '^AchievementFrame$',
}

local function MatchesPanel(name)
	for i = 1, #PANEL_PATTERNS do
		if name:find(PANEL_PATTERNS[i]) then return true end
	end
	local extra = MyNavigateDB and MyNavigateDB.extra
	return (extra and extra[name]) and true or false
end

function ns.IsNavigableRoot(frame)
	local name = frame.GetName and frame:GetName()
	if not name then return false end
	return MatchesPanel(name)
end

function ns.GetRootFrames()
	local roots = {}
	for _, frame in ipairs({ UIParent:GetChildren() }) do
		if frame:IsVisible() and ns.IsNavigableRoot(frame) then
			roots[#roots + 1] = frame
		end
	end
	return roots
end

function ns.DumpFrames(filter)
	filter = filter and filter:lower() or nil
	local kids = { UIParent:GetChildren() }
	ns.Debug('UIParent 子帧数', #kids)
	local listed, navigable = 0, 0
	for i = 1, #kids do
		local frame = kids[i]
		local name = frame.GetName and frame:GetName()
		local visible = frame:IsVisible()
		local isNav = name and ns.IsNavigableRoot(frame)
		-- 无关键词时只列出当前屏幕上可见的帧（避免刷屏）
		local hit = name and (filter and name:lower():find(filter, 1, true) or (not filter and visible))
		if hit then
			listed = listed + 1
			if isNav then navigable = navigable + 1 end
			ns.Debug('  ', name, visible and 'shown' or 'hidden', isNav and '可导航' or '')
		end
	end
	ns.Debug('列出', listed, '可导航', navigable)
end

-- 鼠标选取模式：点击屏幕上的窗口，自动把它加入导航白名单
local picker
local function GetRootFrame(f)
	while f do
		local parent = f.GetParent and f:GetParent()
		if not parent or parent == UIParent or parent == WorldFrame then
			return f
		end
		f = parent
	end
end

local function AddNavigable(frame)
	local name = frame and frame.GetName and frame:GetName()
	if not name then
		print('|cff739BD0MyNavigate|r: 这个窗口没有名字，无法加入，换个位置点')
		return false
	end
	if ns.IsNavigableRoot(frame) then
		print('|cff739BD0MyNavigate|r: '..name..' 已经在白名单里了')
		return true
	end
	MyNavigateDB = MyNavigateDB or {}
	MyNavigateDB.extra = MyNavigateDB.extra or {}
	MyNavigateDB.extra[name] = true
	print('|cff739BD0MyNavigate|r: 已加入导航白名单: '..name)
	ns.Cursor:Refresh()
	return true
end

-- 按光标位置在所有顶层窗口里做命中检测，取层叠顺序最上面的那个
local STRATA = {
	BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
	DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

local function FrameAtCursor()
	local cx, cy = GetCursorPosition()
	local us = UIParent:GetEffectiveScale()
	cx, cy = cx / us, cy / us
	local best, bestPri
	for _, f in ipairs({ UIParent:GetChildren() }) do
		local name = f.GetName and f:GetName()
		if name and name ~= 'WorldFrame' and name:sub(1, 10) ~= 'MyNavigate' and f:IsVisible() then
			local l, b, w, h = f:GetLeft(), f:GetBottom(), f:GetWidth(), f:GetHeight()
			if l and b and w and h and w > 0 and h > 0 then
				local fs = f:GetEffectiveScale() / us
				local l2, b2 = l * fs, b * fs
				local r2, t2 = l2 + w * fs, b2 + h * fs
				if cx >= l2 and cx <= r2 and cy >= b2 and cy <= t2 then
					local pri = (STRATA[f:GetFrameStrata()] or 0) * 100000 + f:GetFrameLevel()
					if not bestPri or pri > bestPri then best, bestPri = f, pri end
				end
			end
		end
	end
	return best
end

local function StartPick()
	if not picker then
		picker = CreateFrame('Frame', 'MyNavigatePicker', UIParent)
		picker:SetAllPoints(UIParent)
		picker:SetFrameStrata('FULLSCREEN_DIALOG')
		picker:EnableMouse(true)

		local bg = picker:CreateTexture(nil, 'BACKGROUND')
		bg:SetAllPoints(picker)
		bg:SetTexture(0, 0, 0, 0.35)

		local text = picker:CreateFontString(nil, 'OVERLAY')
		text:SetFont(STANDARD_TEXT_FONT or 'Fonts\\FRIZQT__.TTF', 16, 'OUTLINE')
		text:SetTextColor(1, 0.88, 0.1)
		text:SetPoint('TOP', picker, 'TOP', 0, -80)
		text:SetText('MyNavigate 选取模式：用鼠标左键点击要加入导航的窗口\n（ESC 取消）')

		-- 遮罩会挡住鼠标，所以先用 GetMouseFocus，取不到就用光标坐标做矩形命中检测
		picker:SetScript('OnMouseDown', function(self, button)
			if button ~= 'LeftButton' then return end
			self:Hide()
			local focus = GetMouseFocus()
			if not focus or focus == WorldFrame then
				focus = FrameAtCursor()
			end
			if not focus then
				print('|cff739BD0MyNavigate|r: 没取到鼠标下的窗口，请重试')
				return
			end
			AddNavigable(GetRootFrame(focus))
		end)

		picker:Hide()
		tinsert(UISpecialFrames, 'MyNavigatePicker')
	end
	MyNavigateDB = MyNavigateDB or {}
	picker:Show()
	print('|cff739BD0MyNavigate|r: 选取模式已开启，点击要加入导航的窗口')
end

-- 自动跟随窗口：白名单窗口的可见集合发生变化时自动刷新光标。
-- 打开窗口 → 光标直接落到该窗口的第一个节点；关闭窗口 → 自动收起或切到剩下的窗口。
local watcher = CreateFrame('Frame')
local watchTimer, shown = 0, {}
watcher:SetScript('OnUpdate', function(_, elapsed)
	watchTimer = watchTimer + elapsed
	if watchTimer < 0.2 then return end
	watchTimer = 0
	if MyNavigateDB and MyNavigateDB.enabled == false then
		ns.navActive = false
		if ns.SetGamepadOverride then ns.SetGamepadOverride(false) end
		return
	end
	local roots, cur, opened = ns.GetRootFrames(), {}, nil
	for i = 1, #roots do
		local name = roots[i]:GetName()
		if name then
			cur[name] = true
			if not shown[name] then opened = roots[i] end
		end
	end
	-- 集合有变化才刷新（新增窗口，或有关掉的窗口），避免每 0.2 秒重复扫描
	local changed = opened ~= nil
	if not changed then
		for name in pairs(shown) do
			if not cur[name] then
				changed = true
				break
			end
		end
	end
	shown = cur
	-- 手柄按键的接管由 Cursor:Refresh 依据「是否真有可导航节点」决定
	if changed then
		ns.Cursor:Refresh()
		if opened then ns.Cursor:SelectRoot(opened) end
	end
end)

---------------------------------------------------------------------
-- 手柄按键映射（参考 ConsolePortLK 的做法）
---------------------------------------------------------------------
-- 目标：有可导航窗口时 1~8 = 导航/动作；窗口全关后 1~8 = 原始功能。
-- 难点：战斗中不能临时改按键绑定（SetOverrideBinding 是受保护函数），所以
--       "随窗口开关切换绑定"的方案一旦窗口在战斗中打开/关闭就会失效。
-- 做法（与 ConsolePort 相同）：登录(非战斗)时把 1~8 常驻覆盖为 MYNAV_*，
--       之后不再改动；按键到底执行"导航"还是"原始功能"，改由按键处理器
--       MyNavigate:OnGamepadKey 在按下瞬间依据 ns.navActive 判断。绑定处理器
--       运行在安全环境，战斗中也能调用 UseAction 还原成动作条。
---------------------------------------------------------------------
-- 逻辑键 → 物理键 & 绑定名（硬编码）：方向 5/6/7/8，动作 X/B/Y/A 对应 1/2/3/4
local GAMEPAD = {
	UP    = { key = '5', bind = 'MYNAV_UP' },
	DOWN  = { key = '6', bind = 'MYNAV_DOWN' },
	LEFT  = { key = '7', bind = 'MYNAV_LEFT' },
	RIGHT = { key = '8', bind = 'MYNAV_RIGHT' },
	X     = { key = '1', bind = 'MYNAV_X' },
	B     = { key = '2', bind = 'MYNAV_B' },
	Y     = { key = '3', bind = 'MYNAV_Y' },
	A     = { key = '4', bind = 'MYNAV_A' },
}

local bindOwner = CreateFrame('Frame')   -- 覆盖绑定的归属帧（无需键盘）
local applied, desired = false, false    -- applied=已生效, desired=期望状态

ns.navActive = false   -- 是否处于导航模式（由 Cursor:Refresh 更新）
ns.origAction = {}     -- 逻辑键 → 覆盖前的原始绑定名（登录时记录）

local function ApplyOverride(on)
	if on then
		for _, info in pairs(GAMEPAD) do
			SetOverrideBinding(bindOwner, true, info.key, info.bind)
		end
	else
		ClearOverrideBindings(bindOwner)
	end
	applied = on
end

-- 常驻覆盖 1~8。战斗中不允许改动绑定，先记下期望值，出战斗后再补上
function ns.SetGamepadOverride(on)
	desired = on and true or false
	if not InCombatLockdown() and desired ~= applied then
		ApplyOverride(desired)
	end
end

bindOwner:RegisterEvent('PLAYER_REGEN_ENABLED')
bindOwner:SetScript('OnEvent', function()
	if desired ~= applied and not InCombatLockdown() then ApplyOverride(desired) end
end)

-- 按键统一入口：导航模式 → 导航/动作；否则还原成覆盖前的原始功能（动作条 1~8）
function MyNavigate:OnGamepadKey(name)
	if ns.navActive then
		local key = DIRECTION_KEYS[name]
		if key then ns.Cursor:UIControl(key, KEY.STATE_DOWN) else ns.Cursor:Action(name) end
		return
	end
	local orig = ns.origAction[name]
	local slot = orig and orig:match('^ACTIONBUTTON(%d+)$')
	if slot then pcall(UseAction, tonumber(slot)) end
end

local frame = CreateFrame('Frame')
frame:RegisterEvent('PLAYER_LOGIN')
frame:SetScript('OnEvent', function()
	MyNavigateDB = MyNavigateDB or {}
	if MyNavigateDB.enabled == nil then MyNavigateDB.enabled = true end
	-- 旧版本用 SetBinding 把 Shift1~8 绑到 MYNAV_*，现已改为固定按键拦截，
	-- 还原当时保存的原始绑定，避免残留占用
	if MyNavigateDB.saved then
		for key, old in pairs(MyNavigateDB.saved) do
			SetBinding(key, old ~= '' and old or nil)
		end
		MyNavigateDB.saved = nil
		SaveBindings(GetCurrentBindingSet())
	end
	-- 清掉误加入白名单的自己（例如 MyNavigatePicker）
	local extra = MyNavigateDB.extra
	if extra then
		for k in pairs(extra) do
			if k:sub(1, 10) == 'MyNavigate' then extra[k] = nil end
		end
	end
	-- 记录 1~8 覆盖前的原始绑定（必须在应用覆盖之前读取），供非导航时还原
	for name, info in pairs(GAMEPAD) do
		ns.origAction[name] = GetBindingAction(info.key)
	end
	-- 常驻覆盖 1~8 → MYNAV_*，之后由 OnGamepadKey 决定导航还是原始功能
	if MyNavigateDB.enabled ~= false then ns.SetGamepadOverride(true) end
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
	MyNavigateDB = MyNavigateDB or {}
	-- 只对命令名转小写，参数（帧名）保留原始大小写
	local cmd, arg = (msg or ''):match('^(%S*)%s*(.-)%s*$')
	cmd = cmd:lower()
	if arg == '' then arg = nil end
	if cmd == 'on' then
		MyNavigateDB.enabled = true
		if ns.SetGamepadOverride then ns.SetGamepadOverride(true) end
		print('|cff739BD0MyNavigate|r: 已开启（窗口打开时 1~8 键导航）')
	elseif cmd == 'off' then
		MyNavigateDB.enabled = false
		ns.navActive = false
		if ns.SetGamepadOverride then ns.SetGamepadOverride(false) end
		ns.Cursor:HideNode()
		print('|cff739BD0MyNavigate|r: 已关闭')
	elseif cmd == 'reset' then
		if MyNavigateDB.saved then
			for key, old in pairs(MyNavigateDB.saved) do
				SetBinding(key, old ~= '' and old or nil)
			end
			MyNavigateDB.saved = nil
			SaveBindings(GetCurrentBindingSet())
			print('|cff739BD0MyNavigate|r: 已恢复原始按键绑定')
		else
			print('|cff739BD0MyNavigate|r: 没有可恢复的原始按键记录')
		end
	elseif cmd == 'debug' then
		MyNavigateDB.debug = not MyNavigateDB.debug
		print('|cff739BD0MyNavigate|r: 调试模式'..(MyNavigateDB.debug and '开启' or '关闭'))
		if MyNavigateDB.debug then
			ns.DumpFrames()
			ns.Cursor:Refresh()
		end
	elseif cmd == 'dump' then
		MyNavigateDB.debug = true
		ns.DumpFrames(arg)
		ns.Cursor:Refresh()
	elseif cmd == 'add' then
		if arg then
			MyNavigateDB.extra = MyNavigateDB.extra or {}
			MyNavigateDB.extra[arg] = true
			print('|cff739BD0MyNavigate|r: 已加入导航白名单: '..arg)
			ns.Cursor:Refresh()
		else
			print('|cff739BD0MyNavigate|r: 用法 /mynav add <帧名>')
		end
	elseif cmd == 'remove' then
		if arg and MyNavigateDB.extra then
			MyNavigateDB.extra[arg] = nil
			print('|cff739BD0MyNavigate|r: 已移出导航白名单: '..arg)
			ns.Cursor:Refresh()
		end
	elseif cmd == 'pick' then
		StartPick()
	elseif cmd == 'nodes' then
		MyNavigateDB.debug = true
		ns.Cursor:Refresh()
		local Node = ns.Node
		local cache = Node.cache
		ns.Debug('缓存节点数', #cache)
		for i = 1, #cache do
			local item = cache[i]
			local n = item.node
			local x, y = n:GetCenter()
			ns.Debug('  ', i, n:GetName() or ('('..n:GetObjectType()..')'), item.object,
				'vis='..(n:IsVisible() and 'Y' or 'N'),
				'drawn='..(Node:IsDrawn(n, item.super) and 'Y' or 'N'),
				'xy='..tostring(x and math.floor(x))..','..tostring(y and math.floor(y)),
				item.super and ('super='..(item.super:GetName() or item.super:GetObjectType())) or '')
		end
	elseif cmd == 'tree' then
		local root = arg and _G[arg]
		if not (root and root.GetObjectType) then
			print('|cff739BD0MyNavigate|r: 找不到帧: '..tostring(arg))
		else
			MyNavigateDB.debug = true
			ns.Debug('帧树:', arg)
			local count = 0
			local function walk(f, depth)
				count = count + 1
				if count > 250 then return end
				local name = f.GetName and f:GetName()
				local ot = (f.GetObjectType and f:GetObjectType()) or '?'
				ns.Debug(string.rep('  ', depth), name or '(匿名)', ot,
					f:IsVisible() and 'shown' or 'hidden')
				local kids = { f:GetChildren() }
				for i = 1, #kids do walk(kids[i], depth + 1) end
			end
			walk(root, 0)
			ns.Debug('共', count, '个')
		end
	else
		print('|cff739BD0MyNavigate|r: /mynav on|off|debug|dump [关键词]|pick|add <帧名>|remove <帧名>|nodes|tree <帧名>|reset')
	end
end
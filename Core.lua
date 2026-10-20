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
	-- 背包 / 银行（含 Combuctor / DragonUI 第三方背包）
	'^ContainerFrame%d+$', '^BankFrame$', '^GuildBankFrame$',
	'^CombuctorFrame%d+$', '^CombuctorItem%d+$',
	'^CombuctorInventoryFrame$', '^CombuctorBankFrame$',
	'^DragonUI_CombuctorFrame%d+$',
	-- 角色 / 技能 / 天赋 / 声望
	'^CharacterFrame$', '^SpellBookFrame$', '^PlayerTalentFrame$',
	'^SkillsFrame$', '^SkillFrame$', '^InspectFrame$', '^ReputationFrame$',
	-- 任务 / 对话 / 商贩 / 训练师
	'^QuestLogFrame$', '^QuestLogPopupDetailFrame$', '^QuestFrame$',
	'^GossipFrame$', '^MerchantFrame$', '^QuestChoiceFrame$',
	'^ClassTrainerFrame$', '^LootFrame$', '^GroupLootFrame%d+$',
	-- 邮件 / 交易 / 制造
	'^MailFrame$', '^OpenMailFrame$', '^SendMailFrame$', '^InboxFrame$',
	'^TradeFrame$', '^TradeSkillFrame$', '^CraftFrame$',
	-- 社交 / 公会 / 团队
	'^FriendsFrame$', '^GuildFrame$', '^GuildInviteFrame$',
	'^GuildRegistrarFrame$', '^LookingForGuildFrame$',
	'^WhoFrame$', '^RaidFrame$', '^RaidGroupFrame$',
	-- 地图 / 飞行 / 换装 / PVP / 地下城
	'^WorldMapFrame$', '^TaxiFrame$', '^DressUpFrame$',
	'^PVPFrame$', '^PVPParentFrame$', '^PVEFrame$', '^HonorFrame$',
	'^ArenaFrame$', '^ArenaRegistrarFrame$', '^PVPBannerFrame$',
	'^LFDParentFrame$', '^LFDQueueFrame$', '^LFDRoleCheckPopup$',
	'^LFGDungeonReadyDialog$', '^LFGInvitePopup$', '^LFGParentFrame$',
	-- 系统 / 设置 / 弹窗
	'^GameMenuFrame$', '^HelpFrame$', '^HelpMenuFrame$',
	'^InterfaceOptionsFrame$', '^VideoOptionsFrame$', '^AudioOptionsFrame$',
	'^KeyBindingFrame$', '^MacroFrame$', '^AddonList$',
	'^ChatConfigFrame$', '^ChatMenu$', '^TimeManagerFrame$',
	'^StaticPopup%d+$', '^DropDownList%d+$',
	-- 沉浸式对话框
	'^ImmersionFrame$', '^ImmersionFrameTalkBox$',
	-- 其它窗口
	'^ItemTextFrame$', '^ItemSocketingFrame$', '^PetitionFrame$',
	'^StableFrame$', '^TabardFrame$', '^BarberShopFrame$',
	'^StackSplitFrame$', '^CoinPickupFrame$', '^TutorialFrame$',
	'^ReadyCheckFrame$', '^SplashFrame$', '^AchievementFrame$',
}

-- 弹窗 / 下拉菜单：只要这些窗口可见，就把导航范围限定在它们里面
-- （与 SimpleCursor 的 GetInteractableNodes 一致：有弹窗时不再理会背后的窗口）
local EXCLUSIVE_FRAMES = {
	'StaticPopup1', 'StaticPopup2', 'StaticPopup3', 'StaticPopup4',
	'DropDownList1', 'DropDownList2', 'DropDownList3',
}

-- 按名字首字母给模式分桶（所有模式都以「^ + 字母」开头），
-- 供 MatchesPanel 预筛，避免每次比对都遍历全部模式。
local PATTERN_INDEX = {}
for i = 1, #PANEL_PATTERNS do
	local pattern = PANEL_PATTERNS[i]
	local first = pattern:sub(2, 2):lower()
	local bucket = PATTERN_INDEX[first]
	if not bucket then
		bucket = {}
		PATTERN_INDEX[first] = bucket
	end
	bucket[#bucket + 1] = pattern
end

local function MatchesPanel(name)
	-- 82 条模式全部以「^ + 大写字母」开头，先按首字母分桶，
	-- 遍历窗口时只比对同首字母的那几条，避免每次都跑满 82 次 find
	local bucket = PATTERN_INDEX[name:sub(1, 1):lower()]
	if bucket then
		for i = 1, #bucket do
			if name:find(bucket[i]) then return true end
		end
	end
	local extra = MyNavigateDB and MyNavigateDB.extra
	return (extra and extra[name]) and true or false
end

function ns.IsNavigableRoot(frame)
	local name = frame.GetName and frame:GetName()
	if not name then return false end
	return MatchesPanel(name)
end

-- 把 UIParent:GetChildren() 返回的一串子帧里符合条件的收进 roots。
-- 本客户端的 GetChildren() 直接返回多值，用 ... 接收即可，
-- 不必每 0.2s 新建一张 `{ ... }` 包装表（这是常驻的内存分配来源之一）。
local function AddRoots(roots, ...)
	for i = 1, select('#', ...) do
		local frame = select(i, ...)
		if frame:IsVisible() and ns.IsNavigableRoot(frame) then
			roots[#roots + 1] = frame
		end
	end
end

function ns.GetRootFrames()
	local roots = {}
	-- 弹窗 / 下拉独占：屏幕上只要有它们，就只导航它们，忽略背后的窗口
	-- （可用设置面板里的「弹窗独占」开关关闭；默认开启）
	if not (MyNavigateDB and MyNavigateDB.exclusive == false) then
		for i = 1, #EXCLUSIVE_FRAMES do
			local frame = _G[EXCLUSIVE_FRAMES[i]]
			if frame and frame:IsVisible() then roots[#roots + 1] = frame end
		end
		if #roots > 0 then return roots end
	end
	AddRoots(roots, UIParent:GetChildren())
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
-- 刚打开的窗口：等它的控件建好、布局稳定之后再落点。
-- 刚 Show 的窗口（尤其界面设置的二级面板）这一拍往往还在创建/重排，
-- 立刻落点会先落到一个马上被隐藏的占位控件上，下一拍再被纠正 —— 看起来就是连跳两次。
local pendingRoot
local pendingSince = 0
local pendingCount         -- 上一次只看不落时的节点数，用来判断新窗口是否已经建完
local pendingTries = 0     -- 等待拍数上限，防止界面一直变化时永远不落点
-- 只检测到「有窗口关闭」时也压一拍：有些窗口是先关掉旧的、下一拍才显示新的，
-- 立刻按关闭处理会先落到旧位置，等新窗口出现再落一次（连跳两次）。
local closePending = false
local closeSince = 0
-- 检查间隔：只有「正在等新窗口建完」才用 0.05s 抢时间；
-- 其余时候（有窗口 / 没窗口）都是 0.1s —— 玩家跑图打怪时占绝大多数时间，
-- 那里没必要每秒扫 20 次白名单。
local watchInterval = 0.1
-- 按当前状态决定下一拍的检查间隔
local function UpdateWatchInterval()
	watchInterval = pendingRoot and 0.05 or 0.1
end
watcher:SetScript('OnUpdate', function(_, elapsed)
	watchTimer = watchTimer + elapsed
	if watchTimer < watchInterval then return end
	watchTimer = 0
	if MyNavigateDB and MyNavigateDB.enabled == false then
		pendingRoot = nil
		closePending = false
		ns.navActive = false
		if ns.SetGamepadOverride then ns.SetGamepadOverride(false) end
		watchInterval = 0.2   -- 禁用时不用快速轮询，省点开销
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
	if pendingRoot then
		local root = pendingRoot
		-- 这 0.2s 内玩家已经自己按方向键搬过光标（UIControl 会直接落点）：
		-- 放弃这次自动落点，否则会再挪一次，变成连跳
		local moved = ns.Cursor.GetLastMoveTime and ns.Cursor:GetLastMoveTime() > pendingSince
		if moved then
			pendingRoot = nil
		else
			-- 只看不落：节点数这一拍和上一拍一致，说明窗口里的控件已经建完、布局稳定，
			-- 这时再正式落点，就不会先落在一个马上被隐藏的占位控件上（避免「先落一处、
			-- 零点几秒后又跳到另一处」）。一直不稳定时最多等 5 拍。
			-- 只扫这个新窗口就够（不传 root 会扫全部白名单窗口，纯属浪费）
			pendingTries = pendingTries + 1
			local count = ns.Cursor:ScanOnly(root)
			if count == pendingCount or pendingTries > 5 then
				pendingRoot = nil
				if root:IsVisible() and ns.IsNavigableRoot(root) then
					ns.Cursor:Refresh(root)
				else
					ns.Cursor:Refresh()
				end
			else
				pendingCount = count
			end
		end
		-- 同一拍里又有别的窗口新开，留到下一拍处理（shown 已更新，不会再被识别为 opened）
		if opened and opened ~= root and not pendingRoot then
			pendingRoot = opened
			pendingSince = GetTime()
			pendingCount = ns.Cursor:ScanOnly(opened)
			pendingTries = 0
		end
		UpdateWatchInterval()
		return
	end
	if changed then
		if opened then
			-- 玩家可能已经抢在自动落点之前自己导航进这个窗口了：那就别再搬一次
			if ns.Cursor.IsCurrentInRoot and ns.Cursor:IsCurrentInRoot(opened) then
				closePending = false
				UpdateWatchInterval()
				return
			end
			closePending = false
			pendingRoot = opened
			pendingSince = GetTime()
			pendingTries = 0
			pendingCount = ns.Cursor:ScanOnly(opened)
			-- 等待期间别让 OnUpdate 自动纠偏，否则会多挪一次
			if ns.Cursor.HoldAutoCorrect then ns.Cursor:HoldAutoCorrect() end
		else
			-- 只有窗口关闭：先压一拍，等下一拍确认没有新窗口再刷新
			closePending = true
			closeSince = GetTime()
		end
		UpdateWatchInterval()
		return
	end
	if closePending then
		closePending = false
		-- 这一拍内玩家已经自己动过光标的话，就不要再刷新搬一次
		local moved = ns.Cursor.GetLastMoveTime and ns.Cursor:GetLastMoveTime() > closeSince
		if not moved then ns.Cursor:Refresh() end
	end
	UpdateWatchInterval()
end)

-- 导航绑定入口（仅在覆盖绑定生效、即存在可导航窗口时会被触发）
function MyNavigate:OnDirection(name)
	local key = DIRECTION_KEYS[name]
	if key then ns.Cursor:UIControl(key, KEY.STATE_DOWN) end
end

function MyNavigate:OnAction(name)
	ns.Cursor:Action(name)
end

-- 滚动绑定入口（-1 上翻 / 1 下翻），窗口打开、导航生效时才会被触发
function MyNavigate:OnScroll(delta)
	ns.Cursor:Scroll(delta)
end

---------------------------------------------------------------------
-- 手柄按键映射（参考 ConsolePortLK：用「覆盖绑定」重定向同一个物理键）
---------------------------------------------------------------------
-- 有可导航窗口时 → 1~8 覆盖为 MYNAV_*（导航/动作）；
-- 窗口全关后   → 清除覆盖，1~8 自动回到各自的原始绑定；本机未绑定的键
--                （如 6/7/8 = NONE）也就自然回到「无功能」，无需手动还原。
-- 覆盖绑定只存在于内存、不写存档，/reload 即失效，不污染玩家按键设置。
-- 注意：战斗中不能改绑定（SetOverrideBinding/ClearOverrideBindings 是受保护
--       函数），故用 desired/applied 记录期望值，出战斗后由
--       PLAYER_REGEN_ENABLED 补应用。因此两种情形受客户端限制、无法即时切换：
--         * 战斗中打开的窗口，本轮战斗内进入不了导航，战斗结束后才补上；
--         * 战斗中关闭的窗口，本轮战斗内按键仍停在导航态，战斗结束后才还原。
--       只要窗口是在非战斗时打开/关闭（最常见情形），战斗内外都能正确工作。
---------------------------------------------------------------------
-- 物理键 → 绑定名：默认方向 5/6/7/8，动作 X/B/Y/A 分别对应 1/2/3/4。
-- 滚动键不属于手柄那 8 个物理键，默认用键盘 PageUp / PageDown。
-- 这些键都可以在设置面板里改，改后的值存在 MyNavigateDB.keys 里。
local DEFAULT_KEYS = {
	UP = '5', DOWN = '6', LEFT = '7', RIGHT = '8',
	X = '1', B = '2', Y = '3', A = '4',
	SCROLLUP = 'PAGEUP', SCROLLDOWN = 'PAGEDOWN',
}
ns.DEFAULT_KEYS = DEFAULT_KEYS
ns.KEY_ACTIONS = { 'UP', 'DOWN', 'LEFT', 'RIGHT', 'A', 'B', 'X', 'Y', 'SCROLLUP', 'SCROLLDOWN' }

-- 读取某个动作当前绑定的物理键（未设置过则用默认值）
function ns.GetKey(action)
	local keys = MyNavigateDB and MyNavigateDB.keys
	local k = keys and keys[action]
	return (k and k ~= '') and k or DEFAULT_KEYS[action]
end

local bindOwner = CreateFrame('Frame')   -- 覆盖绑定的归属帧（无需键盘）
local applied, desired = false, false    -- applied=已生效, desired=期望状态

ns.navActive = false   -- 是否处于导航模式（由 Cursor:Refresh 更新）

-- 动作键 → 安全点击时用的鼠标键（A/X 左键，B 右键；Y 另见 SafeClick 的判断）
local ACTION_MOUSE = { A = 'LeftButton', B = 'RightButton', X = 'LeftButton', Y = 'LeftButton' }

-- 判断某动作键能否走「安全点击」：节点必须有名字，且不能是需要 Lua 特殊处理的节点
--（Y 键对「自定义 SpecialClick / 输入框聚焦」只能交给 Lua，安全点击表达不了）。
-- 不能走安全点击时返回 nil，调用方回退到 MYNAV_* 命令绑定。
local function SafeClick(node, action)
	if not node or not node.GetName then return nil end
	local name = node:GetName()
	if not name then return nil end
	-- 输入框没有可点击的语义，交给 Lua 处理（Y 会去聚焦它）
	if node.IsObjectType and node:IsObjectType('EditBox') then return nil end
	-- Y 的自定义特殊点击是 Lua 函数，安全点击表达不了
	if action == 'Y' and node.SpecialClick then return nil end
	return name, ACTION_MOUSE[action] or 'LeftButton'
end

-- 当前期望绑定的动作节点（由 Cursor 切换节点时通过 ns.SetActionNode 更新）
local actionNode

-- 重设 4 个动作键的覆盖绑定：
--   * 节点有名字 → SetOverrideBindingClick：点击交给暴雪安全框架执行。
--     背包里「使用 / 拾取」这类受保护操作（UseContainerItem 等）只有走这条路
--     才不会被 ADDON_ACTION_BLOCKED（"暴雪自己的代码才能使用的接口"）拦下；
--   * 无名节点 / Y 的特殊分支 → 退回 MYNAV_* 命令，由 Cursor:Action 用 Lua 处理。
local function ApplyActionKeys(node)
	for _, action in ipairs({ 'A', 'B', 'X', 'Y' }) do
		local key = ns.GetKey(action)
		if key then
			local btnName, mouse = SafeClick(node, action)
			if btnName then
				SetOverrideBindingClick(bindOwner, true, key, btnName, mouse)
			else
				SetOverrideBinding(bindOwner, true, key, 'MYNAV_' .. action)
			end
		end
	end
end

-- 节点变化时更新动作键绑定（战斗中禁止改绑定，先记下，出战斗后补应用）
function ns.SetActionNode(node)
	actionNode = node
	if applied and not InCombatLockdown() then ApplyActionKeys(node) end
end

local function ApplyOverride(on)
	ClearOverrideBindings(bindOwner)
	if on then
		-- 方向键 / 滚动键：普通命令绑定，走 Cursor 的移动与滚动逻辑
		for _, action in ipairs({ 'UP', 'DOWN', 'LEFT', 'RIGHT', 'SCROLLUP', 'SCROLLDOWN' }) do
			local key = ns.GetKey(action)
			if key then SetOverrideBinding(bindOwner, true, key, 'MYNAV_' .. action) end
		end
		-- 动作键：安全点击绑定，随当前节点变化
		ApplyActionKeys(ns.Cursor and ns.Cursor:GetCurrentNode() or nil)
	end
	applied = on
end

-- 改键后立即按新键重应用覆盖绑定（战斗中不能改，出战斗后由事件兜底）
function ns.RefreshBindings()
	if not InCombatLockdown() then ApplyOverride(applied) end
end

-- 切换覆盖绑定；战斗中被禁改，先记下期望值，出战斗后再补上
function ns.SetGamepadOverride(on)
	desired = on and true or false
	if not InCombatLockdown() and desired ~= applied then
		ApplyOverride(desired)
	end
end

bindOwner:RegisterEvent('PLAYER_REGEN_ENABLED')
bindOwner:SetScript('OnEvent', function()
	if InCombatLockdown() then return end
	if desired ~= applied then ApplyOverride(desired) end
	-- 战斗中节点变化时被搁置的动作键绑定，在这里补应用
	if applied then ApplyActionKeys(actionNode) end
end)

local frame = CreateFrame('Frame')
frame:RegisterEvent('PLAYER_LOGIN')
frame:SetScript('OnEvent', function()
	MyNavigateDB = MyNavigateDB or {}
	if MyNavigateDB.enabled == nil then MyNavigateDB.enabled = true end
	if MyNavigateDB.exclusive == nil then MyNavigateDB.exclusive = true end
	if MyNavigateDB.hint == nil then MyNavigateDB.hint = true end
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
	-- 清理旧版本残留：曾被绑到 MYNAV_* 的实体键（SHIFT-1..8、F5..F10 等）应解除，
	-- 现在按键由覆盖绑定驱动，这些残留绑定留着会重复触发
	local cleaned = false
	for i = 1, #ns.KEY_ACTIONS do
		local bind = 'MYNAV_' .. ns.KEY_ACTIONS[i]
		local k1, k2 = GetBindingKey(bind)
		if k1 then SetBinding(k1, nil) cleaned = true end
		if k2 then SetBinding(k2, nil) cleaned = true end
	end
	if cleaned then SaveBindings(GetCurrentBindingSet()) end
	-- 覆盖绑定不在这里应用：交由 Cursor:Refresh 依据「是否真有可导航节点」动态开关
end)

local LABELS = {
	UP = '上', DOWN = '下', LEFT = '左', RIGHT = '右',
	A = 'A (左键)', B = 'B (右键)', X = 'X (左键)', Y = 'Y (特殊)',
	SCROLLUP = '上翻', SCROLLDOWN = '下翻',
}
_G['BINDING_HEADER_MYNAV'] = 'MyNavigate 导航'
_G['BINDING_HEADER_MYNAVACT'] = 'MyNavigate 动作'
_G['BINDING_HEADER_MYNAVSCROLL'] = 'MyNavigate 滚动'
for name in pairs({ MYNAV_UP = 1, MYNAV_DOWN = 1, MYNAV_LEFT = 1, MYNAV_RIGHT = 1,
	MYNAV_A = 1, MYNAV_B = 1, MYNAV_X = 1, MYNAV_Y = 1,
	MYNAV_SCROLLUP = 1, MYNAV_SCROLLDOWN = 1 }) do
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
		ns.Cursor:Refresh()   -- 由「当前是否有可导航窗口」重新判定并开关覆盖绑定
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
	elseif cmd == 'config' or cmd == '' then
		if ns.OpenOptions then
			ns.OpenOptions()
		else
			print('|cff739BD0MyNavigate|r: 设置面板未加载')
		end
	else
		print('|cff739BD0MyNavigate|r: /mynav on|off|config|debug|dump [关键词]|pick|add <帧名>|remove <帧名>|nodes|tree <帧名>|reset')
	end
end
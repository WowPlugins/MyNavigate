---------------------------------------------------------------------
-- Cursor.lua: 虚拟光标 —— 金色高亮框、动作提示、动作执行
---------------------------------------------------------------------
-- 高亮框由四条边纹理（WHITE8X8 着色成金色）围成，紧贴当前节点的外沿，
-- 比单张环纹理更能完整包住不同尺寸的控件；
-- 旁边用提示框（tooltip 边框 + GameFontNormalSmall）显示四个动作键当前的功能；
-- ABXY 直接调用控件自己的 Click(button)，等价 ConsolePort 的 ClickWrapper。
---------------------------------------------------------------------
local ADDON, ns = ...
local KEY, Node = ns.KEY, ns.Node
local abs, unpack, next, pairs, pcall = math.abs, unpack, next, pairs, pcall
local tremove = table.remove
local NL = string.char(10)   -- 提示框每行之间的换行符

local BORDER_TEXTURE = 'Interface\\Buttons\\WHITE8X8'
local BORDER_COLOR = { 1, 0.88, 0.1 }   -- 金色
local BORDER_PAD = 4      -- 边框内沿距节点边缘的像素
local BORDER_THICK = 2    -- 边框粗细

local Cursor = CreateFrame('Frame', 'MyNavigateCursor', UIParent)
Cursor:SetFrameStrata('TOOLTIP')
Cursor:SetSize(1, 1)
Cursor:Hide()

-- 四条边纹理围成矩形金框：上/下两条横贯全宽，左/右两条夹在中间，四角刚好相接。
-- 直接挂在 Cursor 上（与旧的高亮环同一层级），随 Cursor:Show()/Hide() 一起显隐，
-- 不再套一层中间 Frame（那样中间帧隐藏时子纹理也不会渲染）。
local edgeTop = Cursor:CreateTexture(nil, 'OVERLAY')
local edgeBottom = Cursor:CreateTexture(nil, 'OVERLAY')
local edgeLeft = Cursor:CreateTexture(nil, 'OVERLAY')
local edgeRight = Cursor:CreateTexture(nil, 'OVERLAY')
for _, tex in ipairs({ edgeTop, edgeBottom, edgeLeft, edgeRight }) do
	tex:SetTexture(BORDER_TEXTURE)
	tex:SetVertexColor(BORDER_COLOR[1], BORDER_COLOR[2], BORDER_COLOR[3])
end

-- 提示框：沿用 SimpleCursor 的样式 —— tooltip 边框小框 + GameFontNormalSmall 字号，
-- 内容仍按当前节点动态生成四个动作键的功能
local HintBox = CreateFrame('Frame', 'MyNavigateHintBox', Cursor)
HintBox:SetFrameStrata('TOOLTIP')
HintBox:SetBackdrop({
	bgFile = 'Interface\\Tooltips\\UI-Tooltip-Background',
	edgeFile = 'Interface\\Tooltips\\UI-Tooltip-Border',
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
HintBox:SetBackdropColor(0, 0, 0, 0.8)
HintBox:SetBackdropBorderColor(1, 1, 1, 1)
HintBox:Hide()
Cursor.hint = HintBox

local HintText = HintBox:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
HintText:SetPoint('TOPLEFT', 8, -8)
HintText:SetJustifyH('LEFT')
Cursor.hintText = HintText

ns.Cursor = Cursor

-- 记忆栈：从窗口 A 切到窗口 B（或弹窗）前，先记住 A 里所在的节点；
-- B 关掉时回溯到 A，而不是盲目跳到最近的节点
local history = {}

-- 动作键 → 点击类型；Y 用 'Special' 走下面的特殊分支
local ACTION_MAP = { A = 'LeftButton', B = 'RightButton', X = 'LeftButton', Y = 'Special' }
ns.ACTION_MAP = ACTION_MAP

local Scroll = CreateFrame('Frame')
local ScrollActive = {}
local current, lastNode

local function Debug(...)
	if MyNavigateDB and MyNavigateDB.debug then
		print('|cff739BD0MyNavigate|r', ...)
	end
end
ns.Debug = Debug

local function RunScript(node, scriptType)
	if node and node.GetScript then
		local script = node:GetScript(scriptType)
		if script then pcall(script, node) end
	end
end

local function IsBagItem(node)
	local parent = node.GetParent and node:GetParent()
	local pn = parent and parent.GetName and parent:GetName()
	local nn = node.GetName and node:GetName()
	return (pn and nn and pn:match('^ContainerFrame') and nn:match(pn..'Item')) and true or false
end

-- 「无名 + 受保护」的控件（如安全动作按钮）：动作键走不了 SetOverrideBindingClick
-- （它是按帧名找按钮的，无名帧没有名字），插件也不能直接 :Click（会触发安全执行环境报错），
-- 手柄点不动它。导航落上去时在提示框里明确告知玩家，避免按了没反应还以为是插件坏了。
local function IsUnclickable(node)
	return (node.IsProtected and node:IsProtected() and not (node.GetName and node:GetName())) and true or false
end

function Scroll:Offset()
	for super, target in pairs(ScrollActive) do
		local currVert = super:GetVerticalScroll()
		local maxVert = super:GetVerticalScrollRange()
		if abs(currVert - target.vert) < 2 then
			super:SetVerticalScroll(target.vert)
			ScrollActive[super] = nil
		else
			local delta = currVert > target.vert and -1 or 1
			local newY = currVert + (delta * abs(currVert - target.vert) / 16 * 4)
			super:SetVerticalScroll(newY < 0 and 0 or newY > maxVert and maxVert or newY)
		end
	end
	if not next(ScrollActive) then Scroll:SetScript('OnUpdate', nil) end
end

-- 让滚动帧滚到目标节点（导航到视口外的行时使用）
function Scroll:To(node, super)
	local _, nodeY = node:GetCenter()
	local _, scrollY = super:GetCenter()
	if nodeY and scrollY then
		local currVert = super:GetVerticalScroll()
		local maxVert = super:GetVerticalScrollRange()
		local newVert = currVert + (scrollY - nodeY)
		ScrollActive[super] = { vert = newVert < 0 and 0 or newVert > maxVert and maxVert or newVert }
		Scroll:SetScript('OnUpdate', Scroll.Offset)
	end
end

-- 提示框里每个动作键一行的颜色（沿用 SimpleCursor 的彩色提示风格）
local ACTION_COLOR = {
	A = '|cFFFFFF00',  -- 金黄
	B = '|cFF00FF00',  -- 绿
	X = '|cFFFF0000',  -- 红
	Y = '|cFF00FFFF',  -- 蓝
}

function Cursor:GetActionText(node)
	-- 点不动的节点：不给四个动作键的功能说明，直接提示原因
	if IsUnclickable(node) then
		return '|cFFFF5555此控件受保护，手柄无法点击|r'
	end
	local object = current and current.object
	local bag = IsBagItem(node)
	local function name(n)
		local mapped = ACTION_MAP[n]
		if mapped == 'Special' then
			if node.SpecialClick then return '特殊' end
			if node:IsObjectType('EditBox') then return '输入' end
			return '点击'
		elseif mapped == 'RightButton' then
			return bag and '菜单' or '右键'
		elseif object == 'EditBox' then
			return '输入'
		elseif bag then
			return '拾取'
		else
			return '点击'
		end
	end
	local lines = {}
	for _, k in ipairs({ 'A', 'B', 'X', 'Y' }) do
		lines[#lines + 1] = ACTION_COLOR[k] .. k .. ' ' .. name(k) .. '|r'
	end
	return table.concat(lines, NL)
end

function Cursor:SetHighlight(node)
	local pad, thick = BORDER_PAD, BORDER_THICK
	local outer = pad + thick
	-- 上边：横贯全宽，内沿在节点上边上方 pad 处
	edgeTop:ClearAllPoints()
	edgeTop:SetPoint('TOPLEFT', node, 'TOPLEFT', -outer, outer)
	edgeTop:SetPoint('TOPRIGHT', node, 'TOPRIGHT', outer, outer)
	edgeTop:SetHeight(thick)
	-- 下边
	edgeBottom:ClearAllPoints()
	edgeBottom:SetPoint('BOTTOMLEFT', node, 'BOTTOMLEFT', -outer, -outer)
	edgeBottom:SetPoint('BOTTOMRIGHT', node, 'BOTTOMRIGHT', outer, -outer)
	edgeBottom:SetHeight(thick)
	-- 左边：竖直，夹在上下两条之间
	edgeLeft:ClearAllPoints()
	edgeLeft:SetPoint('TOPLEFT', node, 'TOPLEFT', -outer, pad)
	edgeLeft:SetPoint('BOTTOMLEFT', node, 'BOTTOMLEFT', -outer, -pad)
	edgeLeft:SetWidth(thick)
	-- 右边
	edgeRight:ClearAllPoints()
	edgeRight:SetPoint('TOPRIGHT', node, 'TOPRIGHT', outer, pad)
	edgeRight:SetPoint('BOTTOMRIGHT', node, 'BOTTOMRIGHT', outer, -pad)
	edgeRight:SetWidth(thick)

	edgeTop:Show()
	edgeBottom:Show()
	edgeLeft:Show()
	edgeRight:Show()
end

function Cursor:SetPosition(node)
	self:SetHighlight(node)
	self:ClearAllPoints()
	self:SetPoint('CENTER', node, 'CENTER', 0, 0)
	-- 提示框贴在节点右上角外侧，尺寸按文字自适应（与 SimpleCursor 一致）。
	-- 点不动的节点属于提醒，即使关掉了常规提示也照样显示，避免按了没反应还以为插件坏了。
	if MyNavigateDB and MyNavigateDB.hint == false and not IsUnclickable(node) then
		HintBox:Hide()
	else
		HintText:SetText(self:GetActionText(node))
		HintBox:SetWidth(HintText:GetStringWidth() + 16)
		HintBox:SetHeight(HintText:GetStringHeight() + 16)
		HintBox:ClearAllPoints()
		HintBox:SetPoint('BOTTOMLEFT', node, 'TOPRIGHT', 4, 2)
		HintBox:Show()
	end
	self:Show()
end

function Cursor:SetNode(node, object, super)
	if node ~= lastNode then
		RunScript(lastNode, 'OnLeave')
		RunScript(node, 'OnEnter')
		lastNode = node
	end
	self:SetPosition(node)
	if super then Scroll:To(node, super) end
	-- 把动作键重绑成「安全点击该节点」，由暴雪安全框架执行点击
	if ns.SetActionNode then ns.SetActionNode(node) end
end

function Cursor:HideNode()
	RunScript(lastNode, 'OnLeave')
	lastNode, current = nil, nil
	HintBox:Hide()
	self:Hide()
	if ns.SetActionNode then ns.SetActionNode(nil) end
end

-- 顶层父窗口（上溯到 UIParent 之前的那一层）
local function TopParent(frame)
	local p = frame
	while p and p.GetParent do
		local parent = p:GetParent()
		if not parent or parent == UIParent or parent == WorldFrame then return p end
		p = parent
	end
	return p
end

-- 记忆：移动到另一个顶层窗口前，先把当前所在节点压栈
local function Remember(item)
	history[#history + 1] = item
	if #history > 24 then tremove(history, 1) end
end

-- 回溯：从记忆栈里取最后一个仍然可见的节点
local function BacktrackItem()
	while #history > 0 do
		local item = tremove(history)
		if item and item.node and item.node:IsVisible() then return item end
	end
end

-- 统一入口：切换当前节点。跨顶层窗口时自动记忆上一个位置
function Cursor:MoveTo(item)
	local prev = current
	if prev and prev.node and prev.node:IsVisible() and item and item.node
		and prev.node ~= item.node and TopParent(prev.node) ~= TopParent(item.node) then
		Remember(prev)
	end
	current = item
	if item then
		self:SetNode(item.node, item.object, item.super)
	else
		self:HideNode()
	end
end

-- 重新扫描所有白名单窗口，并重算当前节点
function Cursor:Refresh()
	local roots = ns.GetRootFrames()
	Node:ClearCache()
	Node:RunScan(unpack(roots))
	-- 当前节点所在窗口被关掉时，先回溯记忆栈，回到进入该窗口前的位置
	local seed = current
	if seed and not (Node:IsRelevant(seed.node) and Node:IsDrawn(seed.node, seed.super)) then
		seed = BacktrackItem() or seed
	end
	local nextItem = Node:GetArbitraryCandidate(seed, seed, self:GetCenter())
	local names = {}
	for i = 1, #roots do names[i] = roots[i]:GetName() or '?' end
	Debug('面板', #roots, '['..table.concat(names, ',')..']', '节点', #Node.cache, '当前',
		nextItem and (nextItem.node:GetName() or nextItem.object) or 'nil')
	-- 只有「已启用」且真正存在可导航节点时才处于导航模式；面板全关或没有可用节点时清除覆盖，
	-- 1~8 自动回到各自的原始绑定（动作条等）
	local enabled = not (MyNavigateDB and MyNavigateDB.enabled == false)
	ns.navActive = enabled and (#Node.cache > 0)
	if ns.SetGamepadOverride then ns.SetGamepadOverride(ns.navActive) end
	if enabled then
		self:MoveTo(nextItem)
	else
		self:HideNode()
	end
end

-- 方向键入口：刷新后按方向选最优候选；没有合适的就退化为「同方向上最近的节点」
function Cursor:UIControl(key, state)
	self:Refresh()
	if state == KEY.STATE_DOWN and current then
		local changed
		local nextItem
		nextItem, changed = Node:GetBestCandidate(current, key)
		if not changed then
			nextItem = Node:GetClosestCandidate(current, key)
		end
		if nextItem then self:MoveTo(nextItem) end
	end
	return current and current.node
end

-- 受保护的帧（安全模板：安全动作按钮等）不能由插件直接 :Click —— 会触发暴雪安全执行
-- 环境报错（SecureHandlers: "Invalid access of managed environments table"），且这个错误在
-- 安全环境里抛出、pcall 拦不住。有名字的受保护节点已由 Core.lua 用 SetOverrideBindingClick
-- 交给安全框架点击；无名节点既没法覆盖绑定、也不能直接点击，只能跳过（调试模式会打印出来）。
local function CanDirectClick(node)
	if node.IsProtected and node:IsProtected() then
		Debug('跳过受保护节点', node:GetName() or '(无名)', node:GetObjectType())
		return false
	end
	return true
end

-- 动作键入口：A/X/B 直接 Click，Y 走特殊分支（SpecialClick / 聚焦输入框 / 兜底左键）
function Cursor:Action(name)
	if not current then self:Refresh() end
	if not current then return end
	local node, mapped = current.node, ACTION_MAP[name]
	Debug('动作', name, '->', mapped, node:GetName() or node:GetObjectType())
	if mapped == 'Special' then
		if node.SpecialClick then
			pcall(node.SpecialClick, node)
		elseif node:IsObjectType('EditBox') then
			node:SetFocus(true)
		elseif node.Click and CanDirectClick(node) then
			pcall(node.Click, node, 'LeftButton')
		end
	elseif mapped and node.Click and CanDirectClick(node) then
		pcall(node.Click, node, mapped)
	end
end

function Cursor:GetCurrentNode() return current and current.node end

-- 判断节点是否属于某个根窗口（沿父级上溯）
local function IsDescendant(node, root)
	local f = node
	while f and f ~= root do
		f = f.GetParent and f:GetParent()
	end
	return f == root
end

-- 把光标直接落到指定根窗口里的第一个节点：窗口刚打开时自动选中用。
-- 落点沿用 SimpleCursor 的评分法：score = ny*10 - nx（越靠上、越靠左分越高），
-- 取第二高分，跳过最高分那个（通常是右上角的关闭按钮）。
function Cursor:SelectRoot(root)
	local scored = {}
	for i = 1, #Node.cache do
		local item = Node.cache[i]
		if IsDescendant(item.node, root) then
			local nx, ny = item.node:GetCenter()
			if nx and ny then
				scored[#scored + 1] = { item = item, score = ny * 10 - nx }
			end
		end
	end
	if #scored == 0 then return false end
	table.sort(scored, function(a, b) return a.score > b.score end)
	self:MoveTo((scored[2] or scored[1]).item)
	return true
end

-- 当前节点消失（窗口被关掉）时回溯记忆栈，回到进入该窗口前的位置；没有则收起光标
Cursor:SetScript('OnUpdate', function(self, elapsed)
	self.Timer = (self.Timer or 0) + elapsed
	if self.Timer < 0.1 then return end
	self.Timer = 0
	if current and not current.node:IsVisible() then
		local item = BacktrackItem()
		if item then
			self:MoveTo(item)
		else
			self:HideNode()
		end
	end
end)
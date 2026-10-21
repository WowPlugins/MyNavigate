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
local abs, next, pairs, pcall = math.abs, next, pairs, pcall
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
-- 复用的「单窗口根帧表」：按键时只重扫当前窗口，避免每次新建一张小表
local singleRoot = {}
-- 最近一次落地的时间：刚落地时节点的 IsVisible 常有瞬时抖动（滚动帧重排 / 外部 UI
-- 换布局），OnUpdate 要据此放一拍再判定，否则会误触发重扫、把光标挪到别的节点上
local lastSetTime = 0
-- 最近一次真正移动光标的时间。与 lastSetTime 分开：lastSetTime 还会被
-- HoldAutoCorrect 主动刷新，这里只记录真实落点，用于判断「用户已经自己动过了」。
local lastMoveTime = 0

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

-- 上翻 / 下翻：默认 PageUp / PageDown（设置面板可改），只在窗口打开、导航生效时触发。
-- 优先滚「当前节点所在的滚动帧」，没有就退回缓存里任意一个可滚动的帧。
local SCROLL_STEP = 40   -- 一次按键滚动的像素
function Cursor:Scroll(delta)
	local target = current and current.super
	if not (target and target.GetVerticalScroll and target:GetVerticalScrollRange() > 0) then
		target = nil
		for _, item in Node:IterateCache() do
			local super = item.super
			if super and super.GetVerticalScroll and super:GetVerticalScrollRange() > 0 then
				target = super
				break
			end
		end
	end
	if not target then return end
	local maxVert = target:GetVerticalScrollRange()
	local newVert = target:GetVerticalScroll() + delta * SCROLL_STEP
	if newVert < 0 then newVert = 0 elseif newVert > maxVert then newVert = maxVert end
	-- 复用 ScrollActive 的缓动，滚动更顺滑（与导航到视口外节点时的滚动一致）
	ScrollActive[target] = { vert = newVert }
	Scroll:SetScript('OnUpdate', Scroll.Offset)
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
	-- 提示框贴在节点右下角外侧（即金色边框的右下角），向右下展开，尺寸按文字自适应
	--（与 SimpleCursor 一致）。点不动的节点属于提醒，即使关掉了常规提示也照样显示，
	-- 避免按了没反应还以为插件坏了。
	if MyNavigateDB and MyNavigateDB.hint == false and not IsUnclickable(node) then
		HintBox:Hide()
	else
		HintText:SetText(self:GetActionText(node))
		HintBox:SetWidth(HintText:GetStringWidth() + 16)
		HintBox:SetHeight(HintText:GetStringHeight() + 16)
		HintBox:ClearAllPoints()
		HintBox:SetPoint('TOPLEFT', node, 'BOTTOMRIGHT', 4, -4)
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
	lastSetTime = GetTime()
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

-- 节点是否属于某个窗口（沿父级上溯）
local function InRoot(node, root)
	local f = node
	while f and f ~= root do
		f = f.GetParent and f:GetParent()
	end
	return f == root
end

-- 在指定窗口内找离 (x, y) 最近的可见节点。
-- 面板切换导致当前控件被藏掉时用它重新落地：只在同一个窗口内选，
-- 不会因为「离光标最近」而跳到另一个窗口或另一栏。
local function NearestInRoot(root, x, y)
	local best, bestDist
	for _, item in Node:IterateCache() do
		if InRoot(item.node, root) then
			local nx, ny = item.node:GetCenter()
			if nx and ny then
				local dist = Node:GetDistanceSum(x, y, nx, ny)
				if not bestDist or dist < bestDist then
					best, bestDist = item, dist
				end
			end
		end
	end
	return best
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
	if MyNavigateDB and MyNavigateDB.debug then
		Debug('落点', item and (item.node:GetName() or item.object) or 'nil', GetTime())
	end
	lastMoveTime = GetTime()
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

-- 只重建缓存、不移动光标；返回可导航节点数。
-- 新窗口刚打开时它的控件还在陆续创建，Core 用一个稳定的节点数判断「已经建完了」。
function Cursor:ScanOnly(root)
	Node:ClearCache()
	if root then
		singleRoot[1] = root
		Node:RunScan(singleRoot)
	else
		Node:RunScan(ns.GetRootFrames())
	end
	return #Node.cache
end

-- 重新扫描所有白名单窗口，并重算当前节点。
-- selectRoot：刚打开的窗口。传入时直接落到它里面，并且只移动一次
--（否则 Refresh 先搬一次、SelectRoot 又搬一次，调用方看起来就是连跳）。
function Cursor:Refresh(selectRoot)
	local roots = ns.GetRootFrames()
	Node:ClearCache()
	Node:RunScan(roots)
	-- 当前节点所在窗口被关掉时，先回溯记忆栈，回到进入该窗口前的位置；
	-- 窗口本身还开着（只是面板换了 / 控件被藏）时只在窗口内重选，
	-- 不翻记忆栈 —— 那里可能存着另一个窗口的旧位置，会造成跨窗口跳。
	local seed = current
	local nextItem
	if seed and not (Node:IsRelevant(seed.node) and Node:IsDrawn(seed.node, seed.super)) then
		local root = seed.node and TopParent(seed.node)
		if root and root:IsVisible() then
			local x, y = self:GetCenter()
			nextItem = NearestInRoot(root, x, y)
			seed = nil
		else
			seed = BacktrackItem() or seed
		end
	end
	nextItem = nextItem or Node:GetArbitraryCandidate(seed, seed, self:GetCenter())
	-- 调试输出：只在开启调试时才拼字符串（否则每次扫描都白拼一份名字表）
	if MyNavigateDB and MyNavigateDB.debug then
		local names = {}
		for i = 1, #roots do names[i] = roots[i]:GetName() or '?' end
		Debug('面板', #roots, '['..table.concat(names, ',')..']', '节点', #Node.cache, '当前',
			nextItem and (nextItem.node:GetName() or nextItem.object) or 'nil')
	end
	-- 只有「已启用」且真正存在可导航节点时才处于导航模式；面板全关或没有可用节点时清除覆盖，
	-- 1~8 自动回到各自的原始绑定（动作条等）
	local enabled = not (MyNavigateDB and MyNavigateDB.enabled == false)
	ns.navActive = enabled and (#Node.cache > 0)
	if ns.SetGamepadOverride then ns.SetGamepadOverride(ns.navActive) end
	if enabled then
		-- 新窗口打开时直接落到它里面（SelectRoot 内部会 MoveTo）；
		-- 它里面一个可导航节点都没有时，再退回常规落点
		if not (selectRoot and self:SelectRoot(selectRoot)) then
			self:MoveTo(nextItem)
		end
	else
		self:HideNode()
	end
end

-- 方向键入口：每次按键前重建缓存。
-- 不能复用上一次的缓存：切分类会整块换掉右侧面板、滚动帧也会换掉视口内容，
-- 缓存里可能留着已经隐藏的旧节点 —— 先落过去、下一拍再被纠正，
-- 画面上就是「刚过到右边，立即又跳到另一个位置」。
-- 扫描本身已改为迭代式、不再转发变长参数（见 Node:Scan），单次开销可控。
function Cursor:UIControl(key, state)
	local node = current and current.node
	local root = node and TopParent(node)
	-- 每次按键都要重建缓存（理由见上），但优先只重扫「当前节点所在的窗口」：
	-- 背包 + 银行 / 多个面板同开时，全量扫描会把它们的节点全部走一遍，
	-- 按键瞬间的开销随窗口数成倍增长，而这一步绝大多数时候只在当前窗口内挑下一个节点。
	-- 窗口已关（root 不可见）时才直接走全量扫描。
	local scannedAll = false
	if root and root:IsVisible() then
		singleRoot[1] = root
		Node:ClearCache()
		Node:RunScan(singleRoot)
	else
		Node:ClearCache()
		Node:RunScan(ns.GetRootFrames())
		scannedAll = true
	end

	if not (node and Node:IsRelevant(node)) then
		-- 当前节点真的没了（窗口关了 / 面板整个换掉）：落到最近的有效节点，
		-- 这一拍不再做方向移动，避免一次按键连搬两次
		if not scannedAll then
			-- 上面只扫了当前窗口，可能已经切到别的窗口：补一次全量扫描
			Node:ClearCache()
			Node:RunScan(ns.GetRootFrames())
		end
		local seed = current
		if seed and not Node:IsRelevant(seed.node) then seed = BacktrackItem() or seed end
		self:MoveTo(Node:GetArbitraryCandidate(seed, seed, self:GetCenter()))
		return current and current.node
	end
	if not Node:IsDrawn(node, current.super) then
		-- 节点还在，只是滚动动画还没把它带进视口：把它滚回来，不要换节点。
		-- 换节点会按「离光标最近」重选，很容易突然跳到窗口的另一边/另一栏，
		-- 而玩家其实只是在同一个列表里按住上/下。
		if current.super then Scroll:To(node, current.super) end
	end
	if state == KEY.STATE_DOWN and current then
		local nextItem, changed = Node:GetBestCandidate(current, key)
		if not changed then nextItem = Node:GetClosestCandidate(current, key) end
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
	-- 金框没显示（无当前节点 / 被滚出视口 / 导航未生效）时，动作键不响应
	if not (current and Cursor:IsShown()) then return end
	local node, mapped = current.node, ACTION_MAP[name]
	-- 兜底：金框刚被滚出视口、还没轮到 OnUpdate（0.1s）把它收起时，
	-- 也不要点到看不见的控件
	if not Node:IsDrawn(node, current.super) then return end
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

-- 当前节点是否已经在这个窗口里（玩家可能抢在自动落点之前自己导航进去了）
function Cursor:IsCurrentInRoot(root)
	local node = current and current.node
	if not node or not root then return false end
	local f = node
	while f and f ~= root do
		f = f.GetParent and f:GetParent()
	end
	return f == root
end

-- 外部即将重新落点（如新窗口打开、需要等它建好再落）时调用：
-- 把「刚落地」的时间刷新一下，让 OnUpdate 在这段宽限期内不要自动纠偏，
-- 否则它会先把光标挪一次、落点逻辑再挪一次，看起来就是连跳。
function Cursor:HoldAutoCorrect() lastSetTime = GetTime() end
function Cursor:GetLastMoveTime() return lastMoveTime end

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

-- 当前节点被滚出滚动帧视口（或被遮挡）时收起光标：
-- 金框和提示框挂在 UIParent 的 TOOLTIP 层级、不受滚动帧裁剪，不收起就会跟着
-- 节点画到滚动帧外面。current 保留，滚回来或再按方向键会自动恢复。
local function SetCursorDrawn(drawn)
	if not current then return end
	if drawn then
		if not Cursor:IsShown() then
			Cursor:SetPosition(current.node)
			if ns.SetActionNode then ns.SetActionNode(current.node) end
		end
	elseif Cursor:IsShown() then
		Cursor:Hide()
		if ns.SetActionNode then ns.SetActionNode(nil) end
	end
end

-- 当前节点消失（窗口被关掉）时回溯记忆栈，回到进入该窗口前的位置；没有则收起光标
Cursor:SetScript('OnUpdate', function(self, elapsed)
	self.Timer = (self.Timer or 0) + elapsed
	if self.Timer < 0.1 then return end
	self.Timer = 0
	if not current then return end
	if not current.node:IsVisible() then
		-- 刚落地时节点的 IsVisible 常有瞬时抖动（滚动帧重排、外部 UI 换布局），
		-- 这种抖动下一拍就恢复。先放一拍再看，否则会误触发下面的重扫，
		-- 把光标挪到别的节点上（表现为「刚过到右边，立即又跳到另一个位置」）。
		if GetTime() - lastSetTime < 0.3 then return end
		-- 确实不见了。窗口本身还开着（只是面板换了 / 控件被藏）：重新扫描并在
		-- 同一个窗口内落地。不要翻记忆栈 —— 里面可能是另一个窗口的旧位置，
		-- 翻出来就会「突然从窗口一边跳到另一边」。
		-- 窗口已经关了的话交给 Core 的 watcher 统一处理，这里不抢跑，
		-- 否则会先落到旧窗口的位置、下一拍再落到新窗口（连跳两次）。
		local root = TopParent(current.node)
		if root and root:IsVisible() then
			self:Refresh()
		end
	else
		-- 节点还在，但可能被滚出滚动帧视口/被遮挡：按「是否还在可视区」显隐光标
		SetCursorDrawn(Node:IsDrawn(current.node, current.super) and true or false)
	end
end)
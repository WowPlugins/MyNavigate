---------------------------------------------------------------------
-- Cursor.lua: 虚拟光标 —— 金色高亮环、动作提示、动作执行
---------------------------------------------------------------------
-- 高亮环是一个独立 Texture（UI-ActionButton-Border，必须用 ADD 混合，
-- 否则该贴图的黑色底会显示成黑块），锚定当前节点的四个角；
-- 旁边用 FontString 显示四个动作键当前的功能；
-- ABXY 直接调用控件自己的 Click(button)，等价 ConsolePort 的 ClickWrapper。
---------------------------------------------------------------------
local ADDON, ns = ...

local KEY, Node = ns.KEY, ns.Node
local abs, unpack, next, pairs, pcall = math.abs, unpack, next, pairs, pcall

local RING_TEXTURE = 'Interface\\Buttons\\UI-ActionButton-Border'

local Cursor = CreateFrame('Frame', 'MyNavigateCursor', UIParent)
Cursor:SetFrameStrata('TOOLTIP')
Cursor:SetSize(1, 1)
Cursor:Hide()

local ring = Cursor:CreateTexture(nil, 'OVERLAY')
ring:SetTexture(RING_TEXTURE)
ring:SetBlendMode('ADD')
ring:SetVertexColor(1, 0.88, 0.1)
ring:Hide()
Cursor.ring = ring

local label = Cursor:CreateFontString(nil, 'OVERLAY')
label:SetFont(STANDARD_TEXT_FONT or 'Fonts\\FRIZQT__.TTF', 11, 'OUTLINE')
label:SetTextColor(1, 0.88, 0.1)
label:SetJustifyH('LEFT')
label:Hide()
Cursor.label = label

ns.Cursor = Cursor

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
	return (pn and nn and pn:match('^ContainerFrame') and nn:match(pn..'Item')) and true
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

function Cursor:GetActionText(node)
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
	return ('A %s  B %s  X %s  Y %s'):format(name('A'), name('B'), name('X'), name('Y'))
end

function Cursor:SetHighlight(node)
	self.ring:ClearAllPoints()
	self.ring:SetPoint('TOPLEFT', node, 'TOPLEFT', -6, 6)
	self.ring:SetPoint('BOTTOMRIGHT', node, 'BOTTOMRIGHT', 6, -6)
	self.ring:Show()
end

function Cursor:SetPosition(node)
	self:SetHighlight(node)
	self:ClearAllPoints()
	self:SetPoint('CENTER', node, 'CENTER', 0, 0)
	self.label:SetText(self:GetActionText(node))
	self.label:ClearAllPoints()
	self.label:SetPoint('BOTTOMLEFT', node, 'TOPRIGHT', 4, 2)
	self.label:Show()
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
end

function Cursor:HideNode()
	RunScript(lastNode, 'OnLeave')
	lastNode, current = nil, nil
	self.label:Hide()
	self:Hide()
	self.ring:Hide()
end

-- 重新扫描所有白名单窗口，并重算当前节点
function Cursor:Refresh()
	local roots = ns.GetRootFrames()
	Node:ClearCache()
	Node:RunScan(unpack(roots))
	current = Node:GetArbitraryCandidate(current, current, self:GetCenter())
	local names = {}
	for i = 1, #roots do names[i] = roots[i]:GetName() or '?' end
	Debug('面板', #roots, '['..table.concat(names, ',')..']', '节点', #Node.cache, '当前',
		current and (current.node:GetName() or current.object) or 'nil')
	-- 只有真正存在可导航节点时才处于导航模式；面板全关或没有可用节点时，
	-- 按键处理器会把 1~8 还原成原始功能（动作条）。1~8 的覆盖绑定是常驻的，
	-- 不随窗口开关变动，因此在战斗中同样有效。
	ns.navActive = (#Node.cache > 0)
	if current then
		self:SetNode(current.node, current.object, current.super)
	else
		self:HideNode()
	end
end

-- 方向键入口：刷新后按方向选最优候选；没有合适的就退化为「同方向上最近的节点」
function Cursor:UIControl(key, state)
	self:Refresh()
	if state == KEY.STATE_DOWN and current then
		local changed
		current, changed = Node:GetBestCandidate(current, key)
		if not changed then
			current = Node:GetClosestCandidate(current, key)
		end
	end
	if current then
		self:SetNode(current.node, current.object, current.super)
	end
	return current and current.node
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
		elseif node.Click then
			pcall(node.Click, node, 'LeftButton')
		end
	elseif mapped and node.Click then
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

-- 把光标直接落到指定根窗口里的第一个节点：窗口刚打开时自动选中用
function Cursor:SelectRoot(root)
	for i = 1, #Node.cache do
		local item = Node.cache[i]
		if IsDescendant(item.node, root) then
			current = item
			self:SetNode(item.node, item.object, item.super)
			return true
		end
	end
	return false
end

-- 当前节点消失（窗口被关掉）时自动收起光标
Cursor:SetScript('OnUpdate', function(self, elapsed)
	self.Timer = (self.Timer or 0) + elapsed
	if self.Timer < 0.1 then return end
	self.Timer = 0
	if current and not current.node:IsVisible() then
		self:HideNode()
	end
end)
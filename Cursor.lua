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

function Cursor:Refresh()
	local roots = ns.GetRootFrames()
	Node:ClearCache()
	Node:RunScan(unpack(roots))
	current = Node:GetArbitraryCandidate(current, current, self:GetCenter())
	Debug('面板', #roots, '节点', #Node.cache, '当前',
		current and (current.node:GetName() or current.object) or 'nil')
	if current then
		self:SetNode(current.node, current.object, current.super)
	else
		self:HideNode()
	end
end

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

Cursor:SetScript('OnUpdate', function(self, elapsed)
	self.Timer = (self.Timer or 0) + elapsed
	if self.Timer < 0.1 then return end
	self.Timer = 0
	if current and not current.node:IsVisible() then
		self:HideNode()
	end
end)
---------------------------------------------------------------------
-- Node.lua: 节点扫描 + 方向选择算法（移植自 ConsolePort Drivers/UINode.lua）
---------------------------------------------------------------------
-- 1) 递归扫描可见 frame：可交互控件 → 导航节点；其它可见 frame → 遮挡矩形
-- 2) RunScan 结束后用遮挡矩形剔除被盖住的节点
-- 3) 选目标：先用曼哈顿距离做「方向过滤」，再用欧氏距离取最优；
--    上下键把横向距离放大 scalar 倍、左右键把纵向放大，
--    让方向偏移小的节点优先，避免斜跳
---------------------------------------------------------------------
local ADDON, ns = ...

local KEY = { UP = 1, DOWN = 2, LEFT = 3, RIGHT = 4 }
ns.KEY = KEY

local vec2Dlen = function(x, y) return math.sqrt(x * x + y * y) end
local abs, floor = math.abs, math.floor
local tinsert, tremove, ipairs, next = table.insert, table.remove, ipairs, next

local MAX_X, MAX_Y = UIParent:GetSize()
UIParent:HookScript('OnSizeChanged', function(_, x, y) MAX_X, MAX_Y = x, y end)

local function IsMouseEnabled(frame)
	if frame.IsMouseEnabled then return frame:IsMouseEnabled() end
	return true
end

if not UIDoFramesIntersect then
	function UIDoFramesIntersect(f1, f2)
		local l1, b1, w1, h1 = f1:GetLeft(), f1:GetBottom(), f1:GetWidth(), f1:GetHeight()
		local l2, b2, w2, h2 = f2:GetLeft(), f2:GetBottom(), f2:GetWidth(), f2:GetHeight()
		if not (l1 and b1 and l2 and b2 and w1 and w2 and h1 and h2) then return false end
		local r1, t1, r2, t2 = l1 + w1, b1 + h1, l2 + w2, b2 + h2
		return not (r1 < l2 or r2 < l1 or t1 < b2 or t2 < b1)
	end
end

local Node = {
	-- 方向过滤：只要求目标在指定方向上。
	-- 这里不再额外要求「垂直距离大于水平距离」（旧写法是 vert > horz）：
	-- 按钮宽度不一致时（如 Immersion 的对话选项，中心 x 相差几十像素），
	-- 行距只有几十像素，水平偏移一超过行距，中间几行就会被整行跳过，
	-- 表现为「按下从第 1 个直接跳到第 4 个」。去掉门槛后只用下面的加权距离比大小，
	-- 与 SimpleCursor 的做法一致（它也是只看方向 + 加权代价）。
	distance = {
		[KEY.UP]    = function(_, destY, _, _, _, thisY) return (destY > thisY) end,
		[KEY.DOWN]  = function(_, destY, _, _, _, thisY) return (destY < thisY) end,
		[KEY.LEFT]  = function(destX, _, _, _, thisX, _) return (destX < thisX) end,
		[KEY.RIGHT] = function(destX, _, _, _, thisX, _) return (destX > thisX) end,
	},
	direction = {
		[KEY.UP]    = function(_, destY, _, _, _, thisY) return (destY > thisY) end,
		[KEY.DOWN]  = function(_, destY, _, _, _, thisY) return (destY < thisY) end,
		[KEY.LEFT]  = function(destX, _, _, _, thisX, _) return (destX < thisX) end,
		[KEY.RIGHT] = function(destX, _, _, _, thisX, _) return (destX > thisX) end,
	},
	level = {
		BACKGROUND = 0x00000, LOW = 0x02710, MEDIUM = 0x04E20, HIGH = 0x07530,
		DIALOG = 0x09C40, FULLSCREEN = 0x0C350, FULLSCREEN_DIALOG = 0x0EA60, TOOLTIP = 0x11170,
	},
	usable = { Button = true, CheckButton = true, EditBox = true, Slider = true },
	cache = {}, rects = {}, scalar = 3, -- scalar: 轴向距离放大倍数（越大越「不斜跳」）
	-- 扫描用的显式栈（复用，避免每次扫描新建；见 Node:Scan 注释）
	_stackNode = {}, _stackSuper = {},
}
ns.Node = Node

function Node:IsMouseEvent(node)
	return node.GetScript and (node:GetScript('OnEnter') or node:GetScript('OnMouseDown')) and true
end

function Node:IsUsable(object) return self.usable[object] end

-- mouseEnabled 可由调用方预先算好（Scan 里同一个节点要用到两次），不传则自己取
function Node:IsInteractive(node, object, mouseEnabled)
	if mouseEnabled == nil then mouseEnabled = IsMouseEnabled(node) end
	return not node.includeChildren and mouseEnabled
		and (self:IsUsable(object) or self:IsMouseEvent(node))
end

-- 滚动条（ScrollFrame 下的 Slider）不是有意义的操作目标，排除在导航之外
local function IsScrollBar(node)
	if node.GetObjectType and node:IsObjectType('Slider') then
		local parent = node.GetParent and node:GetParent()
		return (parent and parent.GetObjectType and parent:IsObjectType('ScrollFrame')) and true or false
	end
	return false
end

function Node:IsRelevant(node)
	return node and not node.ignoreNode and node:IsVisible() and not IsScrollBar(node)
end

function Node:IsTree(node) return not node.ignoreChildren end

function Node:IsDrawn(node, super)
	local x, y = node:GetCenter()
	if self:PointInRange(x, 0, MAX_X) and self:PointInRange(y, 0, MAX_Y) then
		if super and super.GetScrollChild and super:GetScrollChild() and not node:IsObjectType('Slider') then
			return UIDoFramesIntersect(node, super)
		else
			return true
		end
	end
end

function Node:GetSuperNode(super, node)
	return node:IsObjectType('ScrollFrame') and node or super
end

-- 把一批同级帧按逆序压入显式栈。这里的多值来自 GetChildren()，
-- 本客户端 GetChildren() 直接返回多值，用 ... 接收再 select 逐个取出，
-- 既不用为每个父帧新建一张子帧表，也不会把剩下的兄弟参数层层转发。
local function PushNodes(nodes, supers, top, super, ...)
	for i = select('#', ...), 1, -1 do
		top = top + 1
		nodes[top], supers[top] = select(i, ...), super
	end
	return top
end

-- 迭代式扫描（原来是「变长参数兄弟递归」）：
-- 原写法把同级帧用 ... 逐层转发，同级 N 帧时总拷贝量约 N²/2；且两个递归都不是尾调用，
-- 宽窗口（背包/法术书/成就）会把 Lua 栈顶到上千层，栈增长要一次性分配一大块内存。
-- 改成显式栈后，栈只是 Node 上复用的一张普通表，深度只跟树的层数有关，也不再重复拷贝兄弟参数。
function Node:Scan(roots)
	local nodes, supers = self._stackNode, self._stackSuper
	local top = 0
	for i = #roots, 1, -1 do
		top = top + 1
		nodes[top], supers[top] = roots[i], nil
	end
	while top > 0 do
		local node, super = nodes[top], supers[top]
		nodes[top], supers[top] = nil, nil
		top = top - 1
		if self:IsRelevant(node) then
			local object, level = node:GetObjectType(), self:GetFrameLevel(node)
			local mouseEnabled = IsMouseEnabled(node)
			if self:IsDrawn(node, super) then
				if self:IsInteractive(node, object, mouseEnabled) then
					self:CacheItem(node, object, super, level)
				elseif mouseEnabled then
					self:CacheRect(node, level)
				end
			end
			if self:IsTree(node) then
				top = PushNodes(nodes, supers, top, self:GetSuperNode(super, node), node:GetChildren())
			end
		end
	end
end

-- rects 按 level 降序排（RunScan 末尾统一排序）。ScrubCache 只需要看「level 比自己高」的 rect，
-- 用二分找到分界点，避免每个节点都从头线性扫（原来还带一次逐层的 break 判断）。
function Node:GetRectBound(level)
	local rects, lo, hi = self.rects, 1, #self.rects
	while lo <= hi do
		local mid = floor((lo + hi) / 2)
		if rects[mid].level > level then
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return lo
end

-- 判断 a 是不是 b 自身或 b 的祖先。
-- 遮挡剔除时用：按钮自己的装饰子帧（setAllPoints 的 Overlay/Hilite 之类）也会
-- 覆盖按钮中心，但那属于控件自己的一部分，不是挡在它前面的东西，不能据此把按钮删掉。
local function IsAncestor(a, b)
	local f = b
	while f do
		if f == a then return true end
		f = f.GetParent and f:GetParent()
	end
	return false
end

function Node:ScrubCache(i, item)
	while item do
		local node, level = item.node, item.level
		for index = 1, self:GetRectBound(level) - 1 do
			local rect = self.rects[index]
			if self:DoNodeAndRectIntersect(node, rect)
				and not IsAncestor(rect.node, node) and not IsAncestor(node, rect.node) then
				i = self:RemoveCacheItem(i)
				break
			end
		end
		i, item = self:GetNextCacheItem(i)
	end
end

local function SortRectsByLevel(a, b) return a.level > b.level end

function Node:RunScan(roots)
	self:Scan(roots)
	-- rects 逐个有序插入是 O(n²)，改成尾部追加 + 扫描结束统一排序
	table.sort(self.rects, SortRectsByLevel)
	self:ScrubCache(self:GetNextCacheItem(nil))
	return self.cache
end

function Node:CacheItem(node, object, super, level)
	self:CacheRect(node, level)
	tinsert(self.cache, { node = node, object = object, super = super, level = level })
end

function Node:CacheRect(node, level)
	tinsert(self.rects, { node = node, level = level })
end

function Node:RemoveCacheItem(cacheIndex)
	tremove(self.cache, cacheIndex)
	return cacheIndex - 1
end

function Node:ClearCache() wipe(self.cache); wipe(self.rects) end
function Node:HasItems() return #self.cache > 0 end
function Node:GetNextCacheItem(i) return next(self.cache, i and i > 0 and i or nil) end

function Node:GetFirstEligibleCacheItem()
	for _, item in self:IterateCache() do
		local node = item.node
		if node:IsVisible() and self:IsDrawn(node, item.super) then return item end
	end
end

function Node:IterateCache() return ipairs(self.cache) end

function Node:GetDistance(x1, y1, x2, y2) return abs(x1 - x2), abs(y1 - y2) end
function Node:GetDistanceSum(...) local x, y = self:GetDistance(...); return x + y end
function Node:GetFrameLevel(node) return (self.level[node:GetFrameStrata()] or 0) + node:GetFrameLevel() end
function Node:PointInRange(pt, min, max) return pt and pt >= min and pt <= max end

function Node:DoNodeAndRectIntersect(node, rect)
	local x, y = node:GetCenter()
	local r = rect.node
	return self:PointInRange(x, r:GetLeft(), r:GetRight())
		and self:PointInRange(y, r:GetBottom(), r:GetTop())
end

-- 方向选择：直接在缓存上遍历、只保留「当前最优」，不再为每个候选建 {x,y,h,v} 表
-- （原来一次按键要分配 N 张小表 + 一张候选表，是高频 GC 的来源之一）。
-- 注意：返回的是缓存项 item（含 node/object/super），而不是帧本身，
-- 调用方 Cursor:MoveTo 需要的是 item。
function Node:GetBestCandidate(cur, key, curNodeChanged)
	local comparator = self.distance[key]
	if not (cur and comparator) then return cur, curNodeChanged end
	local thisX, thisY = cur.node:GetCenter()
	local hMult = (key == KEY.UP or key == KEY.DOWN) and self.scalar or 1
	local vMult = (key == KEY.LEFT or key == KEY.RIGHT) and self.scalar or 1
	local bestDist
	for _, destination in self:IterateCache() do
		local destX, destY = destination.node:GetCenter()
		if destX and destY then
			local distX, distY = self:GetDistance(thisX, thisY, destX, destY)
			if comparator(destX, destY, distX, distY, thisX, thisY) then
				local dist = vec2Dlen(distX * hMult, distY * vMult)
				if not bestDist or dist < bestDist then
					bestDist, cur, curNodeChanged = dist, destination, true
				end
			end
		end
	end
	return cur, curNodeChanged
end

function Node:GetClosestCandidate(cur, key, curNodeChanged)
	local comparator = self.direction[key]
	if not (cur and comparator) then return cur, curNodeChanged end
	local thisX, thisY = cur.node:GetCenter()
	local bestDist
	for _, destination in self:IterateCache() do
		local destX, destY = destination.node:GetCenter()
		if destX and destY then
			local distX, distY = self:GetDistance(thisX, thisY, destX, destY)
			if comparator(destX, destY, distX, distY, thisX, thisY) then
				local dist = vec2Dlen(distX, distY)
				if not bestDist or dist < bestDist then
					bestDist, cur = dist, destination
				end
			end
		end
	end
	return cur, curNodeChanged
end

function Node:GetArbitraryCandidate(cur, old, x, y)
	return (old and self:IsRelevant(old.node) and self:IsDrawn(old.node, old.super)) and old or
		(cur and self:IsRelevant(cur.node) and self:IsDrawn(cur.node, cur.super)) and cur or
		(not x or not y) and self:GetFirstEligibleCacheItem() or
		(self:HasItems()) and self:GetPriorityCandidate(x, y)
end

function Node:GetPriorityCandidate(x, y)
	local targNode, targDist, targPrio
	for _, this in self:IterateCache() do
		local nx, ny = this.node:GetCenter()
		local thisDist = self:GetDistanceSum(x, y, nx, ny)
		local thisPrio = this.node.hasPriority
		if thisPrio and not targPrio then
			targNode = this
			break
		elseif not targNode or (not targPrio and thisDist < targDist) then
			targNode = this
			targDist = thisDist
			targPrio = thisPrio
		end
	end
	return targNode
end
-- Persistent vector implementation for Lua 5.2/LuaJIT
--
-- based on PVec.java by hyPiRion(jeannikl@hypirion.com), see https://github.com/hyPiRion/pvec-perf
-- ported by Ilya Kolbin (iskolbin@gmail.com)
--
-- Needs LuaJIT bitOp or Lua 5.2 bit32 library to work

local floor, assert, setmetatable = math.floor, _G.assert, _G.setmetatable
local unpack = table.unpack or _G.unpack

-- TODO fallbacks for 5.1 and shift ops for 5.3
local shr = (bit or bit32).arshift
local shl = (bit or bit32).lshift
local xor = (bit or bit32).bxor

local EMPTY_TAIL = {}

local PVec = {}

PVec.__index = PVec

local function newVec( size, shift, root, tail )
	return setmetatable( {
		size = size, 
		shift = shift, 
		root = root,
		tail = tail,
	}, PVec )
end

function PVec.new( t )
	local result = newVec( 0, 0, nil, EMPTY_TAIL )
	if t then
		for _, v in ipairs( t ) do
			result:transientPush( v )
		end
	end
	return result
end

local function copy( array, from, to )
	return {unpack( array, from, to )}
end

local function tailOffset( self )
	return 32 * floor((self.size-1) * (1/32))
end

local function tailSize( self )
	return self.size == 0 and 0 or (((self.size-1) % 32) + 1)
end

function PVec:set( i, val, transient )
	assert( i >= 1 and i <= self.size, 'Index out of bounds' )

	if i > tailOffset( self ) then
		local newTail = copy( self.tail )
		newTail[(i-1) % 32 + 1] = val
		return newVec( self.size, self.shift, self.root, newTail )
	else
		local newRoot = copy( self.root )
		local node = newRoot
		for level = self.shift, 1, -5 do
			local subidx = shr(i-1, level) % 32 + 1
			local child = copy( node[subidx] )
			node[subidx] = child
			node = child
		end
		node[(i-1) % 32 + 1] = val
		return newVec( self.size, self.shift, newRoot, self.tail )
	end
end

function PVec:get( i )
	assert( i >= 1 and i <= self.size, 'Index out of bounds' )

	if i > tailOffset( self ) then
		return self.tail[(i-1) % 32 + 1]
	else
		local node = self.root
		for level = self.shift, 1, -5 do
			node = node[shr(i-1,level) % 32 + 1]
		end
		return node[(i-1) % 32 + 1]
	end
end

local function newPath( levels, tail )
	local topNode = tail
	for level = levels, 1, -5 do
		topNode = {topNode}
	end
	return topNode
end

local function pushLeaf( shift, i, root, tail, transient )
	local newRoot = transient and root or copy( root )
	local node = newRoot
	for level = shift, 6, -5 do
		local subidx = shr( i-1, level ) % 32 + 1
		local child = node[subidx]
		if child == nil then
			node[subidx] = newPath( level-5, tail )
			return newRoot
		end
		child = transient and child or copy( child )
		node[subidx] = child
		node = child
	end
	node[shr( i-1, 5 ) % 32 + 1] = tail
	return newRoot
end

function PVec:push( val, transient )
	local ts = tailSize( self )
	local size, shift = self.size, self.shift

	if ts ~= 32 then
		local newTail = copy( self.tail )
		newTail[#newTail+1] = val
		return newVec(size+1, shift, self.root, newTail )
	else
		if self.size == 32 then
			return newVec( size+1, 0, self.tail, {val} )
		elseif shr( size, 5 ) > shl( 1, shift ) then
			return newVec( size+1, shift + 5, {self.root, newPath( shift, self.tail)}, {val} )
		else
			return newVec( size+1, shift, pushLeaf( shift, size-1, self.root, self.tail ), {val} )
		end
	end
end

local function lowerTrie( self, transient )
	local lowerShift = self.shift - 5
	local node = self.root[2]
	for level = lowerShift, 1, -5 do
		node = node[1]
	end
	if transient then
		self.root, self.tail, self.size = self.root[1], node, self.size-1
		return self
	else
		return newVec( self.size-1, lowerShift, self.root[1], node )
	end
end

local function popTrie( self, transient )
	local newSize = self.size - 33
	local diverges = xor( newSize , newSize - 1 )
	local diverged = false
	local newRoot = transient and self.root or copy( self.root )
	local node = newRoot
	for level = self.shift, 1, -5 do
		local subidx = shr( newSize-1, level ) % 32 + 1
		local child = node[subidx]
		if diverged then
			node = child
		elseif shr( diverges, level ) ~= 0 then
			diverged = true
			node[subidx] = nil
			node = child
		else
			child = transient and child or copy( child )
			node[subidx] = child
			node = child
		end
	end
	if transient then
		self.tail, self.size = node, self.size-1
		return self
	else
		return newVec( self.size-1, self.shift, newRoot, node )
	end
end

function PVec:pop()
	local size = self.size
	assert( size > 0, 'Vector is empty' )

	if ((size-1) % 32) >= 0 then
		return newVec( size-1, self.shift, self.root, copy( self.tail, 1, #self.tail-1 ))
	else
		if size == 33 then
			return newVec( 32, 0, nil, self.tail )
		elseif size - 33 == shl( 1, self.shift ) then
			return lowerTrie( self )
		else
			return popTrie( self )
		end
	end
end

function PVec:transientSet( i, val )
	if i > tailOffset( self ) then
		self.tail[(i-1) % 32 + 1] = val
	else
		local node = self.root
		for level = self.shift, 1, -5 do
			node = node[shr(i-1, level) % 32 + 1]
		end
		node[(i-1) % 32 + 1] = val
	end
	return self
end

function PVec:transientPush( val )
	local ts = tailSize( self )
	local size, shift = self.size, self.shift

	if ts ~= 32 then
		self.tail[#self.tail+1] = val
	else
		if self.size == 32 then
			self.root = self.tail
		elseif shr( size, 5 ) > shl( 1, shift ) then
			self.root, self.shift = newPath( shift, self.tail ), shift + 5
		else
			self.root = pushLeaf( shift, size-1, self.root, self.tail, true )
		end
		self.tail = {val}
	end
	self.size = self.size + 1
	return self
end

function PVec:transientPop()
	local size = self.size
	assert( size > 0, 'Vector is empty' )

	if ((size-1) % 32) >= 0 then
		self.tail[#self.tail], self.size = nil, size - 1
	else
		if size == 33 then
			self.root, self.size = nil, 32
		elseif size - 33 == shl( 1, self.shift ) then
			lowerTrie( self, true )
		else
			popTrie( self, true )
		end
	end
	return self
end

function PVec:len()
	return self.size
end

function PVec:ipairs()
	local size = self.size
	local shift = self.shift
	local tail = self.tail
	local index = 0
	local jump = 33
	local stack
	local leaf
	local toffset = tailOffset( self )

	if size <= 32 then
		leaf = self.tail
	elseif size <= 64 then
		leaf = self.root
	else
		local m = floor( shift/5 )
		stack = {}
		for i = 1, m do
			stack[i] = {}
		end
		stack[m] = self.root
		for i = m-1, 1, -1 do
			stack[i] = stack[i+1][1]
		end
		leaf = stack[1][1]
	end

	return function( _, i )
		i = (i or 0) + 1
		if i <= size then
			if i == jump then
				if i >= toffset then
					leaf = tail
				else
					jump = jump + 32
					local diff = xor( i, i-1 )
					local level = 10
					local stackupd = 0
					while shr( diff, level ) ~= 0 do
						stackupd = stackupd + 1
						level = level + 5
					end
					level = level - 5
					while stackupd > 0 do
						stack[stackupd] = stack[stackupd][shr(i-1,level) % 32 + 1]
						stackupd = stackupd - 1
						level = level - 5
					end
					leaf = stack[1][shr(i-1,5) % 32 + 1]
				end
			end
			return i, leaf[(i-1) % 32 + 1]
		end
	end
end

function PVec:map( f )
	local result = PVec.new()
	for i, v in self:ipairs() do
		result:transientPush( f(v,i,self) )
	end
	return result
end

function PVec:filter( p )
	local result = PVec.new()
	for i, v in self:ipairs() do
		if p(v,i,self) then
			result:transientPush( v )
		end
	end
	return result
end

function PVec:reduce( f, acc )
	for i, v in self:ipairs() do
		acc, stop = f(v,acc,i,self)
		if stop then break end
	end
	return acc
end

function PVec:array()
	local result = {}
	for i, v in self:ipairs() do
		result[i] = v
	end
	return result
end

function PVec:__pairs()
	return self:ipairs()
end

function PVec:__ipairs()
	return self:ipairs()
end

function PVec:__len()
	return self:len()
end

return setmetatable( PVec, {__call = function(_, ...)
	return PVec.new( ... )
end})

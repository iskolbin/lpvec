local PVec = require('PVec')
local vec = PVec()
for i = 1, 2^10 do
	vec = vec:push( i )
	assert( vec:get( i ) == i )
	vec = vec:set( i, -i )
	assert( vec:get( i ) == -i )
	vec = vec:set( i, i )
end

for i = 1, 2^10 do
	assert( vec:get( i ) == i, tostring(vec:get(i)) .. '~=' .. tostring(i) )
end

for i = 2^10, 1, -1 do
	assert( vec.size == i )
	vec = vec:pop()
end

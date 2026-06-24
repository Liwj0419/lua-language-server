---@class vm
local vm        = require 'vm.vm'
local files     = require 'files'
local util      = require 'utility'
local guide     = require 'parser.guide'
local rpath     = require 'workspace.require-path'

local function isStringListTable(source)
    if not source or source.type ~= 'table' then
        return false
    end
    local hasString
    for _, field in ipairs(source) do
        if field.type ~= 'tableexp'
        or not field.value
        or field.value.type ~= 'string' then
            return false
        end
        hasString = true
    end
    return hasString
end

local function collectStringList(source, results, mark)
    if not isStringListTable(source) then
        return
    end
    for _, field in ipairs(source) do
        local name = field.value[1]
        if type(name) == 'string' and not mark[name] then
            mark[name] = true
            results[#results+1] = name
        end
    end
end

local searchByNodeSwitch = util.switch()
    : case 'global'
    ---@param globalVar vm.global
    : call(function (suri, globalVar, pushResult)
        for _, set in ipairs(globalVar:getSets(suri)) do
            pushResult(set)
        end
    end)
    : default(function (_suri, source, pushResult)
        pushResult(source)
    end)

local function searchByLocalID(source, pushResult)
    local fields = vm.getVariableFields(source, true)
    if fields then
        for _, field in ipairs(fields) do
            pushResult(field)
        end
    end
end

local function searchByNode(source, pushResult, mark)
    mark = mark or {}
    if mark[source] then
        return
    end
    mark[source] = true
    local uri = guide.getUri(source)
    vm.compileByParentNode(source, vm.ANY, function (field)
        searchByNodeSwitch(field.type, uri, field, pushResult)
    end)
    vm.compileByNodeChain(source, function (src)
        searchByNode(src, pushResult, mark)
    end)
end

local function eachLocalAssignedTo(source, callback)
    guide.eachSource(guide.getRoot(source), function (src)
        if src.type ~= 'local'
        and src.type ~= 'setlocal' then
            return
        end
        if src.value == source then
            callback(src)
        end
    end)
end

local function searchHostFields(source, callback)
    local searched = {}

    local function pushField(field)
        if not searched[field] then
            searched[field] = true
            callback(field)
        end
    end

    searchByLocalID(source, pushField)
    searchByNode(source, pushField)

    eachLocalAssignedTo(source, function (src)
        searchByLocalID(src, pushField)
        searchByNode(src, pushField)
    end)
end

local function collectHostAliasNames(source, names)
    eachLocalAssignedTo(source, function (src)
        local name = guide.getKeyName(src)
        if name then
            names[name] = true
        end
    end)
end

local function findRequireListNames(source)
    local cache = vm.getCache('fieldRequireListNames', true)
    if cache[source] ~= nil then
        return cache[source]
    end

    local names = {}
    local mark  = {}

    searchHostFields(source, function (field)
        collectStringList(field.value, names, mark)
        local func = vm.getObjectFunctionValue(field)
        if func and func.type == 'function' then
            guide.eachSource(func, function (src)
                if src.value then
                    collectStringList(src.value, names, mark)
                end
            end)
        end
    end)

    guide.eachSource(guide.getRoot(source), function (src)
        if src.type ~= 'local'
        and src.type ~= 'setlocal'
        and src.type ~= 'setfield'
        and src.type ~= 'setmethod'
        and src.type ~= 'setindex' then
            return
        end
        if not src.value or not isStringListTable(src.value) then
            return
        end
        local parent = src.parent
        while parent do
            if parent == source then
                collectStringList(src.value, names, mark)
                return
            end
            parent = parent.parent
        end
    end)

    cache[source] = names
    return names
end

local function getGlobalPath(source)
    if not source then
        return nil
    end
    if source.type == 'getglobal'
    or source.type == 'setglobal' then
        return guide.getKeyName(source)
    end
    if source.type ~= 'getfield'
    and source.type ~= 'setfield'
    and source.type ~= 'getmethod'
    and source.type ~= 'setmethod'
    and source.type ~= 'getindex'
    and source.type ~= 'setindex' then
        return nil
    end
    local parent = getGlobalPath(source.node)
    local key = guide.getKeyName(source)
    if not parent or not key then
        return nil
    end
    if parent == '_G' then
        return key
    end
    return parent .. vm.ID_SPLITE .. key
end

local function isSameGlobalObject(a, b)
    if a == b then
        return true
    end
    if not a or not b then
        return false
    end
    local an = vm.getVariableID(a)
    local bn = vm.getVariableID(b)
    if an and bn then
        return an == bn and guide.getUri(a) == guide.getUri(b)
    end
    local ag = vm.getGlobalNode(a)
    local bg = vm.getGlobalNode(b)
    if ag and bg then
        return ag == bg
    end
    local ap = getGlobalPath(a)
    local bp = getGlobalPath(b)
    if ap and bp then
        return ap == bp
    end
    return false
end

local function collectAliasNames(ast, source, names)
    guide.eachSource(ast, function (src)
        if src.type ~= 'local'
        and src.type ~= 'setlocal' then
            return
        end
        if src.value and isSameGlobalObject(src.value, source) then
            local name = guide.getKeyName(src)
            if name then
                names[name] = true
            end
        end
    end)
end

local function sourceStartsFromAlias(source, aliasNames)
    local root = source.node
    while root
    and (root.type == 'getfield'
      or root.type == 'setfield'
      or root.type == 'getmethod'
      or root.type == 'setmethod'
      or root.type == 'getindex'
      or root.type == 'setindex') do
        root = root.node
    end
    if not root then
        return false
    end
    if root.type == 'getlocal'
    and root.node then
        return aliasNames[root.node[1]]
    end
    if root.type == 'getglobal'
    or root.type == 'setglobal' then
        return aliasNames[root[1]]
    end
    return false
end

local function searchRequireListExtensionFields(source, pushResult)
    local cache = vm.getCache('fieldRequireListExtensionFields', true)
    if cache[source] ~= nil then
        for _, field in ipairs(cache[source]) do
            pushResult(field)
        end
        return
    end

    local fields    = {}
    local fieldMark = {}
    if not getGlobalPath(source) and not vm.getGlobalNode(source) then
        cache[source] = fields
        return
    end

    for host in vm.compileNode(source):eachObject() do
        if host.type == 'table' then
            local hostAliasNames = {}
            collectHostAliasNames(host, hostAliasNames)
            local requireNames = findRequireListNames(host)
            if #requireNames > 0 then
                for _, requireName in ipairs(requireNames) do
                    local uri = rpath.findUrisByRequireName(guide.getUri(source), requireName)[1]
                    local state = uri and files.getState(uri)
                    local ast = state and state.ast
                    if ast then
                        local aliasNames = {}
                        collectAliasNames(ast, source, aliasNames)
                        if not next(aliasNames) then
                            for name in pairs(hostAliasNames) do
                                aliasNames[name] = true
                            end
                        end
                        if next(aliasNames) then
                            guide.eachSource(ast, function (src)
                                if src.type ~= 'setfield'
                                and src.type ~= 'setmethod'
                                and src.type ~= 'setindex' then
                                    return
                                end
                                if not sourceStartsFromAlias(src, aliasNames) then
                                    return
                                end
                                if not fieldMark[src] then
                                    fieldMark[src] = true
                                    fields[#fields+1] = src
                                    pushResult(src)
                                end
                            end)
                        end
                    end
                end
            end
        end
    end

    cache[source] = fields
end

---@param source parser.object
---@return       parser.object[]
function vm.getFields(source)
    local results = {}
    local mark    = {}

    local function pushResult(src)
        if not mark[src] then
            mark[src] = true
            results[#results+1] = src
        end
    end

    searchByLocalID(source, pushResult)
    searchByNode(source, pushResult)
    searchRequireListExtensionFields(source, pushResult)

    return results
end

---@class vm
local vm        = require 'vm.vm'
local files     = require 'files'
local util      = require 'utility'
local guide     = require 'parser.guide'
local config    = require 'config'

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

local function normalizeGlobalPath(path)
    return path:gsub('%.', vm.ID_SPLITE)
end

local function matchConfiguredGlobalAliasPath(source)
    local path = getGlobalPath(source)
    if not path then
        return nil
    end
    local uri = guide.getUri(source)
    for _, configured in ipairs(config.get(uri, 'Lua.completion.globalAliasFields') or {}) do
        if path == normalizeGlobalPath(configured) then
            return configured
        end
    end
    return nil
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

local function searchConfiguredGlobalAliasFields(source, pushResult)
    local configured = matchConfiguredGlobalAliasPath(source)
    if not configured then
        return
    end

    local cache = vm.getCache('fieldConfiguredGlobalAliasFields', true)
    if cache[source] ~= nil then
        for _, field in ipairs(cache[source]) do
            pushResult(field)
        end
        return
    end

    local fields    = {}
    local fieldMark = {}
    for uri in files.eachFile() do
        local state = files.getState(uri)
        local ast = state and state.ast
        if ast then
            local aliasNames = {}
            collectAliasNames(ast, source, aliasNames)
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

    cache[source] = fields
end

function vm.searchConfiguredGlobalAliasFields(source, pushResult)
    searchConfiguredGlobalAliasFields(source, pushResult)
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
    vm.searchConfiguredGlobalAliasFields(source, pushResult)

    return results
end

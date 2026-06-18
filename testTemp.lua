package.path   = package.path
    .. ';./test/?.lua'
    .. ';./test/?/init.lua'
local fs       = require 'bee.filesystem'
local sys      = require 'bee.sys'
local rootPath = sys.exe_path():parent_path():parent_path():string()
print(rootPath)
ROOT = fs.path(rootPath)
print(ROOT)
TEST = true
DEVELOP = true
--FOOTPRINT = true
--TRACE = true
LOGPATH  = LOGPATH  or (ROOT:string() .. '/log')
METAPATH = METAPATH or (ROOT:string() .. '/meta')
TARGET_TEST_NAME = nil

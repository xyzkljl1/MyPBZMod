-- ModConfigUI: native settings tab for existing simple JSON configurations.
local VERSION = '1.0'
local ui = require('native_ui')
require('blueprint_config').start()
local page = require('config_page')
local menu = ui.menu(page)
ui.startInputEvents()
require('menu_events').start(menu, page)
ui.log('v' .. VERSION .. ' loaded. Simple/schema settings enabled; native menu and input events; no control polling.')

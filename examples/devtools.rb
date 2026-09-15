# frozen_string_literal: true
# backtick_javascript: true
# Emerald 桌面 + DevTools 内置 App（M5 系统内自省）：DevTools 不再是旁挂浮层，
# 而是普通 Emerald 应用——经窗口系统开窗口，实时调试同桌面的应用（此处为计算器）。
# 运行：cd citrine && bin/citrine dev ../emerald/examples -I ../beryl/lib -I ../emerald/lib
# 打开 http://127.0.0.1:4402/devtools.html ——开机自启计算器与 DevTools 两个窗口。
require 'citrine/browser'
require 'citrine/debug'
require 'emerald'
require_relative 'apps/calculator/src/main'
require_relative 'apps/stickynote/src/main'
require_relative 'apps/devtools/main'

# 探针开关在入口打开（App 内不重复开关）
Citrine.debug_tracking = true

shell = Emerald::DesktopShell.new
shell.registry.register(Calculator)
shell.registry.register(StickyNote)
shell.registry.register(DevToolsApp)
Beryl::Renderer.mount_at('app', shell)
# 组件树探针的遍历入口：先于 App 窗口渲染抓好桌面根节点——
# root_node 记录最后挂载的顶层组件，窗口渲染后再取会被覆盖
CITRINE_DEVTOOLS_ROOT = Citrine.renderer.root_node

# 调试对象：计算器窗口；DevTools 自开调试窗口，面向桌面根做系统内自省
shell.launch_app(:calculator)
shell.launch_app(:devtools)

# 浏览器验收便利（E7）：console 里可经 window.EmeraldShell 操作桌面
`window.EmeraldShell = shell` if defined?(Opal)

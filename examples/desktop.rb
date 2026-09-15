# frozen_string_literal: true
# backtick_javascript: true
# Emerald OS 整机示例（浏览器）——演示页即整机（docs/PLAN.md §7）
# 运行：在 citrine 仓库执行 bin/citrine dev ../emerald/examples -I ../beryl/lib -I ../emerald/lib
# 编译（emerald/ 目录内）：bundle exec rake compile
require 'citrine/browser'
require 'emerald'
require_relative 'apps/calculator/src/main'
require_relative 'apps/stickynote/src/main'

# 整机入口：DesktopShell 组装壁纸 / 图标网格 / 菜单栏 / 任务栏 / 多窗口与全部系统服务
shell = Emerald::DesktopShell.new
# 示例包（examples/apps/*，SPEC 裸目录形态）手工注册——E7 Installer
# 落地后改由 /Applications 扫描自动完成
shell.registry.register(Calculator)
shell.registry.register(StickyNote)
Beryl::Renderer.mount_at('app', shell)

# 浏览器验收便利（E7）：console 里可经 window.EmeraldShell 调安装流
`window.EmeraldShell = shell` if defined?(Opal)

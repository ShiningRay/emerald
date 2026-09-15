# frozen_string_literal: true
# backtick_javascript: true
# Emerald OS 整机示例（浏览器）——演示页即整机（docs/PLAN.md §7）
# 运行：在 citrine 仓库执行 bin/citrine dev ../emerald/examples -I ../beryl/lib -I ../emerald/lib
# 编译（emerald/ 目录内）：bundle exec rake compile
require 'citrine/browser'
require 'emerald'
require_relative 'apps/calculator/src/main'
require_relative 'apps/stickynote/src/main'
require_relative 'apps/agentos/src/main'

# AgentOS 包 World 窗口「开窗」按钮调 ctx[:launcher].launch：裸 AppRegistry#launch
# 只建实例不开窗（D3，开窗归 DesktopShell#launch_app）。开发期桥接——launch 导向
# shell.launch_app（建实例 + wm.open + 单例聚焦），其余消息原样委托 registry
# （About 等按 ctx[:launcher].apps 计数的消费者行为不变）。
class ShellLauncherBridge
  def initialize(shell)
    @shell = shell
  end

  def launch(id, **argv)
    @shell.launch_app(id, **argv)
  end

  def method_missing(name, *args, **kwargs, &block)
    return super unless @shell.registry.respond_to?(name)

    @shell.registry.public_send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @shell.registry.respond_to?(name, include_private) || super
  end
end

# 整机入口：DesktopShell 组装壁纸 / 图标网格 / 菜单栏 / 任务栏 / 多窗口与全部系统服务
shell = Emerald::DesktopShell.new
# 示例包（examples/apps/*，SPEC 裸目录形态）手工注册——E7 Installer
# 落地后改由 /Applications 扫描自动完成
shell.registry.register(Calculator)
shell.registry.register(StickyNote)
# AgentOS 桌面包（设计文档 agentos/docs/emerald-desktop-ui-design-2026-09-15.md）：
# 四个窗口 App 进注册表；LinkService 进 ServiceHub，并幂等补跑 activate_startup
# （shell 构造内的那次早于本注册）——桌面启动即开轮询，窗口只读其 signal
shell.registry.register(AgentOSDesk::AgentWindow)
shell.registry.register(AgentOSDesk::ServiceWindow)
shell.registry.register(AgentOSDesk::InboxWindow)
shell.registry.register(AgentOSDesk::WorldWindow)
shell.hub.register(AgentOSDesk::LinkService)
shell.hub.activate_startup(shell.services)
shell.services[:launcher] = ShellLauncherBridge.new(shell)
Beryl::Renderer.mount_at('app', shell)

# 浏览器验收便利（E7）：console 里可经 window.EmeraldShell 调安装流
`window.EmeraldShell = shell` if defined?(Opal)

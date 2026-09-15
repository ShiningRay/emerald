# frozen_string_literal: true

# AgentOS 桌面包 entry（docs/SPEC-package-format.md §4.1）——
# AgentOSDesk 命名空间的开发期装载点：1 个连线服务 + 4 个窗口 App。
#
# 装载方式（README「已知限制」）：
# - 开发期（examples/desktop.rb / CRuby 单测）：require 'emerald' 已完成，
#   本文件经 require_relative 串起五个组件文件；
# - .emz / AppHost 懒加载求值路径下 require_relative 不可用（entry 被
#   Opal.compile 单独编译，包内文件不在 load path）——打包前须合并为
#   单文件 entry 或扩展 AppHost，见包 README。
require 'emerald'
require_relative 'link'
require_relative 'agent_window'
require_relative 'service_window'
require_relative 'inbox_window'
require_relative 'world_window'

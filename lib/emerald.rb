# frozen_string_literal: true

# Emerald — Beryl 桌面外壳之上的 Web 桌面操作系统。
# 分层、里程碑与库法则见 docs/PLAN.md（唯一规划事实源）。
#
# 纪律（与 beryl 同款）：系统服务与应用逻辑纯 CRuby 可测（beryl F5）；
# Opal/JS 代码只允许出现在适配层（storage/theme 内部），且 defined?(Opal) 守卫。
module Emerald
  VERSION = '0.1.0'
end

require 'citrine'
require 'beryl'
require_relative 'emerald/storage'
require_relative 'emerald/file_pick'
require_relative 'emerald/settings'
require_relative 'emerald/vfs'
require_relative 'emerald/router'
require_relative 'emerald/notify'
require_relative 'emerald/hotkey'
require_relative 'emerald/clipboard'
require_relative 'emerald/theme'
require_relative 'emerald/pkg'
require_relative 'emerald/packages'
require_relative 'emerald/commands'
require_relative 'emerald/service'
require_relative 'emerald/app'
require_relative 'emerald/runtime'
require_relative 'emerald/standalone'
require_relative 'emerald/apps/about'
require_relative 'emerald/apps/files'
require_relative 'emerald/apps/editor'
require_relative 'emerald/apps/settings'
require_relative 'emerald/apps/terminal'
require_relative 'emerald/shell'

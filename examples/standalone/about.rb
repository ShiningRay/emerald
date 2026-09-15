# frozen_string_literal: true
# backtick_javascript: true
# 独立宿主示例：Emerald 应用脱离桌面外壳单独运行（Emerald::Standalone）。
# 整机外壳见 desktop.rb；本示例演示同一应用经 Standalone 宿主直挂页面。
# 编译（emerald/ 目录内）：bundle exec rake standalone
require 'citrine/browser'
require 'emerald'

# Standalone.boot 传类：内部自建 Runtime + 实例化 + 引导，返回可挂载的宿主组件
Beryl::Renderer.mount_at('app', Emerald::Standalone.boot(Emerald::Apps::About))

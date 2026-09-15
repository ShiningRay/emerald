# frozen_string_literal: true

# E1 · 关于应用单测：manifest 宏 + 版本/组件渲染（docs/PLAN.md §3.2 应用框架首个消费者）
# 纯 CRuby（beryl F5）：StringRenderer 渲染断言。
require 'minitest/autorun'
require 'emerald'

class AboutTest < Minitest::Test
  def test_manifest_macros
    assert_equal :about, Emerald::Apps::About.app_id
    assert_equal '关于', Emerald::Apps::About.app_title
    assert_equal '◈', Emerald::Apps::About.app_icon
    assert_equal true, Emerald::Apps::About.singleton
    assert_equal({ x: 200, y: 120, w: 380, h: 280 },
                 Emerald::Apps::About.default_geometry.call)
  end

  def test_render_contains_title_version_and_kernel
    html = Citrine.render(Emerald::Apps::About.new)
    assert_includes html, 'Emerald OS'
    assert_includes html, "Emerald 0.1.0 · Citrine #{Citrine::VERSION}"
    assert_includes html, 'Citrine', '内核说明应提及 Citrine/Beryl 技术栈'
    assert_includes html, 'Beryl'
  end

  def test_render_tolerates_missing_ctx
    html = Citrine.render(Emerald::Apps::About.new) # 未 boot：ctx nil
    assert_includes html, '已注册应用：—'
  end

  def test_render_shows_registered_app_count_via_launcher
    shell = Emerald::DesktopShell.new
    shell.registry.launch(:about)
    html = Citrine.render(shell.registry.instance(:about))
    assert_includes html, "已注册应用：#{shell.registry.apps.size}"
  end

  def test_booted_ctx_has_services
    shell = Emerald::DesktopShell.new
    inst = shell.launch_app(:about)
    assert_same shell.registry, inst.ctx[:launcher]
    assert_same shell.vfs, inst.ctx[:vfs]
  end
end

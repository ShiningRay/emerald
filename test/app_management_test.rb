# frozen_string_literal: true

# 应用管理（Settings「应用管理」区 + FilePick CRuby 语义 + shell 包管理能力面）
require 'minitest/autorun'
require 'emerald'

class AppManagementTest < Minitest::Test
  def render(component)
    Citrine.render(component)
  end

  # ── FilePick：CRuby 下无对话框可弹，返回 nil 且无副作用 ──

  def test_file_pick_is_noop_on_cruby
    called = false
    result = Emerald::FilePick.pick(accept: '.emz') { |_fn, _bytes| called = true }

    assert_nil result
    refute called
  end

  # ── Settings 应用管理区：ctx 容忍与列表渲染 ──────────────────

  def test_settings_renders_management_section_without_ctx
    html = render(Emerald::Apps::Settings.new)
    assert_includes html, '应用管理'
    assert_includes html, '安装 .emz 应用包'
    assert_includes html, '尚未安装第三方应用' # ctx 缺失 → 空态
  end

  def test_settings_lists_installed_apps_and_uninstall_button
    s = Emerald::Apps::Settings.new
    s.boot(installed_list: lambda {
      [{ 'id' => 'scientific-calculator', 'version' => '1.0.0', 'bundled' => false },
       { 'id' => 'about', 'version' => '1.0.0', 'bundled' => true }]
    }, uninstall: ->(_id) {})

    html = render(s)
    assert_includes html, 'scientific-calculator · v1.0.0'
    assert_includes html, '第三方'
    assert_includes html, '预装'
    assert_includes html, '卸载'
  end

  def test_settings_uninstall_invokes_service_and_bumps_rev
    uninstalled = []
    s = Emerald::Apps::Settings.new
    s.boot(installed_list: -> { [] }, uninstall: ->(id) { uninstalled << id })

    s.send(:uninstall_app, 'scientific-calculator')

    assert_equal ['scientific-calculator'], uninstalled
    assert_equal 1, s.apps_rev
  end

  # ── shell 能力面：包管理四键可调用 ──────────────────────────

  def test_shell_exposes_package_management_services
    shell = Emerald::DesktopShell.new
    svc = shell.services

    assert_respond_to svc[:install_bytes], :call
    assert_respond_to svc[:install_git], :call
    assert_respond_to svc[:uninstall], :call
    assert_kind_of Array, svc[:installed_list].call
  end
end

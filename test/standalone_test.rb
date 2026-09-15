# frozen_string_literal: true

# Emerald::Standalone 单测（独立宿主：应用脱离桌面外壳运行）：
# boot 的类/实例两形态、宿主渲染（应用内容 + Toast 区 + 满视口壳）、
# Citrine.render 纯 CRuby 不炸、runtime/app/notify 读访问器、
# 应用引导失败的「应用不可用」占位。纯 CRuby（beryl F5），不触碰 Opal。
require 'minitest/autorun'
require 'emerald'

class StandaloneTest < Minitest::Test
  # argv 传递观察替身
  class ProbeApp < Emerald::App
    app_id :probe
    app_title '探针'

    def view
      label { 'probe-content' }
    end
  end

  # boot 计数替身：验证已引导实例不重复 boot
  class SpyApp < Emerald::App
    app_id :spy
    attr_reader :boots

    def boot(ctx)
      @boots = (@boots || 0) + 1
      super
    end

    def view
      label { 'spy-content' }
    end
  end

  # 引导即炸的坏应用：验证占位渲染
  class BrokenApp < Emerald::App
    app_id :broken

    def boot(_ctx)
      raise 'boom'
    end

    def view
      label { 'broken-content' }
    end
  end

  def render_html(host)
    Citrine.render(host)
  end

  # ── boot：类 / 实例两形态 ─────────────────────────────

  def test_boot_with_class_builds_and_boots_instance
    host = Emerald::Standalone.boot(Emerald::Apps::About)
    assert_instance_of Emerald::Standalone, host
    assert_instance_of Emerald::Apps::About, host.app
    assert_same host.runtime.services, host.app.ctx, 'ctx 即宿主 Runtime 的 services'
    assert_equal({}, host.app.argv)
  end

  def test_boot_with_instance_preserves_existing_argv
    inst = ProbeApp.new
    inst.argv = { path: '/docs/readme.txt' }
    host = Emerald::Standalone.boot(inst)
    assert_same inst, host.app
    assert_equal({ path: '/docs/readme.txt' }, inst.argv, '实例已有 argv 不得被覆盖')
    assert_same host.runtime.services, inst.ctx
  end

  def test_boot_with_booted_instance_skips_reboot
    inst = SpyApp.new
    rt = Emerald::Runtime.new
    rt.boot_app(inst)
    host = Emerald::Standalone.boot(inst)
    assert_same inst, host.app
    assert_equal 1, inst.boots, '已引导实例不得重复 boot'
  end

  # ── 宿主渲染 ──────────────────────────────────────────

  def test_render_contains_app_content_and_host_shell
    html = render_html(Emerald::Standalone.boot(Emerald::Apps::About))
    assert_includes html, 'Emerald OS', '宿主应渲染应用内容'
    assert_includes html, 'var(--bg)', '满视口壳应引用 --bg 背景变量'
    assert_includes html, '100%', '满视口壳应含 100% 宽高'
  end

  def test_render_contains_toast_area_after_push
    host = Emerald::Standalone.boot(ProbeApp.new)
    host.notify.push('独立宿主通知', kind: :success)
    html = render_html(host)
    assert_includes html, 'b-toast', 'push 后应渲染 Toast 堆叠'
    assert_includes html, '独立宿主通知'
  end

  def test_render_does_not_raise_under_cruby
    host = Emerald::Standalone.boot(ProbeApp.new)
    html = render_html(host)
    refute_nil html
    assert_includes render_html(host), 'probe-content', '二次渲染同样不炸'
  end

  def test_missing_app_renders_placeholder
    host = Emerald::Standalone.boot(BrokenApp)
    assert_nil host.app, '引导失败时 app 为 nil'
    assert_includes render_html(host), '应用不可用'
    note, = host.notify.each.first
    assert_equal :error, note['kind']
    assert_includes note['msg'], 'boom'
  end

  # ── 读访问器 ──────────────────────────────────────────

  def test_accessors
    host = Emerald::Standalone.boot(ProbeApp.new)
    assert_instance_of Emerald::Runtime, host.runtime
    assert_instance_of ProbeApp, host.app
    assert_same host.runtime.notify, host.notify
  end
end

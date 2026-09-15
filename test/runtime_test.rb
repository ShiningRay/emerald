# frozen_string_literal: true

# Emerald::Runtime 单测（PLAN §3.9 ServiceHub 正式化第一步）：
# 桌面无关服务构造的抽取——默认 storage 按环境、services 键集与形状、
# settings 首渲染前 load、VFS 可用、router 映射、boot_app 引导契约、
# apply_theme 的 CRuby 返回形状。纯 CRuby（beryl F5），不触碰 Opal。
require 'minitest/autorun'
require 'emerald'

class RuntimeTest < Minitest::Test
  # 引导契约观察替身（不依赖具体内置应用）
  class ProbeApp < Emerald::App
    app_id :probe
    app_title '探针'

    def view
      label { 'probe' }
    end
  end

  def setup
    @rt = Emerald::Runtime.new
  end

  # ── storage 默认与注入 ────────────────────────────────

  def test_default_storage_is_memory_under_cruby
    assert_instance_of Emerald::Storage::Memory, @rt.storage
  end

  def test_explicit_storage_is_used_as_given
    storage = Emerald::Storage::Memory.new
    rt = Emerald::Runtime.new(storage: storage)
    assert_same storage, rt.storage, '显式注入的 storage 应原样使用（settings/vfs 同此实例）'
    assert_same storage, rt.services[:storage]
  end

  # ── services 键集与读访问器 ───────────────────────────

  def test_services_keys
    assert_equal %i[storage vfs settings notify clipboard router], @rt.services.keys
  end

  def test_accessors_are_the_same_objects_as_services
    assert_same @rt.services[:vfs], @rt.vfs
    assert_same @rt.services[:settings], @rt.settings
    assert_same @rt.services[:notify], @rt.notify
    assert_same @rt.services[:clipboard], @rt.clipboard
    assert_same @rt.services[:router], @rt.router
    assert_same @rt.services[:storage], @rt.storage
  end

  def test_service_shapes
    assert_instance_of Emerald::VFS, @rt.vfs
    assert_instance_of Emerald::SettingsStore, @rt.settings
    assert_instance_of Emerald::NotificationCenter, @rt.notify
    assert_respond_to @rt.clipboard, :copy
    assert_instance_of Emerald::FileTypeRouter, @rt.router
  end

  # ── settings：首渲染前 load + 默认表 ──────────────────

  def test_settings_loaded_with_defaults
    assert_equal :dark, @rt.settings.peek(:theme)
    assert_equal '#4f8cff', @rt.settings.peek(:accent)
    assert_equal :comfortable, @rt.settings.peek(:density)
  end

  def test_default_settings_constant_moved_from_shell
    assert_equal({ theme: :dark, accent: '#4f8cff', wallpaper: :aurora,
                   density: :comfortable }, Emerald::Runtime::DEFAULT_SETTINGS)
    refute Emerald::DesktopShell.const_defined?(:DEFAULT_SETTINGS, false),
           'DEFAULT_SETTINGS 已上提至 Runtime，shell 不得再持有副本'
  end

  def test_settings_persist_through_injected_storage
    backend_was = Beryl::Timer.backend
    Beryl::Timer.backend = ->(_ms, blk) { blk.call } # 同步后端：防抖立即持久化
    storage = Emerald::Storage::Memory.new
    Emerald::Runtime.new(storage: storage).settings.set(:accent, '#ff8800')
    rt2 = Emerald::Runtime.new(storage: storage)
    assert_equal '#ff8800', rt2.settings.peek(:accent), '同一 storage 重建 Runtime 应恢复设置'
  ensure
    Beryl::Timer.backend = backend_was
  end

  # ── vfs / router ──────────────────────────────────────

  def test_vfs_usable_after_seed
    @rt.vfs.seed!
    assert_includes @rt.vfs.read('/docs/readme.txt'), 'Welcome to Emerald OS'
  end

  def test_router_maps_text_exts_to_editor
    assert_equal :editor, @rt.router.app_for('/docs/readme.txt')
    assert_equal :editor, @rt.router.app_for('/NOTES.MD'), '扩展名大小写不敏感'
    assert_equal :editor, @rt.router.app_for('/x.rb')
    assert_nil @rt.router.app_for('/x.xyz')
  end

  # ── boot_app / apply_theme ────────────────────────────

  def test_boot_app_assigns_argv_boots_and_returns_instance
    app = ProbeApp.new
    result = @rt.boot_app(app, argv: { path: '/a.txt' })
    assert_same app, result, 'boot_app 应返回被引导的实例'
    assert_equal({ path: '/a.txt' }, app.argv)
    assert_same @rt.services, app.ctx, 'boot 的 ctx 即本 Runtime 的 services Hash'
  end

  def test_boot_app_default_argv_is_empty_hash
    app = @rt.boot_app(ProbeApp.new)
    assert_equal({}, app.argv)
  end

  def test_apply_theme_returns_vars_under_cruby
    vars = @rt.apply_theme
    assert_kind_of Hash, vars
    assert_equal '#0b0e14', vars['--bg'], '默认 dark 主题的 --bg'
    assert_equal '#4f8cff', vars['--accent']
  end

  def test_apply_theme_reflects_current_settings
    @rt.settings.set(:accent, '#ff8800')
    assert_equal '#ff8800', @rt.apply_theme['--accent']
  end
end

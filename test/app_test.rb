# frozen_string_literal: true

# E2 · 应用框架单测：App manifest 宏 + AppRegistry 生命周期（docs/PLAN.md §3.2）
# 纯 CRuby（beryl F5）：不渲染真实窗口，wm 用假对象注入，只验 focus 接线。
require 'minitest/autorun'
require 'citrine'
require 'emerald/app'

class AppTest < Minitest::Test
  # ── 夹具 ─────────────────────────────────────────────

  # 假 WindowManager：只记录 focus 调用（真 WM 的渲染/几何由 beryl 自家测试覆盖）
  class FakeWM
    attr_reader :focused

    def focus(id)
      @focused = id
    end
  end

  class AboutApp < Emerald::App
    app_id :about
    app_title '关于'
    app_icon 'gem'
    singleton true
    default_geometry { { x: 100, y: 80, w: 320, h: 240 } }

    def view
      label { 'About Emerald' }
    end
  end

  class EditorApp < Emerald::App
    app_id :editor
    app_title '编辑器'
    app_icon 'pencil'

    attr_reader :boot_ctx, :boot_count

    def boot(ctx)
      super
      @boot_ctx = ctx
      @boot_count = (@boot_count || 0) + 1
    end

    def view
      label { 'Editor' }
    end
  end

  class NotesApp < Emerald::App
    app_id :notes
    app_title '便签'
    app_icon :note # Symbol 也合法

    def view
      label { 'Notes' }
    end
  end

  def setup
    @registry = Emerald::AppRegistry.new
  end

  def render(component)
    Citrine.render(component)
  end

  # ── manifest 宏 ──────────────────────────────────────

  def test_manifest_macros_read_and_default
    assert_equal :editor, EditorApp.app_id
    assert_equal '编辑器', EditorApp.app_title
    assert_equal 'pencil', EditorApp.app_icon
    assert_equal false, EditorApp.singleton # 默认 false
    assert_nil Class.new(Emerald::App).app_title # 完全未声明的类读取为 nil
  end

  def test_default_geometry_read_write
    geo = AboutApp.default_geometry.call
    assert_equal %i[x y w h], geo.keys
    assert_nil EditorApp.default_geometry # 未声明为 nil
  end

  def test_manifest_inheritance_is_isolated
    sub_klass = Class.new(EditorApp) { app_id :sub_editor }
    assert_equal :sub_editor, sub_klass.app_id
    assert_equal :editor, EditorApp.app_id # 父类不被子类声明污染
    assert_equal :notes, NotesApp.app_id   # 兄弟类互不染
    assert_equal false, sub_klass.singleton # 其余键沿继承
  end

  def test_app_view_renders_via_string_renderer
    assert_includes render(AboutApp.new), 'About Emerald'
  end

  # ── register ─────────────────────────────────────────

  def test_register_adds_to_apps_snapshot
    @registry.register(AboutApp)
    assert_equal [{ id: :about, title: '关于', icon: 'gem' }], @registry.apps
  end

  def test_apps_snapshot_is_detached
    @registry.register(AboutApp)
    snapshot = @registry.apps
    snapshot << { id: :hacked, title: 'x', icon: 'x' }
    snapshot.first[:title] = '篡改'
    assert_equal [{ id: :about, title: '关于', icon: 'gem' }], @registry.apps
  end

  def test_register_rejects_duplicate_id
    @registry.register(AboutApp)
    impostor = Class.new(Emerald::App) { app_id :about }
    error = assert_raises(ArgumentError) { @registry.register(impostor) }
    assert_match(/已注册/, error.message)
  end

  def test_register_requires_app_id
    anonymous = Class.new(Emerald::App)
    assert_raises(ArgumentError) { @registry.register(anonymous) }
  end

  # ── launch ───────────────────────────────────────────

  def test_launch_returns_instance_with_win_id
    @registry.register(AboutApp)
    inst = @registry.launch(:about)
    assert_instance_of AboutApp, inst
    assert_equal :about, inst.win_id
    assert @registry.running?(:about)
    assert_same inst, @registry.instance(:about)
  end

  def test_launch_unregistered_app_fails_fast
    error = assert_raises(ArgumentError) { @registry.launch(:ghost) }
    assert_match(/未注册/, error.message)
  end

  def test_launch_passes_services_as_ctx_and_argv
    services = { vfs: :fake_vfs, settings: :fake_settings }
    registry = Emerald::AppRegistry.new(services: services)
    registry.register(EditorApp)
    inst = registry.launch(:editor, path: '/docs/a.txt', readonly: true)
    assert_same services, inst.boot_ctx # ctx 即注入的 services（同一对象）
    assert_equal services, inst.ctx
    assert_equal({ path: '/docs/a.txt', readonly: true }, inst.argv)
    assert_equal 1, inst.boot_count # boot 恰好一次
  end

  def test_singleton_second_launch_focuses_existing_window
    @registry.register(AboutApp)
    wm = FakeWM.new
    @registry.wm = wm
    first = @registry.launch(:about)
    second = @registry.launch(:about)
    assert_same first, second
    assert_equal :about, wm.focused # wm 收到 focus(已有 win_id)
    assert_equal 1, @registry.each_running.count # 仍只有一个实例
  end

  def test_singleton_hit_without_wm_still_returns_instance
    @registry.register(AboutApp)
    first = @registry.launch(:about)
    assert_same first, @registry.launch(:about) # 未注入 wm 也不重建
  end

  def test_multi_instance_numbering
    @registry.register(EditorApp) # singleton 默认 false
    a = @registry.launch(:editor)
    b = @registry.launch(:editor)
    c = @registry.launch(:editor)
    assert_equal :editor, a.win_id     # 第一扇窗用裸 id
    assert_equal :"editor#2", b.win_id # 之后 per-app 自增 #2/#3
    assert_equal :"editor#3", c.win_id
    assert_equal 3, @registry.each_running.count
  end

  def test_win_id_for_semantics
    @registry.register(AboutApp)
    @registry.register(EditorApp)
    assert_equal :about, @registry.win_id_for(:about)       # 单例恒为裸 id
    assert_equal :editor, @registry.win_id_for(:editor)     # 多实例无存活 → 裸 id
    @registry.launch(:editor)
    assert_equal :"editor#2", @registry.win_id_for(:editor) # 一存活 → 下一个 #2
  end

  # ── dispose / 查询 ───────────────────────────────────

  def test_dispose_unregisters_instance_only
    @registry.register(AboutApp)
    inst = @registry.launch(:about)
    assert_same inst, @registry.dispose(:about)
    assert_nil @registry.instance(:about)
    refute @registry.running?(:about)
  end

  def test_dispose_unknown_win_id_is_noop
    assert_nil @registry.dispose(:never_launched)
  end

  def test_each_running_in_launch_order
    @registry.register(AboutApp)
    @registry.register(EditorApp)
    @registry.register(NotesApp)
    about = @registry.launch(:about)
    editor = @registry.launch(:editor)
    notes = @registry.launch(:notes)
    assert_equal [about, editor, notes], @registry.each_running.to_a
    yielded = []
    @registry.each_running { |inst| yielded << inst }
    assert_equal [about, editor, notes], yielded
  end

  def test_each_running_without_block_returns_enumerator
    assert_instance_of Enumerator, @registry.each_running
  end

  def test_string_ids_are_normalized
    @registry.register(AboutApp)
    inst = @registry.launch('about') # String 也接受
    assert_equal :about, inst.win_id
    assert @registry.running?('about')
    assert_same inst, @registry.instance('about')
  end

  # ── F6 守卫：launch/dispose 禁止在 view/Effect 内 ─────

  def test_launch_raises_inside_effect
    @registry.register(AboutApp)
    error = capture_error_in_effect { @registry.launch(:about) }
    assert error, 'Effect 内 launch 应 raise ArgumentError'
    assert_match(/view\/Effect/, error.message)
    assert_match(/事件回调/, error.message)
    refute @registry.running?(:about), '守卫拦截后不得残留实例'
  end

  def test_dispose_raises_inside_effect
    @registry.register(AboutApp)
    @registry.launch(:about)
    error = capture_error_in_effect { @registry.dispose(:about) }
    assert error, 'Effect 内 dispose 应 raise ArgumentError'
    assert_match(/view\/Effect/, error.message)
    assert @registry.running?(:about), '守卫拦截后实例不得被注销'
  end

  private

  # 手动建立一个 Effect，在其中跑块并接住第一个 ArgumentError（对齐 beryl
  # window_test 的 F6 守卫测法）
  def capture_error_in_effect
    error = nil
    effect = Citrine::Effect.create do
      begin
        yield
      rescue ArgumentError => e
        error = e
      end
      nil
    end
    effect.dispose
    error
  end
end

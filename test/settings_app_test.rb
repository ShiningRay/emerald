# frozen_string_literal: true

# E4 · 设置应用单测（docs/PLAN.md §3.8）：manifest、CRuby 渲染、ctx nil 容忍、
# 受控件写路径（on_change → settings.set + Theme.apply 重应用）、壁纸持久化
# roundtrip、VFS 存储统计。纯 CRuby（beryl F5）；交互经 StringRenderer 节点树
# 取 on_click/on_change 处理器驱动（对齐 beryl form_test 的契约测法）。
require 'minitest/autorun'
require 'emerald'
require 'citrine/string_renderer' # Citrine.render 内部按需加载；这里要直接操作节点树

class SettingsAppTest < Minitest::Test
  DEFAULTS = { theme: :dark, accent: '#4f8cff', wallpaper: :aurora, density: :comfortable }.freeze

  class FakeRegistry
    attr_reader :launched

    def launch(id, **_argv)
      @launched = id
    end
  end

  def setup
    @timer_was = Beryl::Timer.backend
    @cancel_was = Beryl::Timer.cancel_backend
    # 同步 Timer 后端：防抖窗口内的持久化立即执行，便于断言 roundtrip
    Beryl::Timer.backend = ->(_ms, blk) { blk.call }
  end

  def teardown
    Beryl::Timer.backend = @timer_was
    Beryl::Timer.cancel_backend = @cancel_was
  end

  def store(storage: nil)
    Emerald::SettingsStore.new(storage: storage, defaults: DEFAULTS)
  end

  def booted(ctx = {})
    Emerald::Apps::Settings.new.tap { |inst| inst.boot(ctx) }
  end

  # StringRenderer 一次性挂载：返回 [renderer, root]，root 即节点树
  def mount(inst)
    renderer = Citrine::StringRenderer.new
    root = renderer.mount_component(inst, nil)
    [renderer, root]
  end

  def html(inst)
    _renderer, root = mount(inst)
    root.children.map(&:dom).join
  end

  # ── 节点树工具 ───────────────────────────────────────

  def walk(node, acc = [], &pred)
    acc << node if pred.call(node)
    node.children.each { |child| walk(child, acc, &pred) }
    acc
  end

  def node_text(node)
    node.text.to_s + node.children.map { |c| node_text(c) }.join
  end

  # 找子孙里可点击且文案含 text 的节点，驱动它的 on_click（事件回调语义，
  # StringRenderer 非响应式，Effect.current 为 nil——正是 F6 安全区）
  def click(root, text, css: nil)
    candidates = walk(root) do |n|
      n.props[:on_click].is_a?(Proc) &&
        (css.nil? || n.props[:css_class].to_s.include?(css)) &&
        node_text(n).include?(text)
    end
    assert_equal 1, candidates.size, "期望唯一可点击节点：#{text}"
    candidates.first.props[:on_click].call(nil)
  end

  def radio_row(root, text)
    walk(root) do |n|
      n.props[:on_click].is_a?(Proc) &&
        n.props[:css_class].to_s.include?('b-radio') &&
        node_text(n).include?(text)
    end
  end

  # ── manifest ─────────────────────────────────────────

  def test_manifest
    assert_equal :settings, Emerald::Apps::Settings.app_id
    assert_equal '设置', Emerald::Apps::Settings.app_title
    assert_equal '⚙️', Emerald::Apps::Settings.app_icon
    assert_equal true, Emerald::Apps::Settings.singleton
    assert_equal({ x: 220, y: 110, w: 460, h: 400 },
                 Emerald::Apps::Settings.default_geometry.call)
  end

  # ── 渲染 / ctx 容忍 ──────────────────────────────────

  def test_renders_all_sections_without_boot
    out = html(Emerald::Apps::Settings.new) # 未 boot：ctx 为 nil 也不炸
    %w[外观 主题 深色 浅色 强调色 密度 壁纸 极光 存储 清除全部数据 关于].each do |kw|
      assert_includes out, kw, "渲染结果应包含「#{kw}」"
    end
    assert_includes out, 'b-radiogroup'
    assert_includes out, 'b-colorpicker'
    assert_includes out, 'VFS 服务未接入' # ctx 无 VFS → 占位文案
  end

  def test_renders_with_full_ctx
    vfs = Emerald::VFS.new(storage: nil)
    vfs.write('/docs/readme.txt', 'hello')
    vfs.write('/work/notes.txt', 'abcdefgh')
    vfs.mkdir('/work/sub')
    vfs.write('/work/sub/deep.txt', 'xy')
    inst = booted(vfs: vfs, settings: store)
    out = html(inst)
    assert_includes out, '目录 3 · 文件 3 · 15 B'
    assert_includes out, 'wallpaper-preview'
  end

  # ── 受控件写路径：on_change → settings.set + Theme.apply ──

  def test_radio_change_updates_settings_and_moves_check
    settings = store
    inst = booted(settings: settings)
    _r, root = mount(inst)
    click(root, '浅色', css: 'b-radio')
    assert_equal :light, settings.get(:theme) # on_change 落了库

    out = html(inst) # 重渲染：勾选态经 SettingValue 订阅自动跟随
    checked = radio_row(mount(inst)[1], '浅色').first
    refute_nil checked
    assert_includes checked.props[:css_class], 'is-checked'
    refute_includes radio_row(mount(inst)[1], '深色').first.props[:css_class], 'is-checked'
    assert_includes out, '外观'
  end

  def test_theme_apply_receives_fresh_values_on_every_write
    settings = store
    inst = booted(settings: settings)
    inst.change_theme(:light)
    inst.change_density(:compact)
    vars = inst.change_accent('#3fb950') # 返回值即 Theme.apply 应写入的变量表
    assert_kind_of Hash, vars
    assert_equal :light, settings.peek(:theme)
    assert_equal :compact, settings.peek(:density)
    assert_equal '#3fb950', vars['--accent'] # 写后重应用带上新强调色
    assert_equal '6px', vars['--pad']        # 密度档几何 token 同步生效
  end

  def test_color_picker_change_updates_accent
    settings = store
    inst = booted(settings: settings)
    _r, root = mount(inst)
    swatch = walk(root) do |n|
      n.props[:on_click].is_a?(Proc) && n.props[:style] == { background: '#3fb950' }
    end
    assert_equal 1, swatch.size
    swatch.first.props[:on_click].call(nil)
    assert_equal '#3fb950', settings.get(:accent)
  end

  def test_density_select_controlled_open_and_change
    settings = store
    inst = booted(settings: settings)
    refute_includes html(inst), '紧凑' # 闭合态无下拉项

    inst.signal(:density_open).set(true) # 受控开合：受控信号置位（F4）
    _r, open_root = mount(inst)
    click(open_root, '紧凑', css: 'menu-item')
    assert_equal :compact, settings.get(:density)
    assert_includes html(inst), '紧凑 ▾' # 选中值回到按钮文案
  end

  # ── 壁纸：选择 + 持久化 roundtrip ──────────────────────

  def test_wallpaper_change_roundtrips_through_storage
    mem = Emerald::Storage::Memory.new
    settings = store(storage: mem)
    inst = booted(settings: settings)
    inst.signal(:wallpaper_open).set(true) # 受控开合（F4）
    _r2, open_root = mount(inst)
    click(open_root, '石墨', css: 'menu-item')
    assert_equal :graphite, settings.get(:wallpaper)

    fresh = store(storage: mem) # 新 store 从同一后端恢复
    fresh.load
    assert_equal :graphite, fresh.get(:wallpaper)

    out = html(inst) # 预览色块跟随新壁纸
    assert_includes out, Emerald::Apps::Settings::WALLPAPER_GRADIENTS[:graphite]
  end

  # ── 存储统计 ─────────────────────────────────────────

  def test_vfs_stats_counts_exactly
    vfs = Emerald::VFS.new(storage: nil)
    vfs.write('/docs/readme.txt', 'hello')    # 5 B
    vfs.write('/work/notes.txt', 'abcdefgh')  # 8 B
    vfs.mkdir('/work/sub')
    vfs.write('/work/sub/deep.txt', 'xy')     # 2 B
    inst = booted(settings: store)
    assert_equal({ dirs: 3, files: 3, bytes: 15 }, inst.send(:vfs_stats, vfs))
  end

  def test_storage_stats_reflect_vfs_changes
    vfs = Emerald::VFS.new(storage: nil)
    vfs.write('/a.txt', '1234')
    inst = booted(vfs: vfs, settings: store)
    assert_includes html(inst), '目录 0 · 文件 1 · 4 B'
    vfs.write('/dir/b.txt', 'xyz') # 子目录新增：view 里经根 watch 读值，重挂载即新数字
    assert_includes html(inst), '目录 1 · 文件 2 · 7 B'
  end

  # ── 危险钮确认流 ─────────────────────────────────────

  def test_clear_data_confirm_flow_explains_limit_and_notifies
    notify = Emerald::NotificationCenter.new
    inst = booted(settings: store, notify: notify)
    refute_includes html(inst), '无删除通道'

    click(mount(inst)[1], '清除全部数据')
    out = html(inst)
    assert_includes out, '清除全部数据'   # 确认框标题
    assert_includes out, '无删除通道'     # 如实说明协议限制（见 CLEAR_NOTICE）
    assert_includes out, '我知道了'

    click(mount(inst)[1], '我知道了', css: 'b-btn-primary') # 确认 = 关弹窗 + 通知指引
    refute_includes html(inst), '无删除通道'
    assert_equal 1, notify.count
    note = notify.each.first.first
    assert_equal :warning, note['kind']
  end

  # ── 关于：跳转 launch ────────────────────────────────

  def test_about_button_launches_about_app
    registry = FakeRegistry.new
    inst = booted(settings: store, apps: registry)
    click(mount(inst)[1], '关于本系统')
    assert_equal :about, registry.launched
  end
end

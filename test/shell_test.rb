# frozen_string_literal: true

# E1/E4 · 桌面外壳单测（docs/PLAN.md §3.1/§3.7 + 决策 D2/D3/D4）
# 纯 CRuby（beryl F5）：StringRenderer 渲染 + 服务接线断言，不触碰 Opal。
require 'minitest/autorun'
require 'emerald'

class ShellTest < Minitest::Test
  # ── 夹具 ─────────────────────────────────────────────

  # 多实例替身：验证级联几何偏移（不依赖并行里程碑的应用完成度）
  class CascadeApp < Emerald::App
    app_id :cascade
    app_title '级联'
    app_icon '📐'
    default_geometry { { x: 100, y: 60, w: 300, h: 200 } }

    def view
      label { 'cascade' }
    end
  end

  def setup
    @shell = Emerald::DesktopShell.new
  end

  def render_html(shell = @shell)
    Citrine.render(shell)
  end

  # ── 初始化与整机渲染 ─────────────────────────────────

  def test_initialize_runs_and_renders_whole_desktop
    html = render_html
    assert_includes html, 'var(--wallpaper)', '壁纸层应铺满并引用 --wallpaper 变量'
    assert_includes html, 'icon-grid', '桌面图标网格应渲染'
    assert_includes html, 'b-menubar', '菜单栏应渲染'
    assert_includes html, 'b-taskbar', '任务栏应渲染'
    assert_includes html, 'tray', '托盘应渲染'
    assert_includes html, '关于', '内置 About 应已注册并进图标/菜单'
  end

  def test_services_wired
    assert_instance_of Emerald::VFS, @shell.vfs
    assert_instance_of Emerald::SettingsStore, @shell.settings
    assert_instance_of Emerald::NotificationCenter, @shell.notify
    assert_respond_to @shell.clipboard, :copy
    assert_same @shell.registry, @shell.services[:launcher], 'launcher 服务即注册表'
    assert_respond_to @shell.services[:open_file], :call
  end

  def test_router_maps_text_exts_to_editor
    assert_equal :editor, @shell.router.app_for('/docs/readme.txt')
    assert_equal :editor, @shell.router.app_for('/NOTES.MD'), '扩展名大小写不敏感'
    assert_nil @shell.router.app_for('/x.xyz')
  end

  def test_builtin_about_registered_and_others_tolerated
    ids = @shell.registry.apps.map { |a| a[:id] }
    assert_includes ids, :about
    # Files/Editor/Settings/Terminal 此刻可能还是桩：未注册不得阻塞外壳
    refute @shell.registry.running?(:about)
  end

  def test_desktop_file_icons_come_from_vfs
    @shell.vfs.write('/Desktop/备忘.txt', 'buy milk')
    assert_includes render_html, '备忘.txt'
  end

  # ── launch / close 链路（D2）─────────────────────────

  def test_launch_app_opens_window_and_registers
    inst = @shell.launch_app(:about)
    assert @shell.registry.running?(:about)
    assert_includes @shell.wm.windows, inst.win_id
    assert_equal '关于', @shell.wm.record(inst.win_id).title
  end

  def test_launch_singleton_twice_reuses_window
    first = @shell.launch_app(:about)
    second = @shell.launch_app(:about)
    assert_same first, second
    assert_equal 1, @shell.wm.windows.count(first.win_id), '单例重复启动不得重复开窗'
    assert_equal 1, @shell.registry.each_running.count
  end

  def test_close_window_cleans_both_sides
    inst = @shell.launch_app(:about)
    @shell.close_window(inst.win_id)
    refute_includes @shell.wm.windows, inst.win_id
    refute @shell.registry.running?(:about)
    assert_nil @shell.registry.instance(inst.win_id)
  end

  def test_window_render_loop_guarded_by_wm_windows
    inst = @shell.launch_app(:about)
    assert_includes render_html, 'Emerald OS', 'About 窗口内容应经 frame 渲染'
    assert_includes render_html, 'b-taskbtn', '任务栏应出现窗口按钮'
    @shell.close_window(inst.win_id)
    html = render_html # D4：关闭后无守卫渲染不得 raise
    refute_includes html, 'b-taskbtn', '关闭后任务栏应清空'
    refute_includes html, 'Emerald OS'
  end

  # ── open_file 路由 ───────────────────────────────────

  def test_open_file_routes_txt_to_running_editor
    skip '内置 Editor 尚未注册（并行里程碑进行中）' unless @shell.registry.apps.any? { |a| a[:id] == :editor }

    @shell.services[:open_file].call('/docs/readme.txt')
    assert @shell.registry.running?(:editor)
    inst = @shell.registry.instance(:editor)
    assert_equal '/docs/readme.txt', inst.argv[:path]
    assert_includes @shell.wm.windows, inst.win_id
  end

  def test_open_file_unknown_type_pushes_warning
    assert_nil @shell.services[:open_file].call('/x.xyz')
    assert_equal 1, @shell.notify.count
    note, = @shell.notify.each.first
    assert_equal '没有可打开此类型文件的应用', note['msg']
    assert_equal :warning, note['kind']
    assert_includes render_html, 'tray-badge', '通知角标应出现'
  end

  # ── 菜单栏 ───────────────────────────────────────────

  def test_app_menu_action_launches_app
    menus = @shell.send(:menubar_data)
    app_menu = menus.find { |m| m[:label] == '应用' }
    about_item = app_menu[:items].find { |it| it[:label] == '关于' }
    about_item[:action].call
    assert @shell.registry.running?(:about)
  end

  def test_desktop_menu_theme_toggle_via_settings
    menus = @shell.send(:menubar_data)
    items = menus.find { |m| m[:label] == '桌面' }[:items]
    theme_item = items.find { |it| it[:label] == '暗色主题' }
    assert_equal true, theme_item[:checked], '默认暗色主题应勾选'
    theme_item[:action].call
    assert_equal :light, @shell.settings.peek(:theme)
    refute @shell.send(:dark_theme?)
  end

  # ── 几何级联 / 图标选择 / 托盘时钟 ─────────────────────

  def test_geometry_cascades_per_live_instance
    @shell.registry.register(CascadeApp)
    a = @shell.launch_app(:cascade)
    b = @shell.launch_app(:cascade)
    assert_equal({ x: 100, y: 60, w: 300, h: 200 }, @shell.wm.geometry(a.win_id))
    assert_equal({ x: 124, y: 84, w: 300, h: 200 }, @shell.wm.geometry(b.win_id),
                 '第二个实例应按存活序号 x/y 各 +24 级联')
  end

  def test_icon_selection_is_controlled_state
    assert_equal 'd-icon', @shell.send(:icon_tile_class, 'app:about')
    @shell.selected_icons = ['app:about']
    assert_equal 'd-icon is-selected', @shell.send(:icon_tile_class, 'app:about')
    assert_includes render_html, 'is-selected'
  end

  def test_tray_clock_signal_exists
    refute_nil @shell.signal(:clock)
    html = render_html # SSR 也跑 on_mount：时钟走字一次（CRuby Timer 无后端安全跳过）
    assert_includes html, 'tray-clock'
    assert_match(/\A\d{2}:\d{2}\z/, @shell.clock)
  end

  # ── 全局快捷键 ───────────────────────────────────────

  def test_meta_w_closes_active_window_and_meta_n_focuses
    about = @shell.launch_app(:about)
    @shell.registry.register(CascadeApp)
    cascade = @shell.launch_app(:cascade)
    assert_equal true, Emerald.hotkey.dispatch({ key: 'w', meta: true })
    refute_includes @shell.wm.windows, cascade.win_id, 'meta+w 应关闭 z 序最后的激活窗'
    assert_equal true, Emerald.hotkey.dispatch({ key: '1', meta: true })
    assert @shell.wm.active?(about.win_id), 'meta+1 应聚焦第一个窗口'
  end

  def test_meta_n_beyond_window_count_is_noop
    @shell.launch_app(:about)
    assert_equal true, Emerald.hotkey.dispatch({ key: '9', meta: true })
    assert_equal 1, @shell.wm.windows.size, '越界聚焦应忽略（窗口不增不减）'
  end
end

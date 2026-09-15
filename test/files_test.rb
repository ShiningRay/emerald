# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'

# 文件管理器（E3b）：manifest、CRuby 渲染（ctx nil 容忍）、导航、
# 双击/右键回调、菜单与删除/重命名/新建流。服务用真 VFS + 记录 lambda 注入
# （beryl F5：StringRenderer 渲染断言）。
class FilesTest < Minitest::Test
  def render(app)
    Citrine.render(app)
  end

  # 真 VFS + 记录型协作服务：open_file/notify 留痕便于断言
  def ctx(opened: [], notes: nil)
    vfs = Emerald::VFS.new.tap(&:seed!)
    notify = notes || Emerald::NotificationCenter.new
    { vfs: vfs, notify: notify, open_file: ->(p) { opened << p } }
  end

  def launch(ctx, path: nil)
    app = Emerald::Apps::Files.new
    app.argv = path ? { path: path } : {}
    app.boot(ctx)
    app
  end

  # ---- manifest ----

  def test_manifest
    assert_equal :files, Emerald::Apps::Files.app_id
    assert_equal true, Emerald::Apps::Files.singleton
    assert_equal '🗂️', Emerald::Apps::Files.app_icon
    assert_equal({ x: 60, y: 40, w: 640, h: 440 }, Emerald::Apps::Files.default_geometry.call)
  end

  # ---- 渲染：ctx nil 不炸，关键词齐全 ----

  def test_render_without_ctx
    html = render(Emerald::Apps::Files.new)
    assert_includes html, '双击打开 · 右键菜单'  # 顶部说明行
    assert_includes html, 'b-table'              # 表格
    assert_includes html, '名称'                 # 三列头
    assert_includes html, '类型'
    assert_includes html, '修改时间'
    assert_includes html, 'b-breadcrumb'         # 面包屑
    assert_includes html, '刷新'                 # 工具钮
    assert_includes html, '新建文件'
  end

  # ---- boot 与导航 ----

  def test_boot_defaults_to_root
    app = launch(ctx)
    assert_equal '/', app.dir
    html = render(app)
    assert_includes html, 'docs'     # 根下种子目录
    assert_includes html, 'Desktop'
  end

  def test_boot_with_file_path_lands_in_parent_dir
    app = launch(ctx, path: '/docs/readme.txt')
    assert_equal '/docs', app.dir
    assert_includes render(app), 'readme.txt'
  end

  def test_boot_with_dir_path_stays
    app = launch(ctx, path: '/docs')
    assert_equal '/docs', app.dir
  end

  def test_boot_with_missing_path_falls_back
    app = launch(ctx, path: '/no/such/deep.txt')
    assert_equal '/no/such', app.dir  # 目录部分语义
    app2 = launch(ctx, path: '相对/路径')
    assert_equal '/', app2.dir        # 非法路径兜底
  end

  def test_navigation_changes_rows
    c = ctx
    app = launch(c)
    html_root = render(app)
    assert_includes html_root, 'Desktop'

    app.navigate('/docs')
    assert_equal '/docs', app.dir
    html_docs = render(app)
    assert_includes html_docs, 'readme.txt'
    # 表格行随 dir 变化（侧栏树恒显根目录，只断言表格单元格）
    assert_includes html_docs, 'class="b-table-td em-files-name"'
    refute_includes html_docs, 'b-table-td em-files-name">Desktop'
  end

  def test_crumbs_follow_dir
    app = launch(ctx)
    app.navigate('/docs')
    labels = app.send(:crumbs).map { |c| c[:label] }
    assert_equal ['/', 'docs'], labels
  end

  # ---- watch 订阅源：目录变更 bump 版本 ----

  def test_watch_signal_bumps_on_change
    c = ctx
    app = launch(c, path: '/docs')
    render(app)  # 渲染即读 watch(dir) 建订阅源
    _dir, v0 = c[:vfs].watch('/docs').get
    c[:vfs].write('/docs/new.txt', 'hi')
    _dir, v1 = c[:vfs].watch('/docs').get
    assert_operator v1, :>, v0
  end

  # ---- 双击：目录进入 / 文件 open_file ----

  def test_dblclick_file_calls_open_file
    opened = []
    app = launch(ctx(opened: opened), path: '/docs')
    app.open_entry(name: 'readme.txt', kind: :file, mtime: 0)
    assert_equal ['/docs/readme.txt'], opened
  end

  def test_dblclick_dir_navigates
    app = launch(ctx)
    app.open_entry(name: 'docs', kind: :dir, mtime: 0)
    assert_equal '/docs', app.dir
    assert_includes render(app), 'readme.txt'
  end

  # ---- 右键菜单：渲染 + 删除/重命名流 ----

  def test_row_menu_renders_rename_and_delete
    app = launch(ctx, path: '/docs')
    app.open_row_menu({ name: 'readme.txt', kind: :file, mtime: 0 }, { clientX: 5, clientY: 6 })
    html = render(app)
    assert_includes html, 'ctx-menu'
    assert_includes html, '重命名'
    assert_includes html, '删除'
    app.close_menu
    refute_includes render(app), 'ctx-menu'
  end

  def test_delete_flow_with_confirm
    c = ctx
    c[:vfs].write('/docs/trash.txt', 'bye')
    app = launch(c, path: '/docs')
    entry = { name: 'trash.txt', kind: :file, mtime: 0 }

    app.ask_delete(entry)
    assert_includes render(app), '确定删除「trash.txt」吗？'  # Confirm 确认层

    app.do_delete(entry)
    refute c[:vfs].exist?('/docs/trash.txt')
    note, = c[:notify].each.to_a.last
    assert_equal :success, note['kind']                      # 成功通知
    assert_includes note['msg'], '已删除'
    assert_nil app.dialog                                    # 对话框已关
  end

  def test_rename_flow_with_prompt
    c = ctx
    app = launch(c, path: '/docs')
    entry = { name: 'readme.txt', kind: :file, mtime: 0 }

    app.ask_rename(entry)
    assert_includes render(app), '新名称：'                  # Prompt 渲染

    app.do_rename(entry, 'renamed.txt')
    assert_equal 'Welcome to Emerald OS!', c[:vfs].read('/docs/renamed.txt').lines.first.chomp
    refute c[:vfs].exist?('/docs/readme.txt')
  end

  def test_new_file_writes_empty_and_opens_editor
    opened = []
    c = ctx(opened: opened)
    app = launch(c, path: '/docs')
    app.ask_new_file
    assert_includes render(app), '文件名：'
    app.do_new_file('note.txt')
    assert_equal '', c[:vfs].read('/docs/note.txt')          # 空内容落盘
    assert_equal ['/docs/note.txt'], opened                  # 进入编辑
  end
end

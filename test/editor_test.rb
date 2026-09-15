# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'

# 文本编辑器（E3b）：manifest、CRuby 渲染（ctx nil 容忍）、boot 读文件、
# save 写 vfs（真 VFS roundtrip + 假 vfs 注入各覆盖）、dirty 语义、
# 无 path 的 Prompt 取名路径。textarea 的 value 是 Signal——
# StringRenderer 下渲染不含值文本属正常，buf 经信号本身断言。
class EditorTest < Minitest::Test
  def render(app)
    Citrine.render(app)
  end

  def ctx(notes: nil)
    vfs = Emerald::VFS.new.tap(&:seed!)
    { vfs: vfs, notify: notes || Emerald::NotificationCenter.new }
  end

  def launch(ctx, path: nil)
    app = Emerald::Apps::Editor.new
    app.argv = path ? { path: path } : {}
    app.boot(ctx)
    app
  end

  # ---- manifest ----

  def test_manifest
    assert_equal :editor, Emerald::Apps::Editor.app_id
    assert_equal false, Emerald::Apps::Editor.singleton
    assert_equal '📝', Emerald::Apps::Editor.app_icon
    assert_equal({ x: 140, y: 90, w: 560, h: 420 }, Emerald::Apps::Editor.default_geometry.call)
  end

  # ---- 渲染：ctx nil 不炸，结构齐全 ----

  def test_render_without_ctx
    html = render(Emerald::Apps::Editor.new)
    assert_includes html, '未命名'        # 头部文件名占位
    assert_includes html, '<textarea'    # L1 原语
    assert_includes html, '⌘⏎ 保存'     # 状态行提示
    refute_includes html, '●'            # 未编辑无未保存标记
  end

  def test_textarea_binds_buf_signal
    app = launch(ctx)
    assert_instance_of Citrine::Signal, app.signal(:buf)
    assert_same app.signal(:buf), app.signal(:buf)  # 同一受控信号
  end

  # ---- boot ----

  def test_boot_reads_file_into_buf
    c = ctx
    c[:vfs].write('/docs/todo.txt', "买菜\n浇水")
    app = launch(c, path: '/docs/todo.txt')
    assert_equal '/docs/todo.txt', app.path
    assert_equal "买菜\n浇水", app.buf
    assert_equal false, app.dirty
    html = render(app)
    assert_includes html, 'todo.txt'    # 头部文件名
    assert_includes html, '5 字符'       # 底部字符数（含换行）
  end

  def test_boot_missing_file_warns_and_starts_empty
    c = ctx
    app = launch(c, path: '/gone.txt')
    assert_equal '/gone.txt', app.path                # 按新文件对待，path 照记
    assert_equal '', app.buf
    note, = c[:notify].each.to_a.last
    assert_equal :warning, note['kind']               # 告警通知
    assert_includes note['msg'], '文件不存在'
  end

  def test_boot_without_path_is_untitled
    app = launch(ctx)
    assert_nil app.path
    assert_equal '', app.buf
    assert_includes render(app), '未命名'
  end

  # ---- dirty 语义 ----

  def test_dirty_tracks_edits_against_snapshot
    c = ctx
    c[:vfs].write('/a.txt', 'abc')
    app = launch(c, path: '/a.txt')
    assert_equal false, app.dirty

    app.buf = 'abcd'                       # 任意编辑路径（含双向绑定直写）
    assert_equal true, app.dirty
    assert_includes render(app), '●'

    app.buf = 'abc'                        # 改回原内容 → 不再脏
    assert_equal false, app.dirty
  end

  # ---- save：有 path 直写 ----

  def test_save_writes_vfs_and_clears_dirty
    c = ctx
    c[:vfs].write('/docs/a.txt', 'v1')
    app = launch(c, path: '/docs/a.txt')
    app.buf = 'v2'
    app.save

    assert_equal 'v2', c[:vfs].read('/docs/a.txt')   # roundtrip：真 VFS 落盘
    assert_equal false, app.dirty
    note, = c[:notify].each.to_a.last
    assert_equal '已保存', note['msg']               # 成功通知
    assert_equal :success, note['kind']
    refute_includes render(app), '●'
  end

  def test_save_with_injected_fake_vfs
    writes = []
    fake_vfs = Object.new
    fake_vfs.define_singleton_method(:read) { |_p| 'seed' }
    fake_vfs.define_singleton_method(:write) { |p, c| writes << [p, c] }
    notify = Emerald::NotificationCenter.new
    app = launch({ vfs: fake_vfs, notify: notify }, path: '/x.txt')
    assert_equal 'seed', app.buf                     # boot 走注入服务

    app.buf = 'edited'
    app.save
    assert_equal [['/x.txt', 'edited']], writes      # 写也走注入服务
  end

  # ---- save：无 path → Prompt 取名 ----

  def test_save_without_path_asks_then_writes
    c = ctx
    app = launch(c)
    app.buf = "hello\nworld"
    app.save
    refute_nil app.save_as                            # Prompt 状态就位
    assert_includes render(app), '文件路径：'

    app.confirm_save_as('notes/diary.txt')            # 相对名补根前缀
    assert_equal "/notes/diary.txt", app.path
    assert_equal "hello\nworld", c[:vfs].read('/notes/diary.txt')
    assert_equal false, app.dirty
    assert_nil app.save_as                            # Prompt 已关
    html = render(app)
    assert_includes html, 'diary.txt'                 # 头部换名
    assert_includes html, '11 字符'
  end

  def test_save_as_empty_name_is_noop
    c = ctx
    app = launch(c)
    app.buf = 'x'
    app.save
    app.confirm_save_as('   ')
    assert_nil app.path                               # 空名不写盘
    assert_equal false, c[:vfs].exist?('/x.txt')
    assert_nil app.save_as
  end
end

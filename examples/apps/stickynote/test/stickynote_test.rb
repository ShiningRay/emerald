# frozen_string_literal: true

# 便利贴示例包单测：manifest 宏 / window_opts 异形声明 / 渲染 / VFS 保存闭环。
# 纯 CRuby。运行（emerald/ 目录内）：
#   bundle exec ruby -Ilib examples/apps/stickynote/test/stickynote_test.rb
require 'minitest/autorun'
require 'emerald'
require_relative '../src/main'

class StickyNoteTest < Minitest::Test
  def test_manifest_macros_match_package_manifest
    assert_equal :stickynote, StickyNote.app_id
    assert_equal '便利贴', StickyNote.app_title
    assert_equal '🗒️', StickyNote.app_icon
    assert_equal false, StickyNote.singleton
    assert_equal({ x: 260, y: 160, w: 240, h: 240 }, StickyNote.default_geometry.call)
  end

  def test_window_opts_declares_shaped_window
    opts = StickyNote.window_opts
    assert_equal StickyNote::DOGEAR, opts[:shape]
    assert_equal 'sticky-note-win', opts[:css_class]
    assert_equal false, opts[:snap]         # 吸附是矩形假设，异形窗口关闭
    assert_equal false, opts[:resizable]
    assert_equal false, opts[:maximizable]
  end

  def test_render_shows_note_structure_without_boot
    html = Citrine.render(StickyNote.new)
    assert_includes html, 'sticky-note-area'
    assert_includes html, 'sticky-note-status'
  end

  def test_multi_instance_and_save_to_vfs
    vfs = Emerald::VFS.new
    registry = Emerald::AppRegistry.new(services: { vfs: vfs })
    registry.register(StickyNote)

    note = registry.launch(:stickynote)
    note.buf = '记得买牛奶'
    note.save
    assert_equal '/Notes/note-1.txt', note.path
    assert_equal '记得买牛奶', vfs.read('/Notes/note-1.txt')
    refute note.dirty

    second = registry.launch(:stickynote)   # 多实例：第二张贴不撞第一贴
    refute_equal note.win_id, second.win_id
    second.buf = '第二张'
    second.save
    assert_equal '/Notes/note-2.txt', second.path

    reopened = registry.launch(:stickynote, path: '/Notes/note-1.txt')
    assert_equal '记得买牛奶', reopened.buf
  end

  def test_dirty_tracks_edits
    registry = Emerald::AppRegistry.new(services: { vfs: Emerald::VFS.new })
    registry.register(StickyNote)
    note = registry.launch(:stickynote)
    refute note.dirty
    note.buf = '改了一笔'
    assert note.dirty
  end
end

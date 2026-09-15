# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'

class FileTypeRouterTest < Minitest::Test
  def setup
    @router = Emerald::FileTypeRouter.new
    @router.register('.txt', :editor)
  end

  def test_app_for_hits_registered_ext
    assert_equal :editor, @router.app_for('/docs/readme.txt')
    assert_equal :editor, @router.app_for('notes.TXT')
  end

  def test_app_for_miss_returns_nil
    assert_nil @router.app_for('/images/pic.png')
    assert_nil @router.app_for('/no_ext')
  end

  def test_register_normalizes_symbol_and_bare_ext
    @router.register(:md, 'editor')
    assert_equal :editor, @router.app_for('/a/b.md')
  end

  def test_register_overrides_same_ext
    @router.register('.txt', :viewer)
    assert_equal :viewer, @router.app_for('/a.txt')
  end

  def test_mappings_snapshot_is_a_copy
    snap = @router.mappings
    snap['.txt'] = :hacked
    assert_equal :editor, @router.app_for('/a.txt')
  end
end

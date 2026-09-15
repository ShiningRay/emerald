# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'

# 同步 Timer 后端：VFS 的防抖持久化立即落盘，便于断言 roundtrip
class VFSTest < Minitest::Test
  def setup
    @backend_was = Beryl::Timer.backend
    @cancel_was = Beryl::Timer.cancel_backend
    Beryl::Timer.backend = ->(_ms, blk) { blk.call }
    @vfs = Emerald::VFS.new(storage: Emerald::Storage::Memory.new)
  end

  def teardown
    Beryl::Timer.backend = @backend_was
    Beryl::Timer.cancel_backend = @cancel_was
  end

  def fresh(memory)
    Emerald::VFS.new(storage: memory)
  end

  # ---- normalize：各形态 ----

  def test_normalize_collapses_double_slashes_and_dots
    assert_equal '/a/b', Emerald::VFS.normalize('/a//b')
    assert_equal '/a/b', Emerald::VFS.normalize('//a///b//')
    assert_equal '/a/b', Emerald::VFS.normalize('/a/./b')
    assert_equal '/a', Emerald::VFS.normalize('/a/b/..')
    assert_equal '/a/b/c', Emerald::VFS.normalize('/a/x/../b/./c')
  end

  def test_normalize_root_and_trailing_slash
    assert_equal '/', Emerald::VFS.normalize('/')
    assert_equal '/a', Emerald::VFS.normalize('/a/')
    assert_equal '/', Emerald::VFS.normalize('/.')
    assert_equal '/', Emerald::VFS.normalize('/a/..')
  end

  def test_normalize_accepts_backslash_and_string_keys
    assert_equal '/a/b', Emerald::VFS.normalize('\\a\\b')
  end

  # ---- normalize：越根 raise ----

  def test_normalize_escaping_root_raises
    assert_raises(ArgumentError) { Emerald::VFS.normalize('/..') }
    assert_raises(ArgumentError) { Emerald::VFS.normalize('/a/../../b') }
  end

  def test_normalize_rejects_relative_path
    assert_raises(ArgumentError) { Emerald::VFS.normalize('a/b') }
    assert_raises(ArgumentError) { Emerald::VFS.normalize('') }
    assert_raises(ArgumentError) { Emerald::VFS.normalize(nil) }
  end

  # ---- seed ----

  def test_seeds_initial_tree
    @vfs.seed!
    assert_equal :file, @vfs.stat('/docs/readme.txt').kind
    refute_empty @vfs.read('/docs/readme.txt')
    assert_equal :dir, @vfs.stat('/Desktop').kind
    assert_equal :dir, @vfs.stat('/images').kind
    assert_empty @vfs.list('/Desktop')
  end

  def test_seed_is_idempotent
    2.times { @vfs.seed! }
    assert_equal 1, @vfs.list('/docs').size
    assert_equal 1, @vfs.list('/').count { |n| n.name == 'docs' }
    assert_equal 1, @vfs.list('/').count { |n| n.name == 'Desktop' }
    assert_equal 1, @vfs.list('/').count { |n| n.name == 'images' }
  end

  def test_seed_preserves_existing_content
    @vfs.write('/docs/readme.txt', '用户内容')
    @vfs.seed!
    assert_equal '用户内容', @vfs.read('/docs/readme.txt')
  end

  # ---- read / write / mkdir / exist? ----

  def test_write_auto_creates_parents
    @vfs.write('/a/b/c.txt', 'hi')
    assert_equal 'hi', @vfs.read('/a/b/c.txt')
    assert_equal :dir, @vfs.stat('/a/b').kind
  end

  def test_write_requires_string_content
    assert_raises(ArgumentError) { @vfs.write('/a.txt', 42) }
  end

  def test_read_returns_content
    @vfs.write('/x.txt', 'hello')
    assert_equal 'hello', @vfs.read('/x.txt')
  end

  def test_read_missing_raises_not_found
    assert_raises(Emerald::VFS::NotFound) { @vfs.read('/missing.txt') }
  end

  def test_read_dir_raises_not_found
    assert_raises(Emerald::VFS::NotFound) { @vfs.read('/Desktop') }
  end

  def test_mkdir_recursive_and_idempotent
    @vfs.mkdir('/a/b/c')
    assert_equal :dir, @vfs.stat('/a/b/c').kind
    @vfs.mkdir('/a/b/c') # 幂等
    assert_equal 1, @vfs.list('/a/b').size
  end

  def test_exist
    refute @vfs.exist?('/nope.txt')
    @vfs.write('/nope.txt', 'x')
    assert @vfs.exist?('/nope.txt')
    assert @vfs.exist?('/')
  end

  # ---- list / stat ----

  def test_list_sorts_dirs_first_then_name_ascending
    @vfs.mkdir('/work/zdir')
    @vfs.mkdir('/work/adir')
    @vfs.write('/work/b.txt', 'b')
    @vfs.write('/work/a.txt', 'a')
    names = @vfs.list('/work').map(&:name)
    assert_equal %w[adir zdir a.txt b.txt], names
  end

  def test_list_missing_raises_not_found
    assert_raises(Emerald::VFS::NotFound) { @vfs.list('/missing') }
  end

  def test_list_on_file_raises_not_found
    @vfs.write('/f.txt', 'x')
    assert_raises(Emerald::VFS::NotFound) { @vfs.list('/f.txt') }
  end

  def test_stat_returns_node_or_nil
    assert_nil @vfs.stat('/missing')
    @vfs.write('/f.txt', 'x')
    node = @vfs.stat('/f.txt')
    assert_equal 'f.txt', node.name
    assert_equal :file, node.kind
    assert_kind_of Integer, node.mtime
  end

  def test_list_view_hides_internal_dir_content
    @vfs.mkdir('/d/sub')
    entry = @vfs.list('/').find { |n| n.name == 'd' }
    assert_nil entry.content # 目录的 content 不对外暴露
  end

  def test_list_nodes_are_frozen_copies
    @vfs.write('/f.txt', 'x')
    entry = @vfs.list('/').find { |n| n.name == 'f.txt' }
    entry.content << 'junk' # dup 出的 String，改不穿内部树
    assert_equal 'x', @vfs.read('/f.txt')
  end

  def test_mtime_is_monotonic_counter
    @vfs.write('/a.txt', '1')
    @vfs.write('/b.txt', '2')
    assert_operator @vfs.stat('/b.txt').mtime, :>, @vfs.stat('/a.txt').mtime
  end

  # ---- move：两种语义 ----

  def test_move_into_existing_dir_keeps_file_name
    @vfs.write('/a.txt', 'x')
    @vfs.move('/a.txt', '/Desktop')
    refute @vfs.exist?('/a.txt')
    assert_equal 'x', @vfs.read('/Desktop/a.txt')
  end

  def test_move_rename_to_dst
    @vfs.write('/a.txt', 'x')
    @vfs.move('/a.txt', '/b.txt')
    refute @vfs.exist?('/a.txt')
    assert_equal 'x', @vfs.read('/b.txt')
  end

  def test_move_rename_into_other_dir
    @vfs.write('/a.txt', 'x')
    @vfs.move('/a.txt', '/Desktop/renamed.txt')
    assert_equal 'x', @vfs.read('/Desktop/renamed.txt')
  end

  def test_move_dir_recursively
    @vfs.write('/d/f.txt', 'x')
    @vfs.move('/d', '/e')
    refute @vfs.exist?('/d')
    assert_equal 'x', @vfs.read('/e/f.txt')
  end

  def test_move_missing_src_raises_not_found
    assert_raises(Emerald::VFS::NotFound) { @vfs.move('/missing', '/Desktop') }
  end

  # ---- delete ----

  def test_delete_recursive
    @vfs.write('/a/b/c.txt', 'x')
    @vfs.delete('/a')
    refute @vfs.exist?('/a')
    refute @vfs.exist?('/a/b/c.txt')
  end

  def test_delete_missing_raises_not_found
    assert_raises(Emerald::VFS::NotFound) { @vfs.delete('/missing') }
  end

  # ---- watch ----

  def test_watch_bumps_on_child_change
    sig = @vfs.watch('/docs')
    assert_equal ['/docs', 0], sig.peek

    @vfs.write('/docs/a.txt', 'a')
    assert_equal ['/docs', 1], sig.peek
    @vfs.delete('/docs/a.txt')
    assert_equal ['/docs', 2], sig.peek
  end

  def test_watch_bumps_on_self_change
    sig = @vfs.watch('/docs')
    @vfs.mkdir('/docs/sub')
    assert_equal ['/docs', 1], sig.peek
  end

  def test_watch_effect_reruns_on_bump
    @vfs.write('/docs/a.txt', 'a')
    sig = @vfs.watch('/docs')
    seen = []
    Citrine::Effect.create { seen << sig.get[1] }
    assert_equal [0], seen
    @vfs.write('/docs/b.txt', 'b')
    assert_equal [0, 1], seen
  end

  def test_unrelated_dir_watch_does_not_bump
    @vfs.mkdir('/work')
    sig = @vfs.watch('/work')
    @vfs.write('/docs/a.txt', 'a')
    assert_equal ['/work', 0], sig.peek
  end

  # ---- 持久化 ----

  def test_persistence_roundtrip
    mem = Emerald::Storage::Memory.new
    vfs = Emerald::VFS.new(storage: mem)
    vfs.write('/notes/todo.txt', '买菜')
    vfs.mkdir('/notes/archive')
    vfs.delete('/docs/readme.txt')

    fresh = Emerald::VFS.new(storage: mem)
    assert_equal '买菜', fresh.read('/notes/todo.txt')
    assert_equal :dir, fresh.stat('/notes/archive').kind
    refute fresh.exist?('/docs/readme.txt')
  end

  def test_new_instance_without_data_seeds_first
    mem = Emerald::Storage::Memory.new
    vfs = Emerald::VFS.new(storage: mem)
    assert vfs.exist?('/docs/readme.txt')
    refute_empty vfs.read('/docs/readme.txt')
  end

  def test_nil_storage_never_persists
    @vfs.write('/a.txt', 'x')
    fresh = Emerald::VFS.new(storage: nil)
    refute fresh.exist?('/a.txt')
  end
end

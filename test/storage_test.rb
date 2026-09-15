# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'

class StorageTest < Minitest::Test
  def test_memory_roundtrip
    s = Emerald::Storage::Memory.new
    assert_nil s.load('k')

    s.dump('k', { 'a' => 1 })
    assert_equal({ 'a' => 1 }, s.load('k'))
  end

  def test_memory_holds_ruby_objects_without_serialization
    s = Emerald::Storage::Memory.new
    obj = { nested: [:sym, 42] }
    s.dump('k', obj)
    assert_same obj, s.load('k') # 直存引用，不经序列化
  end

  def test_memory_keys_are_isolated
    s = Emerald::Storage::Memory.new
    s.dump('a', 1)
    s.dump('b', 2)
    assert_equal 1, s.load('a')
    assert_equal 2, s.load('b')
  end

  def test_localstorage_raises_under_cruby
    error = assert_raises(RuntimeError) { Emerald::Storage::LocalStorage.new }
    assert_includes error.message, 'Opal'
  end
end

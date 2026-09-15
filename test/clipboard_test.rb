# frozen_string_literal: true

# E5a · Clipboard（PLAN §3.6）：内存真相源 + Opal 下 best-effort 系统剪贴板。
# CRuby 下 navigator.clipboard 适配是 defined?(Opal) 守卫的 no-op，故纯内存断言。
require 'minitest/autorun'
require 'emerald'

class ClipboardTest < Minitest::Test
  def test_initial_read_is_nil
    assert_nil Emerald::Clipboard.new.read
  end

  def test_copy_then_read_roundtrip
    clipboard = Emerald::Clipboard.new
    assert_equal '文本', clipboard.copy('文本')
    assert_equal '文本', clipboard.read
  end

  def test_repeated_copy_overwrites
    clipboard = Emerald::Clipboard.new
    clipboard.copy('第一段')
    clipboard.copy('第二段')

    assert_equal '第二段', clipboard.read
  end

  def test_clear_resets_to_nil
    clipboard = Emerald::Clipboard.new
    clipboard.copy('文本')
    clipboard.clear

    assert_nil clipboard.read
  end

  def test_instances_are_independent
    a = Emerald::Clipboard.new
    b = Emerald::Clipboard.new
    a.copy('只属于 a')

    assert_equal '只属于 a', a.read
    assert_nil b.read
  end
end

# frozen_string_literal: true

# 计算器示例包单测：Engine 纯计算内核 + App manifest/渲染/注册启动。
# 纯 CRuby（SPEC §1：源码包作者侧可测）。运行（emerald/ 目录内）：
#   bundle exec ruby -Ilib examples/apps/calculator/test/calculator_test.rb
require 'minitest/autorun'
require 'emerald'
require_relative '../src/main'

class CalcEngineTest < Minitest::Test
  def setup
    @engine = Calculator::Engine.new
  end

  def press(*keys)
    keys.each { |k| @engine.press(k) }
    @engine.display
  end

  def test_digit_entry_and_leading_zero
    assert_equal '123', press('1', '2', '3')
    assert_equal '0', press('C', '0')
    assert_equal '5', press('5')
  end

  def test_dot_rules
    assert_equal '1.5', press('1', '.', '5')
    assert_equal '1.5', press('.')
    assert_equal '0.5', press('C', '.', '5')
  end

  def test_addition_and_float_cleanup
    assert_equal '3', press('1', '+', '2', '=')
    assert_equal '0.3', press('C', '0', '.', '1', '+', '0', '.', '2', '=')
  end

  def test_chained_operators_resolve_pending
    assert_equal '3', press('1', '+', '2', '+')
    assert_equal '6', press('3', '=')
  end

  def test_division_and_divide_by_zero
    assert_equal '3.5', press('7', '/', '2', '=')
    assert_equal '错误', press('C', '1', '/', '0', '=')
    assert_equal '5', press('5') # 错误态下新数字脱出
  end

  def test_clear_backspace_percent
    assert_equal '12', press('1', '2', '3', 'back')
    assert_equal '0', press('back', 'back')
    assert_equal '0.5', press('5', '0', '%')
    assert_equal '0', press('C')
  end

  def test_change_operator_while_fresh
    assert_equal '-1', press('3', '+', '-', '4', '=') # 换符不结算：3 - 4
  end
end

class CalculatorAppTest < Minitest::Test
  def test_manifest_macros_match_package_manifest
    assert_equal :calculator, Calculator.app_id
    assert_equal '计算器', Calculator.app_title
    assert_equal '🧮', Calculator.app_icon
    assert_equal true, Calculator.singleton
    assert_equal({ x: 220, y: 140, w: 280, h: 420 }, Calculator.default_geometry.call)
  end

  def test_render_shows_display_and_keys_without_boot
    html = Citrine.render(Calculator.new)
    assert_includes html, 'calc-display'
    assert_includes html, '×'
    assert_includes html, '⌫'
  end

  def test_launch_and_press_via_registry
    registry = Emerald::AppRegistry.new
    registry.register(Calculator)
    inst = registry.launch(:calculator)
    assert_equal :calculator, inst.win_id
    inst.press('6')
    inst.press('*')
    inst.press('7')
    inst.press('=')
    assert_equal '42', inst.display
    assert_same inst, registry.launch(:calculator) # singleton 命中
  end
end

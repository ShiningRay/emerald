# frozen_string_literal: true

# 快捷键注册表单测（docs/PLAN.md §3.6）：纯 CRuby，无渲染。
# 覆盖 chord 归一（字符串/Hash/大小写/乱序/纯修饰键/空格键）、
# register/dispatch 语义（闭包 self、覆盖、未命中、注销）、scope 路由
# （应用优先、全局兜底、表间不串）、修饰键缺省 false。
require 'minitest/autorun'
require 'emerald'

class HotkeyTest < Minitest::Test
  def registry
    Emerald::ShortcutRegistry.new
  end

  # ── chord_for：字符串输入 ─────────────────────────────

  def test_chord_for_string_single_key
    assert_equal 'f', registry.chord_for('f')
  end

  def test_chord_for_string_chord_downcases_key
    assert_equal 'ctrl+shift+p', registry.chord_for('ctrl+shift+P')
  end

  def test_chord_for_string_reorders_modifiers
    assert_equal 'meta+ctrl+shift+x', registry.chord_for('shift+ctrl+meta+X')
  end

  def test_chord_for_pure_modifier_raises
    assert_raises(ArgumentError) { registry.chord_for('meta') }
    assert_raises(ArgumentError) { registry.chord_for('ctrl+shift') }
  end

  def test_chord_for_two_main_keys_raises
    assert_raises(ArgumentError) { registry.chord_for('a+b') }
  end

  # ── chord_for：Hash 输入 ──────────────────────────────

  def test_chord_for_hash_symbol_keys
    assert_equal 'meta+s', registry.chord_for({ key: 'S', meta: true })
  end

  def test_chord_for_hash_string_keys
    assert_equal 'ctrl+shift+p', registry.chord_for({ 'key' => 'p', 'ctrl' => true, 'shift' => true })
  end

  def test_chord_for_hash_key_names_case_insensitive
    assert_equal 'meta+a', registry.chord_for({ 'Key' => 'A', 'META' => true, 'Ctrl' => false })
  end

  def test_chord_for_hash_reorders_modifiers
    chord = registry.chord_for({ key: 'x', shift: true, ctrl: true, meta: true })
    assert_equal 'meta+ctrl+shift+x', chord
  end

  def test_chord_for_hash_pure_modifier_raises
    assert_raises(ArgumentError) { registry.chord_for({ meta: true }) }
  end

  def test_chord_for_space_key
    assert_equal 'meta+space', registry.chord_for({ key: ' ', meta: true })
    assert_equal 'space', registry.chord_for(' ')
  end

  def test_chord_for_key_event_duck_type
    # shell 将来的接线形态：citrine window_key 的 KeyEvent 直接可喂
    ev = Citrine::KeyEvent.new('s', meta: true)
    assert_equal 'meta+s', registry.chord_for(ev)
  end

  # ── register / dispatch ───────────────────────────────

  def test_dispatch_hit_runs_handler_and_returns_true
    h = registry
    log = []
    h.register('meta+s') { log << :saved }
    assert_equal true, h.dispatch({ 'key' => 's', 'meta' => true })
    assert_equal [:saved], log
  end

  def test_dispatch_miss_returns_false_without_side_effect
    h = registry
    log = []
    h.register('meta+s') { log << :saved }
    assert_equal false, h.dispatch({ key: 'x', meta: true })
    assert_equal false, h.dispatch({ key: 's' }) # 修饰键缺省 false，'s' ≠ 'meta+s'
    assert_empty log
  end

  def test_dispatch_block_keeps_closure_self
    # beryl F1：块以普通 call 执行，self 不重绑——能调到定义处的实例方法
    counter = Class.new do
      def initialize = (@n = 0)
      def bump = (@n += 1)
      attr_reader :n
    end.new
    captured = nil
    h = registry
    h.register('meta+k') { captured = self; counter.bump }
    h.dispatch({ key: 'k', meta: true })
    assert_same self, captured
    assert_equal 1, counter.n
  end

  def test_register_without_block_raises
    assert_raises(ArgumentError) { registry.register('meta+s') }
  end

  def test_reregister_overrides_last_wins
    # 热插拔语义：同 chord+scope 后注册者赢（注释见 ShortcutRegistry#register）
    h = registry
    log = []
    h.register('a') { log << :first }
    h.register('a') { log << :second }
    assert_equal true, h.dispatch({ key: 'a' })
    assert_equal [:second], log
  end

  def test_unregister_removes_handler
    h = registry
    log = []
    h.register('meta+s') { log << :saved }
    h.unregister('meta+s')
    assert_equal false, h.dispatch({ key: 's', meta: true })
    assert_empty log
  end

  def test_unregister_scoped_does_not_touch_global
    h = registry
    log = []
    h.register('meta+s') { log << :global }
    h.unregister('meta+s', scope: :editor)
    assert_equal true, h.dispatch({ key: 's', meta: true })
    assert_equal [:global], log
  end

  def test_registries_are_independent
    a = registry
    b = registry
    a.register('x') { :a }
    assert_equal false, b.dispatch({ key: 'x' })
  end

  # ── scope 路由 ────────────────────────────────────────

  def test_scoped_dispatch_prefers_app_over_global
    h = registry
    log = []
    h.register('meta+s') { log << :global }
    h.register('meta+s', scope: :editor) { log << :editor }
    assert_equal true, h.dispatch({ key: 's', meta: true }, scope: :editor)
    assert_equal [:editor], log
  end

  def test_scoped_dispatch_falls_back_to_global
    h = registry
    log = []
    h.register('meta+s') { log << :global }
    assert_equal true, h.dispatch({ key: 's', meta: true }, scope: :editor)
    assert_equal [:global], log
  end

  def test_scoped_entry_does_not_leak_to_global
    h = registry
    log = []
    h.register('meta+s', scope: :editor) { log << :editor }
    assert_equal false, h.dispatch({ key: 's', meta: true })
    assert_equal false, h.dispatch({ key: 's', meta: true }, scope: :files)
    assert_empty log
  end

  def test_global_dispatch_ignores_scoped_tables
    h = registry
    log = []
    h.register('meta+s') { log << :global }
    h.register('meta+s', scope: :editor) { log << :editor }
    assert_equal true, h.dispatch({ key: 's', meta: true })
    assert_equal [:global], log
  end

  def test_scope_string_normalized_to_symbol
    h = registry
    log = []
    h.register('meta+s', scope: :editor) { log << :editor }
    assert_equal true, h.dispatch({ key: 's', meta: true }, scope: 'editor')
    assert_equal [:editor], log
  end

  # ── 模块级入口（PLAN §3.6 的 Emerald.hotkey 形态）─────

  def test_module_level_hotkey_registry
    assert_same Emerald.hotkey, Emerald.hotkey
    Emerald.hotkey.register('meta+z') { :z }
    assert_equal true, Emerald.hotkey.dispatch({ key: 'z', meta: true })
  ensure
    Emerald.hotkey.unregister('meta+z')
  end
end

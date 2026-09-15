# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'
require 'emerald/commands'

class CommandRegistryTest < Minitest::Test
  def setup
    @reg = Emerald::CommandRegistry.new
    @reg.register('hello.say', title: '问好', hotkey: 'meta+h') { :said }
    @reg.register(:'app.quit', title: '退出') { :quit }
  end

  def test_register_normalizes_id_to_symbol_and_returns_self
    assert_equal @reg, @reg.register(:'x.y', title: 'X') { nil }
    assert @reg.command?(:'x.y')
  end

  def test_run_invokes_handler_without_args_and_returns_its_value
    assert_equal :said, @reg.run('hello.say')
    assert_equal :quit, @reg.run(:'app.quit')
  end

  def test_duplicate_id_raises_argument_error
    error = assert_raises(ArgumentError) do
      @reg.register('hello.say', title: '另一个问好') { nil }
    end
    refute_empty error.message
  end

  def test_register_without_handler_raises_argument_error
    assert_raises(ArgumentError) { @reg.register(:'x.y', title: 'X') }
  end

  def test_unregister_hit_returns_true_and_unknown_returns_nil
    assert_equal true, @reg.unregister('hello.say')
    refute @reg.command?(:'hello.say')
    assert_nil @reg.unregister(:'never.existed')
  end

  def test_unregister_then_register_again_works
    @reg.unregister('hello.say')
    @reg.register('hello.say', title: '问好 v2') { :v2 }
    assert_equal :v2, @reg.run('hello.say')
  end

  def test_run_unknown_id_raises_argument_error
    assert_raises(ArgumentError) { @reg.run(:'nope.nada') }
  end

  def test_command_predicate
    assert @reg.command?(:'hello.say')
    assert @reg.command?('app.quit')
    refute @reg.command?(:'nope.nada')
  end

  def test_commands_snapshot_in_registration_order_with_hotkey_nil
    assert_equal [
      { id: :'hello.say', title: '问好', hotkey: 'meta+h' },
      { id: :'app.quit', title: '退出', hotkey: nil }
    ], @reg.commands
  end

  def test_commands_snapshot_is_isolated_from_internal_state
    snap = @reg.commands
    snap << { id: :injected, title: 'X', hotkey: nil }
    snap.first[:title] = '篡改'
    assert_equal 2, @reg.commands.size
    assert_equal '问好', @reg.commands.first[:title]
  end

  def test_each_walks_registration_order
    ids = []
    @reg.each { |cmd| ids << cmd[:id] }
    assert_equal [:'hello.say', :'app.quit'], ids
  end
end

# frozen_string_literal: true

# E5a · NotificationCenter（PLAN §3.5）：push 封顶淘汰 / kind 白名单 /
# 快照枚举（F9）/ dismiss / clear。纯数据层，不碰 Timer 与渲染。
require 'minitest/autorun'
require 'emerald'

class NotifyTest < Minitest::Test
  def test_push_returns_note_with_three_keys
    center = Emerald::NotificationCenter.new
    undo = -> {}
    note = center.push('已保存', kind: :success, actions: [{ 'label' => '撤销', 'action' => undo }])

    assert_kind_of Hash, note
    assert_equal %w[msg kind actions], note.keys

    titled = center.push('主机已就绪', kind: :success, title: '系统')
    assert_equal %w[msg kind actions title], titled.keys
    assert_equal '系统', titled['title']
    assert_equal '已保存', note['msg']
    assert_equal :success, note['kind']
    assert_equal [{ 'label' => '撤销', 'action' => undo }], note['actions']
  end

  def test_push_defaults_kind_info_and_empty_actions
    center = Emerald::NotificationCenter.new
    note = center.push('普通消息')

    assert_equal :info, note['kind']
    assert_equal [], note['actions']
  end

  def test_kind_nil_means_default_info
    center = Emerald::NotificationCenter.new
    assert_equal :info, center.push('x', kind: nil)['kind']
  end

  def test_count_tracks_pushes
    center = Emerald::NotificationCenter.new
    assert_equal 0, center.count
    center.push('一')
    center.push('二')
    assert_equal 2, center.count
  end

  def test_each_yields_note_and_index_in_push_order
    center = Emerald::NotificationCenter.new
    center.push('一', kind: :info)
    center.push('二', kind: :error)

    seen = []
    center.each { |note, i| seen << [note['msg'], note['kind'], i] }
    assert_equal [['一', :info, 0], ['二', :error, 1]], seen
  end

  def test_each_without_block_returns_enumerator
    center = Emerald::NotificationCenter.new
    center.push('一')

    enum = center.each
    assert_kind_of Enumerator, enum
    assert_equal [['一', 0]], enum.map { |note, i| [note['msg'], i] }
  end

  def test_each_iterates_over_frozen_snapshot
    center = Emerald::NotificationCenter.new
    center.push('一')
    center.push('二')

    seen = []
    center.each do |note, i|
      seen << [note['msg'], i]
      center.push('三') # 枚举期间新增：不得出现在本次遍历里
    end
    assert_equal [['一', 0], ['二', 1]], seen
    assert_equal 4, center.count # 块内两次 push 都落在快照外，下轮 each 才可见
  end

  def test_dismiss_removes_by_index
    center = Emerald::NotificationCenter.new
    center.push('一')
    center.push('二')
    center.push('三')

    center.dismiss(1)
    assert_equal 2, center.count
    assert_equal %w[一 三], center.each.map { |note, _i| note['msg'] }
  end

  def test_dismiss_out_of_range_is_noop
    center = Emerald::NotificationCenter.new
    center.push('一')
    assert_nil center.dismiss(9)
    assert_equal 1, center.count
  end

  def test_clear_empties
    center = Emerald::NotificationCenter.new
    center.push('一')
    center.push('二')
    center.clear

    assert_equal 0, center.count
    assert_equal [], center.each.to_a
  end

  def test_limit_evicts_oldest
    center = Emerald::NotificationCenter.new(limit: 3)
    %w[一 二 三 四 五].each { |msg| center.push(msg) }

    assert_equal 3, center.count
    assert_equal %w[三 四 五], center.each.map { |note, _i| note['msg'] }
  end

  def test_limit_is_configurable_per_instance
    center = Emerald::NotificationCenter.new(limit: 1)
    center.push('一')
    center.push('二')

    assert_equal 1, center.count
    assert_equal '二', center.each.first[0]['msg']
  end

  def test_kind_accepts_symbol_and_string_normalized_to_symbol
    center = Emerald::NotificationCenter.new
    center.push('a', kind: :warning)
    center.push('b', kind: 'error')

    kinds = center.each.map { |note, _i| note['kind'] }
    assert_equal %i[warning error], kinds
  end

  def test_invalid_kind_raises_argument_error
    center = Emerald::NotificationCenter.new
    assert_raises(ArgumentError) { center.push('x', kind: :fatal) }
    assert_raises(ArgumentError) { center.push('x', kind: 'fatal') }
    assert_raises(ArgumentError) { center.push('x', kind: 123) }
    assert_equal 0, center.count # 非法 push 一条都不落
  end

  def test_actions_preserved_verbatim
    center = Emerald::NotificationCenter.new
    undo = -> { :undo }
    note = center.push('已保存', actions: [{ 'label' => '撤销', 'action' => undo }])

    assert_same undo, note['actions'].first['action']
  end
end

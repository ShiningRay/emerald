# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'

# 同步 Timer 后端：防抖窗口内的持久化立即执行，便于断言 roundtrip
class SettingsTest < Minitest::Test
  DEFAULTS = { theme: :dark, accent: '#4f8cff', wallpaper: :aurora, density: :comfortable }.freeze

  def setup
    @backend_was = Beryl::Timer.backend
    @cancel_was = Beryl::Timer.cancel_backend
    Beryl::Timer.backend = ->(_ms, blk) { blk.call }
  end

  def teardown
    Beryl::Timer.backend = @backend_was
    Beryl::Timer.cancel_backend = @cancel_was
  end

  def store(storage: nil, defaults: DEFAULTS)
    Emerald::SettingsStore.new(storage: storage, defaults: defaults)
  end

  def test_defaults_before_load
    s = store
    assert_equal :dark, s.get(:theme)
    assert_equal '#4f8cff', s.get(:accent)
  end

  def test_get_subscribes_when_read_inside_effect
    s = store
    seen = []
    Citrine::Effect.create { seen << s.get(:theme) }
    assert_equal [:dark], seen

    s.set(:theme, :light)
    assert_equal %i[dark light], seen
  end

  def test_peek_does_not_subscribe
    s = store
    seen = []
    Citrine::Effect.create { seen << s.peek(:theme) }
    s.set(:theme, :light)
    assert_equal [:dark], seen
  end

  def test_set_returns_value_and_reads_back
    s = store
    assert_equal :light, s.set(:theme, :light)
    assert_equal :light, s.get(:theme)
  end

  def test_string_key_normalized_to_symbol
    s = store
    assert_equal :dark, s.get('theme')
    s.set('theme', :light)
    assert_equal :light, s.get(:theme)
  end

  def test_unknown_key_fails_fast
    s = store
    assert_raises(ArgumentError) { s.get(:nope) }
    assert_raises(ArgumentError) { s.set(:nope, 1) }
  end

  def test_all_returns_plain_snapshot
    s = store
    snapshot = s.all
    assert_equal DEFAULTS, snapshot
    snapshot[:theme] = :mutated
    assert_equal :dark, s.get(:theme) # 快照可随意改，不影响内部
  end

  def test_load_noop_without_storage
    s = store
    assert_same s, s.load
    assert_equal :dark, s.get(:theme) # 保持默认
  end

  def test_persistence_roundtrip_with_memory
    mem = Emerald::Storage::Memory.new
    s = store(storage: mem)
    s.set(:theme, :light)
    s.set(:density, :compact)

    fresh = store(storage: mem)
    fresh.load
    assert_equal :light, fresh.get(:theme)
    assert_equal :compact, fresh.get(:density)
    assert_equal :aurora, fresh.get(:wallpaper) # 未写的键回退默认
  end

  def test_load_is_idempotent_and_does_not_clobber_later_sets
    mem = Emerald::Storage::Memory.new
    s = store(storage: mem)
    s.set(:theme, :light)

    s.load
    s.set(:theme, :dark)
    s.load # 再次 load 不应把 :dark 冲掉（@loaded 守卫）
    assert_equal :dark, s.get(:theme)
  end

  def test_load_tolerates_garbage_data
    mem = Emerald::Storage::Memory.new
    mem.dump(Emerald::SettingsStore::STORAGE_KEY, 'garbage')
    s = store(storage: mem)
    assert_same s, s.load
    assert_equal :dark, s.get(:theme)
  end
end

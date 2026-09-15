# frozen_string_literal: true

module Emerald
  # 设置存储（PLAN §3.4）：读取即 Signal（`get` 在 Effect/view 内读即订阅），
  # `set` 写 + 调度持久化（防抖 300ms 经 storage.dump）。
  # key 归一为 Symbol；未知 key（defaults 没有的）get/set 时 ArgumentError fail fast。
  # 存储 key 为 'emerald.settings.v1'（分 key 分版本，D6）。
  class SettingsStore
    STORAGE_KEY = 'emerald.settings.v1'
    DEBOUNCE_MS = 300

    def initialize(storage: nil, defaults: {})
      @storage = storage
      @defaults = defaults.transform_keys(&:to_sym)
      @signals = {} # key => Citrine::Signal（惰性创建）
      @timers = {}  # key => 未执行的持久化 Timer handle
      @loaded = false
    end

    # 从 storage 恢复（无数据则保持默认）；storage 为 nil 时 no-op。
    # 恢复值不广播（build_signals! 直接写入内部信号），供首渲染前调用防闪变。
    def load
      return self if @storage.nil? || @loaded

      data = @storage.load(STORAGE_KEY)
      build_signals!(data) if data.is_a?(Hash)
      @loaded = true
      self
    end

    def get(key)
      signal_for(key).get
    end

    def set(key, value)
      signal_for(key).set(value)
      @timers[key] = debounce(@timers[key]) do
        @storage&.dump(STORAGE_KEY, all)
      end
      value
    end

    # 不订阅读取（peek 语义，按需用）
    def peek(key)
      signal_for(key).peek
    end

    # 全部当前值的普通 Hash 快照
    def all
      @defaults.each_key.to_h { |k| [k, peek(k)] }
    end

    private

    def known?(key)
      @defaults.key?(key)
    end

    def signal_for(key)
      key = normalize_key(key)
      raise ArgumentError, "未知设置项: #{key.inspect}" unless known?(key)

      @signals[key] ||= Citrine.signal(@defaults[key])
    end

    def normalize_key(key)
      key.is_a?(String) || key.is_a?(Symbol) ? key.to_sym : key
    end

    # 恢复时值直接灌进信号：绕开 set 以免未恢复完全的中间态触发广播/误调度持久化
    def build_signals!(data)
      @defaults.each_key do |k|
        stored = Beryl.pick(data, k)
        @signals[k] = Citrine.signal(stored.nil? ? @defaults[k] : stored)
      end
    end

    # 每次 dump 取消该 key 上次未执行的 handle 再重排（Beryl::Timer.cancel）
    def debounce(pending)
      Beryl::Timer.cancel(pending)
      Beryl::Timer.after(DEBOUNCE_MS) { yield }
    end
  end
end

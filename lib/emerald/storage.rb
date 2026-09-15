# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  # 持久化适配协议（PLAN §3.4 / D6：分 key 分版本、启动同步 load、写后防抖 300ms）：
  # 上层（VFS / SettingsStore）只依赖 `load(key) -> obj|nil` 与 `dump(key, obj)`，
  # 后端可换（CRuby 测试注入 Memory；浏览器走 localStorage；OPFS 列 v1.1 评估）。
  module Storage
    # 纯 CRuby 内存后端：Hash 直存 Ruby 对象（不序列化，测试友好）。
    class Memory
      def initialize
        @data = {}
      end

      def load(key)
        @data.key?(key) ? @data[key] : nil
      end

      def dump(key, obj)
        @data[key] = obj
      end
    end

    # localStorage 后端（仅 Opal）：JSON 序列化，key 加 `namespace:` 前缀，
    # 写防抖 300ms——每次 dump 取消该 key 上次未执行的 Timer handle 再重排。
    # CRuby 下实例化即 raise（只允许 Opal 环境用，测试请注入 Memory）。
    class LocalStorage
      DEBOUNCE_MS = 300

      def initialize(namespace: 'emerald')
        raise 'Emerald::Storage::LocalStorage 仅可在 Opal（浏览器）环境使用' unless defined?(Opal)

        @namespace = namespace
        @timers = {} # key => 未执行的 Timer handle
      end

      def load(key)
        raw = local_storage["#{@namespace}:#{key}"]
        raw ? `JSON.parse(#{raw})` : nil
      end

      def dump(key, obj)
        Beryl::Timer.cancel(@timers[key])
        @timers[key] = Beryl::Timer.after(DEBOUNCE_MS) do
          @timers.delete(key)
          local_storage["#{@namespace}:#{key}"] = `JSON.stringify(#{obj.to_n})`
        end
        nil
      end

      private

      def local_storage
        `window.localStorage`
      end
    end
  end
end

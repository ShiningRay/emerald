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

    # native JS 值 → Ruby 对象（仅 Opal 有意义）：JSON.parse 的产物是裸 JS
    # 对象，连 is_a?/[] 都调不了（E7 前置修复：浏览器带数据重载在 VFS/Settings
    # 的 data.is_a?(Hash) 处 TypeError 崩溃）。对象 → Hash，数组原生直通（Opal
    # 已给 Array.prototype 打 Ruby 方法补丁），标量原生，null/undefined → nil。
    # CRuby 下原样返回（Memory 后端存的本来就是 Ruby 对象）。
    def self.from_native(obj)
      return obj unless defined?(Opal)

      # backtick_javascript: true
      %x{
        if (obj === null || obj === undefined) return nil;
        if (typeof obj !== 'object') return obj;
        if (Array.isArray(obj)) {
          var out = [];
          for (var i = 0; i < obj.length; i++) out.push(#{from_native(`obj[i]`)});
          return out;
        }
        var h = Opal.Hash.$new();
        for (var k in obj) {
          if (Object.prototype.hasOwnProperty.call(obj, k)) {
            h.$store(k, self.$from_native(obj[k]));
          }
        }
        return h;
      }
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
        # 原生对象取值必须走 JS API：local_storage["x"] 会被编译成 $[] 调用，
        # navigator 对象上没有（E7 浏览器验收时发现的潜伏 bug）。
        # getItem 的 null 回到 Ruby 侧即 nil。
        raw = `window.localStorage.getItem(#{full_key(key)})`
        raw ? Emerald::Storage.from_native(`JSON.parse(#{raw})`) : nil
      end

      def dump(key, obj)
        Beryl::Timer.cancel(@timers[key])
        @timers[key] = Beryl::Timer.after(DEBOUNCE_MS) do
          @timers.delete(key)
          `window.localStorage.setItem(#{full_key(key)}, JSON.stringify(#{obj.to_n}))`
        end
        nil
      end

      private

      def full_key(key)
        "#{@namespace}:#{key}"
      end
    end
  end
end

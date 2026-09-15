# frozen_string_literal: true

module Emerald
  # 快捷键注册表（docs/PLAN.md §3.6）：chord 解析 + scope 路由。
  #
  # chord 是 "meta+ctrl+alt+shift+主键" 的归一化字符串：修饰键固定序
  #（meta→ctrl→alt→shift，乱序输入会重排）、主键小写；纯修饰键不构成
  # chord（缺主键 → ArgumentError）。
  #
  # scope 路由：dispatch 不带 scope（或 :global）只查全局表；带应用级
  # scope 时先查该 scope 表、查不到回退全局表——应用级快捷键优先，
  # 全局兜底（⌘S 保存这类系统默认不被单个应用抢占，除非它想覆盖）。
  #
  # 纯 CRuby：事件源只是 Hash/String/KeyEvent 形态的纯数据，将来 shell
  # 把 citrine window_key 接到 dispatch 即可（现在不接线）。
  # 稳定后反哺 beryl Beryl.hotkey（beryl PLAN M-WM+ 已定，见 emerald PLAN §5）。
  class ShortcutRegistry
    # 修饰键固定序（输出 chord 的拼接顺序）
    MODIFIERS = %w[meta ctrl alt shift].freeze

    def initialize
      @global = {}
      @scoped = {}
    end

    # 注册：chord 字符串（'meta+s'）+ 可选 scope（缺省 :global）。
    # 同 chord+scope 重复注册直接覆盖、最后注册者赢——这是刻意的热插拔
    # 语义：应用热重载/设置重载时新处理器原地生效，调用方无需先
    # unregister 再 register（配对漏一次就漏快捷键，覆盖则无状态负担）。
    # 块以普通 Proc 存储、call 执行，闭包 self 不重绑（beryl F1）。
    def register(chord, scope: :global, &handler)
      raise ArgumentError, '快捷键注册需要块（register 的 &handler 缺失）' unless handler

      table_for(normalize_scope(scope))[normalize_chord(chord)] = handler
      self
    end

    # 注销该 scope 表里的 chord（只影响指定表，不会连带全局兜底）。
    def unregister(chord, scope: :global)
      table_for(normalize_scope(scope)).delete(normalize_chord(chord))
      self
    end

    # 分发：event 归一成 chord 后查表；命中执行块并返回 true，
    # 未命中返回 false 且无任何副作用。
    def dispatch(event, scope: :global)
      chord = chord_for(event)
      handler = lookup(chord, normalize_scope(scope))
      return false unless handler

      handler.call
      true
    end

    # 事件 → 归一 chord。接受三种形态：
    # - Hash：symbol/string 键均可、键名大小写不敏感，取 key/meta/ctrl/
    #   alt/shift 五槽位（修饰键缺省 nil，nil 视为 false）；
    # - String：当作 chord 归一（'ctrl+shift+P' / 'f' / 纯修饰键报错）；
    # - KeyEvent 形态的对象（respond_to key/meta?/...）：citrine window_key
    #   的 KeyEvent 直接可喂，shell 接线时零转换。
    def chord_for(event)
      if event.is_a?(Hash)
        flat = {}
        event.each { |k, v| flat[k.to_s.downcase] = v }
        chord_from_parts(flat['key'],
                         meta: flat['meta'], ctrl: flat['ctrl'],
                         alt: flat['alt'], shift: flat['shift'])
      elsif event.respond_to?(:key) && event.respond_to?(:meta?)
        chord_from_parts(event.key,
                         meta: event.meta?, ctrl: event.ctrl?,
                         alt: event.alt?, shift: event.shift?)
      else
        normalize_chord(event.to_s)
      end
    end

    private

    # 归一 chord：分段（'+' 分隔）→ 小写、去空白、去重复修饰键、
    # 修饰键按固定序排、主键必须唯一且存在。
    # 空格键特殊处理：KeyboardEvent.key 对空格返回 ' '（纯空白段），
    # 归一成单词 'space'——⌘Space 启动器（PLAN §3.6 内置默认）依赖它。
    # 连续 '+'（如 'ctrl++'）不被解释成加号主键，请写 'ctrl+='。
    def normalize_chord(input)
      tokens = input.to_s.split('+').map { |seg|
        stripped = seg.strip.downcase
        if stripped.empty?
          seg =~ /\s/ ? 'space' : nil # 空白段是空格键；空段（'a++b'）丢弃
        else
          stripped
        end
      }.compact
      raise ArgumentError, "快捷键 chord 缺主键：#{input.inspect}" if tokens.empty?

      mains = tokens.reject { |t| MODIFIERS.include?(t) }
      raise ArgumentError, "快捷键 chord 只能有一个主键：#{input.inspect}" if mains.size > 1
      raise ArgumentError, "快捷键 chord 缺主键（纯修饰键）：#{input.inspect}" if mains.empty?

      (MODIFIERS.select { |m| tokens.include?(m) } + mains).join('+')
    end

    # 从分离的槽位拼 chord 再走归一（大小写/乱序/重复全在归一里兜）
    def chord_from_parts(key, meta:, ctrl:, alt:, shift:)
      parts = []
      parts << 'meta' if meta
      parts << 'ctrl' if ctrl
      parts << 'alt' if alt
      parts << 'shift' if shift
      parts << key.to_s
      normalize_chord(parts.join('+'))
    end

    # scope 归一：symbol 优先；string 顺手 to_sym（'editor' 与 :editor 同表），
    # 其余类型原样作哈希键
    def normalize_scope(scope)
      scope.respond_to?(:to_sym) ? scope.to_sym : scope
    end

    def table_for(scope)
      scope == :global ? @global : (@scoped[scope] ||= {})
    end

    # 路由：:global 只查全局表；应用级 scope 先查本表再回退全局
    def lookup(chord, scope)
      if scope == :global
        @global[chord]
      else
        @scoped.fetch(scope, {})[chord] || @global[chord]
      end
    end
  end

  # 系统级注册表入口（PLAN §3.6 的 Emerald.hotkey.register 形态）：
  # shell 与应用共享同一实例；单测请自建 ShortcutRegistry.new，别污染它
  def self.hotkey
    @hotkey ||= ShortcutRegistry.new
  end
end

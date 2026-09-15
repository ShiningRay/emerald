# frozen_string_literal: true

module Emerald
  # 命令统一注册入口（VS Code contributes.commands 模型，docs/SPEC-package-format.md §4.1）：
  # 一条命令注册一次，启动器/菜单/快捷键三处消费同一张表。
  # 重复 id fail fast（坏的是包代码，早炸早知道；应用卸载走 unregister 后可重装）。
  # 纯 CRuby 零依赖，可单测。
  class CommandRegistry
    def initialize
      @table = {} # Symbol id → { id:, title:, hotkey:, handler: }，插入序即注册序
    end

    # id 归一为 Symbol；title 必填（缺省由 Ruby 关键字参数直接报错）
    def register(id, title:, hotkey: nil, &handler)
      raise ArgumentError, '命令注册需要块（register 的 &handler 缺失）' unless handler

      key = id.to_sym
      raise ArgumentError, "命令 #{key} 已注册" if @table.key?(key)

      @table[key] = { id: key, title: title, hotkey: hotkey, handler: handler }
      self
    end

    # 未知 id 是 no-op 返回 nil（卸载可幂等重试），命中删除返回 true
    def unregister(id)
      return nil unless @table.key?(id.to_sym)

      @table.delete(id.to_sym)
      true
    end

    # 未知 id raise ArgumentError；无参调用 handler，透传其返回值
    def run(id)
      entry = @table[id.to_sym]
      raise ArgumentError, "未知命令 #{id}" unless entry

      entry[:handler].call
    end

    def command?(id)
      @table.key?(id.to_sym)
    end

    # 快照数组 [{ id:, title:, hotkey: }]（新哈希新数组，防外部改穿；不外泄 handler）
    def commands
      @table.values.map { |e| { id: e[:id], title: e[:title], hotkey: e[:hotkey] } }
    end

    # 便捷遍历（同 commands 顺序），yield 快照条目
    def each(&blk)
      commands.each(&blk)
      self
    end
  end
end

# frozen_string_literal: true

module Emerald
  # 通知中心（L5 系统服务，PLAN §3.5）：Toast 堆叠的数据层。
  # beryl demo 的「push_bounded 封顶堆叠」模式正式化（beryl F9）：
  # 内部一条 Citrine.signal_list，push 走 push_bounded 一次通知完成「追加 + 封顶」；
  # 枚举走 get 的冻结快照（F9），快照就地改写当场 FrozenError。
  # 纯 CRuby，零 Opal——浏览器侧的渲染与到期删除由 shell 消费 each/dismiss 完成。
  class NotificationCenter
    # kind 白名单：symbol / string 都收，归一为 symbol（Toast css_class 直接用）
    KINDS = %i[info success warning error].freeze

    attr_reader :limit

    def initialize(limit: 5)
      @limit = limit
      @notes = Citrine.signal_list([])
    end

    # 推入一条通知，返回 note 哈希（'msg' / 'kind' / 'actions' 三键；
    # 传 title 时附带第四键——Beryl::Notification 的标题语义）。
    # 超过 limit 时淘汰最旧的（push_bounded 既有语义）。
    def push(msg, kind: :info, actions: [], title: nil)
      note = { 'msg' => msg, 'kind' => normalize_kind(kind), 'actions' => actions }
      note['title'] = title if title
      @notes.push_bounded(note, limit)
      note
    end

    # 快照枚举，块收 (note, index)；无块返回 Enumerator。
    # shell 的 Toast 堆叠在 view 里调用即建立订阅（get 的读跟踪），
    # auto_dismiss 到期回调里按 index dismiss。
    def each(&block)
      return enum_for(:each) unless block

      @notes.get.each_with_index(&block)
    end

    # 按序号删（Toast 到期 / 用户点掉都走这里）
    def dismiss(i)
      @notes.delete_at(i)
    end

    def count
      @notes.size
    end

    def clear
      @notes.clear
    end

    private

    # kind 归一：nil 视为缺省（info）；symbol/string 收进来统一成 symbol；
    # 其余一律 ArgumentError——错误在入口炸，不能流到渲染层。
    def normalize_kind(kind)
      return :info if kind.nil?

      sym = kind.respond_to?(:to_sym) ? kind.to_sym : nil
      return sym if sym && KINDS.include?(sym)

      raise ArgumentError, "非法 kind: #{kind.inspect}（白名单 #{KINDS.join('/')}）"
    end
  end
end

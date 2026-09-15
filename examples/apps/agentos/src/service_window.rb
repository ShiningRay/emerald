# frozen_string_literal: true

# AgentOS Service 窗口（阶段一 · HTTP 轮询版）——每个 Service endpoint 一扇窗。
# 窗口内容四段（设计文档 emerald-desktop-ui-design-2026-09-15.md §3.2）：
#   ①头部：service 名 + running 状态圆点（绿/灰）+ mailbox 待处理/处理中计数
#   ②state 面板：服务端 state Hash 渲染为键值表，值超 120 字符截断、点击展开全文
#   ③消息队列：pending / processing 双栏消息卡片（kind 徽标、from→to、内容、时间）
#   ④互动条：输入框 + 发送（Service 支持同步应答，kind 固定 :ask）+ normal/urgent 切换
# 结构照 Calculator 模板：Presenter 纯展示内核（零 UI/信号依赖，CRuby 可测）
# + App 薄壳（只读 LinkService signal、渲染、把动作派回 send_message）。
# 防御纪律：LinkService 未启动（instance 为 nil）或 endpoint 未上报时渲染占位文案，
# 绝不崩溃——Citrine.render(App.new) 无 boot 也必须可渲染。
# entry 在运行时已加载（Emerald::App 可用）的前提下求值，自身不 require。
module AgentOSDesk
  class ServiceWindow < Emerald::App
    # 纯展示内核：把 LinkService 的原始数据（service 条目 / mailboxes 快照）
    # 归一成视图直接可用的结构（状态行、消息卡片、徽标、截断串）。
    # 不碰 Citrine 信号与元素 DSL，输入输出全是纯 Ruby 值，可脱离 UI 完整单测。
    class Presenter
      STATE_VALUE_LIMIT = 120 # state 值截断上限（字符），点击展开全文

      # 状态圆点：running 绿 / 其余（含条目缺失）灰
      DOT_RUNNING = '#10b981'
      DOT_OTHER = '#9ca3af'

      # kind → [徽标文字, 底色]；未知 kind 兜底原样展示（防御 Observer 新增类型）
      KIND_BADGES = {
        'ask' => ['询问', '#0ea5e9'],
        'task' => ['任务', '#7c3aed'],
        'answer' => ['回答', '#10b981'],
        'question' => ['质询', '#f59e0b'],
        'event' => ['事件', '#64748b'],
        'control' => ['控制', '#ef4444']
      }.freeze
      FALLBACK_BADGE_COLOR = '#475569'

      attr_reader :endpoint

      def initialize(endpoint)
        @endpoint = endpoint.to_s
      end

      # services 数组里定位本窗口的 endpoint；元素类型不符 / 缺 name 键一律跳过
      def service_entry(services)
        return nil if @endpoint.empty?

        Array(services).find do |svc|
          svc.is_a?(Hash) && pick(svc, :name).to_s == @endpoint
        end
      end

      def running?(service)
        service.is_a?(Hash) && pick(service, :running) == true
      end

      def dot_color(service)
        running?(service) ? DOT_RUNNING : DOT_OTHER
      end

      # 状态文字用线格式词（设计文档 §3.2 标题栏 `⚙️ bash · ● running`，
      # 与 AgentWindow 渲染 last_status 原词同口径）；条目缺失时诚实显示"未知"
      def status_text(service)
        return '未知' unless service.is_a?(Hash)

        running?(service) ? 'running' : 'stopped'
      end

      # mailbox 计数 [pending, processing]（缺键 / nil 一律 0）
      def mailbox_counts(service)
        return [0, 0] unless service.is_a?(Hash)

        [pick(service, :mailbox_pending).to_i, pick(service, :mailbox_processing).to_i]
      end

      # service 条目 → [[键, 值字符串], ...]；state 为 nil / 非 Hash / 空 → []
      def state_rows(service)
        return [] unless service.is_a?(Hash)

        state = pick(service, :state)
        return [] unless state.is_a?(Hash) && state.any?

        state.map { |key, value| [key.to_s, value.nil? ? '—' : value.to_s] }
      end

      def long_value?(text)
        text.to_s.length > STATE_VALUE_LIMIT
      end

      # 截断展示：expanded 给全文；未展开截到 LIMIT 并加省略号。
      # 返回 [显示串, 是否被截断]
      def state_value(text, expanded)
        return [text, false] if expanded || !long_value?(text)

        ["#{text[0, STATE_VALUE_LIMIT]}…", true]
      end

      # mailboxes → [pending 卡片数组, processing 卡片数组]（msg 防御缺字段）
      def queue_cards(mailboxes)
        box = (mailboxes || {})[@endpoint]
        box = {} unless box.is_a?(Hash)
        [pick(box, :pending), pick(box, :processing)].map do |msgs|
          Array(msgs).select { |m| m.is_a?(Hash) }.map { |m| message_card(m) }
        end
      end

      # string 键 msg（契约：message_id/from/to/thread_id/task_id/in_reply_to/
      # kind/content/priority/created_at）→ 视图卡片 Hash
      def message_card(msg)
        kind = msg['kind'].to_s
        badge = KIND_BADGES[kind] || [kind.empty? ? '消息' : kind, FALLBACK_BADGE_COLOR]
        {
          kind_label: badge[0],
          kind_color: badge[1],
          from: presence(msg['from']),
          to: presence(msg['to']),
          content: msg['content'].to_s,
          time: format_time(msg['created_at']),
          urgent: msg['priority'].to_s == 'urgent'
        }
      end

      # created_at 可能是 epoch 数 / ISO 字符串 / nil，统一成可展示串
      def format_time(value)
        case value
        when Numeric then Time.at(value).strftime('%Y-%m-%d %H:%M:%S')
        when String then value.empty? ? '—' : value
        else '—'
        end
      rescue RangeError, ArgumentError
        value.to_s
      end

      private

      # 契约内层键为 symbol（如 :running / :pending），防御 string 键混入
      def pick(hash, key)
        hash[key].nil? ? hash[key.to_s] : hash[key]
      end

      def presence(value)
        text = value.to_s
        text.empty? ? '—' : text
      end
    end

    app_id :agentos_service
    app_title 'Service'
    app_icon '⚙️'
    singleton false
    default_geometry { { x: 140, y: 100, w: 480, h: 460 } }

    state :input, default: ''          # 互动条草稿
    state :priority, default: :normal  # :normal / :urgent 切换

    MONO = 'ui-monospace, Menlo, monospace'

    ROOT_STYLE = { width: '100%', height: '100%', padding: '12px',
                   background: '#ffffff', color: '#111827', font_size: 13,
                   overflow: 'auto' }.freeze
    HEADER_STYLE = { align_items: 'center', padding_bottom: 8,
                     border_bottom: '1px solid #e5e7eb' }.freeze
    DOT_STYLE = { width: 10, height: 10, border_radius: '50%', flex_shrink: 0 }.freeze
    TITLE_STYLE = { font_size: 16, font_weight: 700 }.freeze
    STATUS_STYLE = { color: '#6b7280', font_size: 12 }.freeze
    SPACER_STYLE = { flex: 1 }.freeze
    COUNT_STYLE = { color: '#6b7280', font_size: 12, white_space: 'nowrap' }.freeze
    OFFLINE_STYLE = { background: '#fef2f2', color: '#b91c1c', font_size: 12,
                      border: '1px solid #fecaca', border_radius: 6,
                      padding: '6px 8px' }.freeze
    SECTION_CAPTION_STYLE = { color: '#6b7280', font_size: 12, font_weight: 700 }.freeze
    PANEL_STYLE = { border: '1px solid #e5e7eb', border_radius: 8, padding: 8 }.freeze
    EMPTY_STYLE = { color: '#9ca3af' }.freeze
    STATE_KEY_STYLE = { width: 140, flex_shrink: 0, color: '#6b7280',
                        font_family: MONO, font_size: 12, word_break: 'break-all' }.freeze
    STATE_VALUE_STYLE = { flex: 1, min_width: 0, font_family: MONO, font_size: 12,
                          white_space: 'pre-wrap', word_break: 'break-all' }.freeze
    # 超长值渲染成 button（点击展开/收起），视觉与纯文本一致
    STATE_VALUE_BUTTON_STYLE = STATE_VALUE_STYLE.merge(
      background: 'transparent', border: 'none', padding: 0,
      text_align: 'left', color: '#111827', cursor: 'pointer'
    ).freeze
    QUEUE_STYLE = { flex: 1, min_height: 0 }.freeze
    QUEUE_COLUMNS_STYLE = { flex: 1, min_height: 0, align_items: 'flex-start' }.freeze
    QUEUE_LIST_STYLE = { overflow: 'auto', max_height: 260 }.freeze
    COLUMN_TITLE_STYLE = { color: '#374151', font_size: 12, font_weight: 700 }.freeze
    CARD_STYLE = { border: '1px solid #e5e7eb', border_radius: 6,
                   padding: '6px 8px', background: '#f9fafb' }.freeze
    CARD_HEAD_STYLE = { align_items: 'center' }.freeze
    CARD_META_STYLE = { color: '#6b7280', font_size: 11 }.freeze
    CARD_CONTENT_STYLE = { font_size: 12, white_space: 'pre-wrap',
                           word_break: 'break-all' }.freeze
    TIME_STYLE = { color: '#9ca3af', font_size: 11, white_space: 'nowrap' }.freeze
    URGENT_BADGE_STYLE = { background: '#fee2e2', color: '#b91c1c', font_size: 11,
                           padding: '1px 6px', border_radius: 4 }.freeze
    BADGE_BASE = { color: '#ffffff', font_size: 11, padding: '1px 6px',
                   border_radius: 4, white_space: 'nowrap' }.freeze
    COMPOSE_STYLE = { align_items: 'center', padding_top: 8,
                      border_top: '1px solid #e5e7eb' }.freeze
    INPUT_STYLE = { flex: 1, min_width: 0, padding: '6px 8px', font_size: 13,
                    border: '1px solid #d1d5db', border_radius: 6 }.freeze
    SEND_STYLE = { padding: '6px 14px', border: 'none', border_radius: 6, font_size: 13,
                   background: '#10b981', color: '#ffffff', cursor: 'pointer' }.freeze
    PRIORITY_NORMAL_STYLE = { padding: '6px 10px', border: '1px solid #d1d5db',
                              border_radius: 6, background: '#ffffff', color: '#374151',
                              font_size: 13, cursor: 'pointer' }.freeze
    PRIORITY_URGENT_STYLE = { padding: '6px 10px', border: '1px solid #b91c1c',
                              border_radius: 6, background: '#ef4444', color: '#ffffff',
                              font_size: 13, cursor: 'pointer' }.freeze
    PLACEHOLDER_STYLE = { flex: 1, align_items: 'center',
                          justify_content: 'center' }.freeze
    PLACEHOLDER_TITLE_STYLE = { color: '#6b7280', font_size: 14, font_weight: 700 }.freeze
    PLACEHOLDER_HINT_STYLE = { color: '#9ca3af', font_size: 12 }.freeze

    def view
      stack(style: ROOT_STYLE, gap: 10) do
        link = link_service
        if link.nil?
          placeholder('AgentOS 连接未启动', 'AgentOSDesk Link Service 未启动')
        else
          service = presenter.service_entry(read(link.services))
          header_row(service)
          offline_banner(read(link.last_error)) if read(link.offline)
          if service
            state_panel(service)
            queue_section(read(link.mailboxes))
          else
            placeholder("未找到 Service endpoint：#{display_endpoint}",
                        '等待 Observer 上报服务列表…')
          end
          compose_bar
        end
      end
    end

    # ── 互动动作（按钮 / 回车绑定；测试可直接驱动，对齐 calculator #press 惯例）──

    # 优先级切换：normal ↔ urgent
    def toggle_priority
      self.priority = priority == :urgent ? :normal : :urgent
    end

    # 发送草稿：Service 支持同步应答，kind 固定 :ask；发完清空输入。
    # 连接未启动 / 空草稿 / endpoint 缺失时静默忽略，绝不崩溃
    def submit_draft
      link = link_service
      text = input.to_s.strip
      return if link.nil? || text.empty? || endpoint.empty?

      link.send_message(to: endpoint, content: text, kind: :ask, priority: priority)
      self.input = ''
    end

    private

    # LinkService 契约入口：类未加载（integration 前的单文件渲染）或 instance
    # 为 nil（Service 未激活）一律视为未启动，view 走占位文案
    def link_service
      AgentOSDesk::LinkService.instance if defined?(AgentOSDesk::LinkService)
    end

    # endpoint 名来自 launch 的 argv；无 boot / 未传参时容忍为 ''
    def endpoint
      args = argv
      (args && (args[:endpoint] || args['endpoint'])).to_s
    end

    def display_endpoint
      endpoint.empty? ? '（未指定）' : endpoint
    end

    # endpoint 随窗口生命周期不变（launch 时注入），可安全 memoize
    def presenter
      @presenter ||= Presenter.new(endpoint)
    end

    # LinkService 读口是 Citrine::Signal（view 内 .get 即订阅）；实现侧若直接
    # 返回值也兼容（对齐 WorldWindow#read 的防御口径）
    def read(source)
      source.respond_to?(:get) ? source.get : source
    end

    # ── ①头部：状态圆点 + 名 + 状态文字 + mailbox 计数 ──────────
    def header_row(service)
      pending, processing = presenter.mailbox_counts(service)
      row(style: HEADER_STYLE, gap: 8) do
        box(style: DOT_STYLE.merge(background: presenter.dot_color(service)))
        label(style: TITLE_STYLE) { display_endpoint }
        label(style: STATUS_STYLE) { presenter.status_text(service) }
        box(style: SPACER_STYLE)
        label(style: COUNT_STYLE) { "待处理 #{pending} · 处理中 #{processing}" }
      end
    end

    # 离线降级（设计 §4）：offline 置位时窗口内提示并保留最后数据
    def offline_banner(last_error)
      detail = last_error.to_s
      box(style: OFFLINE_STYLE) do
        label { detail.empty? ? '观测端离线' : "观测端离线：#{detail}" }
      end
    end

    # ── ②state 面板：键值表，超长值点击展开 ─────────────────────
    def state_panel(service)
      stack(style: PANEL_STYLE, gap: 6) do
        label(style: SECTION_CAPTION_STYLE) { 'state' }
        rows = presenter.state_rows(service)
        if rows.empty?
          label(style: EMPTY_STYLE) { '（空）' }
        else
          rows.each { |key, value| state_row(key, value) }
        end
      end
    end

    def state_row(key, value)
      expanded = keyed_signal(:state_expanded, key) { false }.get
      row(gap: 8) do
        label(style: STATE_KEY_STYLE) { key }
        if presenter.long_value?(value)
          text, = presenter.state_value(value, expanded)
          button(on_click: -> { toggle_state_key(key) }, style: STATE_VALUE_BUTTON_STYLE) do
            expanded ? "#{text}（收起）" : "#{text}（展开）"
          end
        else
          label(style: STATE_VALUE_STYLE) { value }
        end
      end
    end

    def toggle_state_key(key)
      sig = keyed_signal(:state_expanded, key) { false }
      sig.set(!sig.peek)
    end

    # ── ③消息队列：pending / processing 双栏卡片 ───────────────
    def queue_section(mailboxes)
      pending, processing = presenter.queue_cards(mailboxes)
      stack(style: QUEUE_STYLE, gap: 6) do
        label(style: SECTION_CAPTION_STYLE) { '消息队列' }
        row(style: QUEUE_COLUMNS_STYLE, gap: 8) do
          queue_column('待处理', pending)
          queue_column('处理中', processing)
        end
      end
    end

    def queue_column(title, cards)
      stack(gap: 6, style: { flex: 1, min_height: 0 }) do
        label(style: COLUMN_TITLE_STYLE) { "#{title}（#{cards.size}）" }
        stack(style: QUEUE_LIST_STYLE, gap: 6) do
          if cards.empty?
            label(style: EMPTY_STYLE) { '（空）' }
          else
            cards.each { |card| message_card_node(card) }
          end
        end
      end
    end

    def message_card_node(card)
      box(style: CARD_STYLE, gap: 4) do
        row(style: CARD_HEAD_STYLE, gap: 6) do
          span(style: badge_style(card[:kind_color])) { card[:kind_label] }
          span(style: URGENT_BADGE_STYLE) { '紧急' } if card[:urgent]
          box(style: SPACER_STYLE)
          span(style: TIME_STYLE) { card[:time] }
        end
        label(style: CARD_META_STYLE) { "#{card[:from]} → #{card[:to]}" }
        label(style: CARD_CONTENT_STYLE) { card[:content] }
      end
    end

    def badge_style(color)
      BADGE_BASE.merge(background: color)
    end

    # ── ④互动条：受控输入 + 优先级切换 + 发送（kind 固定 :ask）──
    def compose_bar
      row(style: COMPOSE_STYLE, gap: 8) do
        text_input(value: signal(:input), on_enter: -> { submit_draft },
                   placeholder: "给 #{display_endpoint} 发消息…", style: INPUT_STYLE)
        button(on_click: -> { toggle_priority }, style: priority_style) { priority_text }
        button(on_click: -> { submit_draft }, style: SEND_STYLE) { '发送' }
      end
    end

    def priority_text
      priority == :urgent ? '紧急' : '普通'
    end

    def priority_style
      priority == :urgent ? PRIORITY_URGENT_STYLE : PRIORITY_NORMAL_STYLE
    end

    def placeholder(title, hint)
      box(style: PLACEHOLDER_STYLE) do
        stack(gap: 4, style: { align_items: 'center' }) do
          label(style: PLACEHOLDER_TITLE_STYLE) { title }
          label(style: PLACEHOLDER_HINT_STYLE) { hint }
        end
      end
    end
  end
end

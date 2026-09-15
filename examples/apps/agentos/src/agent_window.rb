# frozen_string_literal: true

# Agent 窗口（examples/apps/agentos 包，阶段一 HTTP 轮询版）：
# 单个 Agent（endpoint）的状态条 + 会话流 + 互动条。结构照 calculator 模板：
#   AgentWindow::Presenter —— 纯渲染内核（CRuby 可测、零 UI/网络依赖）：把
#     LinkService 的 agents/mailboxes 原始数据整理成视图模型（状态徽标、
#     mailbox 计数、thread 分组、内容截断）
#   AgentWindow            —— App 薄壳（< Emerald::App）：只负责订阅
#     LinkService 的 signal 并渲染；窗口自身零 IO，数据一律经
#     AgentOSDesk::LinkService.instance（nil 时整体渲染占位文案）
#
# entry 由包接线（src/main.rb）在运行时加载，本文件自身不 require；
# 纯 CRuby 可测，无任何 Opal/JS 代码。
module AgentOSDesk
  class AgentWindow < Emerald::App
    # 纯渲染内核：输入是 LinkService 两个 signal 的原始片段
    #（agent 摘要 Hash + mailbox 两段消息数组），输出视图模型。
    # 所有渲染防御（缺失字段、未知 status/kind/priority、非 Hash
    # 元素）集中在此，App 壳只搬字。
    class Presenter
      # last_status 徽标配色（契约：Symbol 或 nil）：
      # completed 绿 / cancelled 灰 / failed 红 / step_limit 橙 /
      # restart_requested 紫；nil（待命）与未知值一律蓝灰兜底。
      STATUS_BADGES = {
        completed: { text: 'completed', color: '#10b981' },
        cancelled: { text: 'cancelled', color: '#9ca3af' },
        failed: { text: 'failed', color: '#ef4444' },
        step_limit: { text: 'step_limit', color: '#f59e0b' },
        restart_requested: { text: 'restart_requested', color: '#a855f7' }
      }.freeze
      IDLE_BADGE = { text: '待命', color: '#64748b' }.freeze
      FALLBACK_BADGE_COLOR = '#64748b'

      # kind/priority 徽标配色（契约：string 键；未知值兜底灰）
      KIND_COLORS = {
        'task' => '#60a5fa', 'question' => '#f59e0b', 'answer' => '#34d399',
        'result' => '#10b981', 'alert' => '#ef4444', 'progress' => '#94a3b8',
        'stop' => '#f87171'
      }.freeze
      FALLBACK_KIND_COLOR = '#94a3b8'
      PRIORITY_COLORS = {
        'urgent' => '#f97316', 'control' => '#a855f7', 'normal' => '#64748b'
      }.freeze
      FALLBACK_PRIORITY_COLOR = '#64748b'

      CONTENT_LIMIT = 120 # 消息内容截断长度（展开前）
      TIME_CHARS = 19     # ISO8601 截到秒：2026-09-15T08:30:00
      THREAD_FALLBACK_LABEL = '（未分组）'

      attr_reader :pending_count, :processing_count

      def initialize(agent, mailbox, fallback_name: nil)
        @agent = agent.is_a?(Hash) ? agent : {}
        @pending = bucket(mailbox, :pending)
        @processing = bucket(mailbox, :processing)
        @fallback_name = fallback_name
        @pending_count = @pending.size
        @processing_count = @processing.size
      end

      # agents 列表缺该 endpoint 时回落到启动参数名
      def name
        field(@agent, :name) || @fallback_name.to_s
      end

      # 非空段拼接（如 "scripted · gpt-5"），全缺时视图显示兜底文案
      def driver_model
        [field(@agent, :driver), field(@agent, :model)]
          .map { |v| v.to_s.strip }.reject(&:empty?)
      end

      # => { text:, color: }；无 agent 数据（视作待命）也给徽标，头部不塌
      def status_badge
        status = field(@agent, :last_status)
        return IDLE_BADGE if status.nil? || status.to_s.empty?

        STATUS_BADGES.fetch(status.to_sym) do
          { text: status.to_s, color: FALLBACK_BADGE_COLOR }
        end
      end

      # processing 段：视图置顶高亮渲染，组内按时间升序
      def processing_messages
        sort_by_time(@processing)
      end

      # 会话流主体：pending 消息按 thread_id 分组的可折叠卡片列表，
      # 组间按最新活动倒序、组内按时间升序
      # => [{ id:, label:, latest:, messages: [...] }]
      def threads
        @pending
          .group_by { |msg| thread_label(msg) }
          .map do |label, msgs|
            { id: label, label: label, latest: latest_time(msgs),
              messages: sort_by_time(msgs) }
          end
          .sort_by { |t| t[:latest] }.reverse
      end

      def kind_badge(msg)
        kind = field(msg, :kind).to_s
        { text: kind.empty? ? '?' : kind,
          color: KIND_COLORS.fetch(kind, FALLBACK_KIND_COLOR) }
      end

      def priority_badge(msg)
        priority = field(msg, :priority).to_s
        { text: priority.empty? ? 'normal' : priority,
          color: PRIORITY_COLORS.fetch(priority, FALLBACK_PRIORITY_COLOR) }
      end

      def route_text(msg)
        "#{field(msg, :from)} → #{field(msg, :to)}"
      end

      def message_key(msg)
        field(msg, :message_id).to_s
      end

      def time_text(msg)
        field(msg, :created_at).to_s[0, TIME_CHARS]
      end

      # 内容截断可展开 => [展示文本, 截断中?, 展开中?]
      def content_view(msg, expanded)
        text = field(msg, :content).to_s
        return [text, false, false] if text.length <= CONTENT_LIMIT
        return [text, false, true] if expanded

        ["#{text[0, CONTENT_LIMIT]}…", true, false]
      end

      private

      # 键约定：agent/mailbox 外层为 symbol 键、消息为 string 键；
      # 渲染防御——两种读取都容忍
      def field(hash, key)
        hash[key] || hash[key.to_s]
      end

      def bucket(mailbox, key)
        Array(field(mailbox || {}, key))
      end

      def thread_label(msg)
        label = field(msg, :thread_id).to_s
        label.empty? ? THREAD_FALLBACK_LABEL : label
      end

      def sort_by_time(msgs)
        msgs.sort_by { |m| field(m, :created_at).to_s }
      end

      def latest_time(msgs)
        msgs.map { |m| field(m, :created_at).to_s }.max.to_s
      end
    end

    # ── App 薄壳 ────────────────────────────────────────

    app_id :agentos_agent
    app_title 'Agent'
    app_icon '🤖'
    singleton false
    default_geometry { { x: 80, y: 60, w: 540, h: 580 } }

    state :draft, default: ''          # 输入框内容（受控 text_input）
    state :priority, default: :normal  # 发送优先级：:normal / :urgent
    state :level, default: :result     # 披露层级：:result / :process / :trace
    state(:collapsed_threads) { [] }   # 折叠中的 thread_id 列表（块初始化防共享）
    state(:expanded_msgs) { [] }       # 展开长内容的消息 id 列表

    LEVELS = { result: '结果', process: '过程', trace: '完整轨迹' }.freeze
    PRIORITIES = { normal: '常规', urgent: '加急' }.freeze

    NO_LINK_TEXT = 'AgentOS 连接未启动'
    NO_ENDPOINT_TEXT = '未指定目标 Agent：请经启动参数 endpoint 打开' \
                       '（launch(:agentos_agent, endpoint: "agent-1")）'
    TRACE_PLACEHOLDER = '执行轨迹（阶段二经 WS 推送）'

    PAGE = { width: '100%', height: '100%', background: '#1e1e2e',
             color: '#e2e8f0', padding: '12px', gap: 10 }.freeze
    PLACEHOLDER = { padding: 14, color: '#94a3b8', font_size: 13 }.freeze
    HEADER = { align_items: 'center', gap: 8, padding_bottom: 8,
               border_bottom: '1px solid #313244' }.freeze
    HEADER_META = { align_items: 'center', gap: 6, font_size: 12,
                    color: '#64748b' }.freeze
    CONVERSATION = { flex: 1, min_height: 0, overflow_y: 'auto', gap: 10 }.freeze
    SECTION_TITLE = { font_size: 12, color: '#94a3b8', font_weight: 'bold' }.freeze
    EMPTY_TEXT = { font_size: 12, color: '#64748b', padding: 6 }.freeze
    CARD = { gap: 4, border_radius: 6, padding: 8 }.freeze
    CARD_ROW = { align_items: 'center', gap: 6 }.freeze
    ROUTE = { font_size: 11, color: '#94a3b8' }.freeze
    CONTENT = { font_size: 12, line_height: 1.5, white_space: 'pre-wrap',
                word_break: 'break-all', color: '#cbd5e1' }.freeze
    TIME = { font_size: 11, color: '#64748b', margin_left: 'auto',
             white_space: 'nowrap' }.freeze
    LINK_BTN = { border: 'none', background: 'transparent', color: '#60a5fa',
                 font_size: 11, cursor: 'pointer', padding: 0,
                 align_self: 'flex-start' }.freeze
    THREAD = { gap: 4, border_radius: 8, background: '#262636',
               border: '1px solid #313244' }.freeze
    THREAD_HEAD = { display: 'flex', align_items: 'center', gap: 6,
                    width: '100%', background: 'transparent', border: 'none',
                    cursor: 'pointer', padding: '7px 9px',
                    text_align: 'left', color: '#e2e8f0' }.freeze
    PROCESSING_BOX = { gap: 6, border_radius: 8, padding: 8,
                       background: '#2a2140', border: '1px solid #a855f7' }.freeze
    LEVELS_ROW = { align_items: 'center', gap: 6 }.freeze
    TRACE_BOX = { gap: 4, border_radius: 8, padding: 8,
                  background: '#242438', border: '1px dashed #334155' }.freeze
    INPUT_ROW = { align_items: 'center', gap: 8, padding_top: 8,
                  border_top: '1px solid #313244' }.freeze
    INPUT = { flex: 1, background: '#262636', color: '#e2e8f0',
              border: '1px solid #334155', border_radius: 6,
              padding: '7px 9px', font_size: 13, outline: 'none' }.freeze
    SEND_BTN = { padding: '7px 14px', font_size: 13, border: 'none',
                 border_radius: 6, background: '#10b981', color: '#ffffff',
                 cursor: 'pointer' }.freeze

    def view
      stack(css_class: 'aos-agent', style: PAGE) do
        link = current_link
        if link.nil?
          label(style: PLACEHOLDER) { NO_LINK_TEXT }
        elsif endpoint.empty?
          endpoint_prompt(link)
        else
          render_body(link)
        end
        nil
      end
    end

    # 发送：空输入忽略；交给 LinkService 构造信封（人永远不和协议打交道）
    def send_current
      content = draft.to_s.strip
      return if content.empty?

      link = current_link
      return unless link

      link.send_message(to: endpoint, content: content, kind: :ask, priority: priority)
      self.draft = ''
    end

    def toggle_thread(id)
      self.collapsed_threads = if collapsed_threads.include?(id)
                                 collapsed_threads - [id]
                               else
                                 collapsed_threads + [id]
                               end
    end

    def toggle_message(id)
      self.expanded_msgs = if expanded_msgs.include?(id)
                             expanded_msgs - [id]
                           else
                             expanded_msgs + [id]
                           end
    end

    private

    # LinkService 未加载（包接线外的裸渲染/单测）与 instance 为 nil 同等待遇
    def current_link
      defined?(AgentOSDesk::LinkService) ? AgentOSDesk::LinkService.instance : nil
    end

    def endpoint
      return '' unless argv

      (argv[:endpoint] || argv['endpoint']).to_s
    end

    def read_signal(service, name)
      value = service.public_send(name)
      value.respond_to?(:get) ? value.get : value
    end

    # 无 endpoint：提示选择，并列出当前在线 Agent 帮忙挑（只读渲染，
    # 开窗动作归 AppRegistry，视图内不得 launch——F6 守卫）
    def endpoint_prompt(link)
      stack(css_class: 'aos-no-endpoint', gap: 6) do
        label(style: PLACEHOLDER) { NO_ENDPOINT_TEXT }
        names = Array(read_signal(link, :agents)).filter_map do |a|
          a.is_a?(Hash) ? (a[:name] || a['name']).to_s : nil
        end
        label(style: EMPTY_TEXT) do
          names.any? ? "在线 Agent：#{names.join('、')}" : '当前无在线 Agent'
        end
        nil
      end
    end

    def render_body(link)
      presenter = Presenter.new(find_agent(link), find_mailbox(link),
                                fallback_name: endpoint)
      header(presenter, read_signal(link, :offline), read_signal(link, :last_error))
      conversation(presenter)
      level_switch
      trajectory_area
      input_bar
    end

    def find_agent(link)
      Array(read_signal(link, :agents)).find do |a|
        a.is_a?(Hash) && (a[:name] || a['name']).to_s == endpoint
      end
    end

    def find_mailbox(link)
      boxes = read_signal(link, :mailboxes)
      boxes.is_a?(Hash) ? boxes[endpoint] : nil
    end

    # ① 头部：agent 名 + last_status 徽标 +（离线提示）+ mailbox 计数 + driver/model
    def header(presenter, offline, last_error)
      row(css_class: 'aos-header', style: HEADER) do
        label(style: { font_size: 16, font_weight: 'bold', color: '#f8fafc',
                       white_space: 'nowrap' }) { "🤖 #{presenter.name}" }
        badge(**presenter.status_badge)
        badge(text: '观测端离线', color: '#ef4444') if offline
        box(style: { flex: 1 }) { nil }
        label(style: { font_size: 12, color: '#94a3b8', white_space: 'nowrap' }) do
          "待处理 #{presenter.pending_count} · 处理中 #{presenter.processing_count}"
        end
        nil
      end
      row(css_class: 'aos-header-meta', style: HEADER_META) do
        label do
          presenter.driver_model.any? ? presenter.driver_model.join(' · ') : 'driver/model 未知'
        end
        label(style: { color: '#ef4444' }) { "（#{last_error.to_s[0, 60]}）" } \
          if offline && !last_error.to_s.empty?
        nil
      end
    end

    # ② 会话流：processing 置顶高亮 + pending 按 thread 分组的折叠卡片列表
    def conversation(presenter)
      stack(css_class: 'aos-flow', style: CONVERSATION) do
        processing = presenter.processing_messages
        processing_block(processing, presenter) if processing.any?
        threads = presenter.threads
        if threads.empty?
          label(style: EMPTY_TEXT) { processing.any? ? '队列中暂无其他消息' : '暂无消息' }
        else
          threads.each { |thread| thread_card(thread, presenter) }
        end
        nil
      end
    end

    def processing_block(messages, presenter)
      stack(css_class: 'aos-processing', style: PROCESSING_BOX) do
        label(style: { font_size: 12, color: '#c084fc', font_weight: 'bold' }) do
          "🔄 处理中（#{messages.size}）"
        end
        messages.each { |msg| message_card(presenter, msg, highlight: true) }
        nil
      end
    end

    def thread_card(thread, presenter)
      stack(css_class: 'aos-thread', style: THREAD) do
        collapsed = collapsed_threads.include?(thread[:id])
        button(on_click: -> { toggle_thread(thread[:id]) }, style: THREAD_HEAD) do
          label(style: { white_space: 'pre', color: '#c084fc' }) { collapsed ? '▸' : '▾' }
          label(style: { font_size: 12, color: '#e2e8f0' }) { thread[:label] }
          box(style: { flex: 1 }) { nil }
          label(style: ROUTE) { "#{thread[:messages].size} 条" }
          label(style: TIME.merge(margin_left: 0)) { thread[:latest][0, Presenter::TIME_CHARS] }
          nil
        end
        thread[:messages].each { |msg| message_card(presenter, msg) } unless collapsed
        nil
      end
    end

    def message_card(presenter, msg, highlight: false)
      stack(css_class: 'aos-msg', style: card_style(highlight)) do
        row(style: CARD_ROW) do
          badge(**presenter.kind_badge(msg))
          badge(**presenter.priority_badge(msg))
          label(style: TIME) { presenter.time_text(msg) }
          nil
        end
        label(style: ROUTE) { presenter.route_text(msg) }
        text, truncated, expanded =
          presenter.content_view(msg, expanded_msgs.include?(presenter.message_key(msg)))
        label(style: CONTENT) { text }
        if truncated
          button(on_click: -> { toggle_message(presenter.message_key(msg)) },
                 style: LINK_BTN) { '展开' }
        elsif expanded
          button(on_click: -> { toggle_message(presenter.message_key(msg)) },
                 style: LINK_BTN) { '收起' }
        end
        nil
      end
    end

    def badge(text:, color:)
      label(style: { display: 'inline-block', padding: '1px 7px', border_radius: 8,
                     font_size: 11, line_height: 1.6, color: '#ffffff',
                     background: color, white_space: 'nowrap' }) { text }
    end

    def card_style(highlight)
      CARD.merge(
        background: highlight ? '#31273f' : '#242438',
        border: highlight ? '1px solid #a855f7' : '1px solid #334155'
      )
    end

    def choice_btn_style(active)
      { padding: '3px 10px', font_size: 12, border: '1px solid #334155',
        border_radius: 6, cursor: 'pointer',
        background: active ? '#334155' : 'transparent',
        color: active ? '#f8fafc' : '#94a3b8' }
    end

    # ③ 披露层级切换（三档 state）+ 轨迹占位区（结果档收起）
    def level_switch
      row(css_class: 'aos-levels', style: LEVELS_ROW) do
        label(style: SECTION_TITLE) { '披露层级' }
        LEVELS.each do |key, text|
          button(on_click: -> { self.level = key },
                 style: choice_btn_style(level == key)) { text }
        end
        nil
      end
    end

    def trajectory_area
      return if level == :result

      stack(css_class: 'aos-trace', style: TRACE_BOX) do
        label(style: SECTION_TITLE) { level == :trace ? '完整轨迹' : '执行轨迹' }
        label(style: { font_size: 12, color: '#64748b' }) { TRACE_PLACEHOLDER }
        nil
      end
    end

    # ④ 底部互动条：受控输入框 + 优先级切换 + 发送
    def input_bar
      row(css_class: 'aos-input', style: INPUT_ROW) do
        text_input(value: signal(:draft), autofocus: true,
                   placeholder: "发消息给 #{endpoint}，Enter 发送",
                   on_enter: -> { send_current }, style: INPUT)
        priority_switch
        button(on_click: -> { send_current }, style: SEND_BTN) { '发送' }
        nil
      end
    end

    def priority_switch
      row(css_class: 'aos-priority',
          style: { gap: 0, border: '1px solid #334155', border_radius: 6,
                   overflow: 'hidden' }) do
        PRIORITIES.each do |key, text|
          button(on_click: -> { self.priority = key },
                 style: choice_btn_style(priority == key)
                   .merge(border: 'none', border_radius: 0)) { text }
        end
        nil
      end
    end
  end
end

# frozen_string_literal: true

module AgentOSDesk
  # 收件箱窗口（设计文档 §3.3）：AgentOS Human Endpoint 的窗口化——
  # 人话卡片流 + 待回答质询橙色高亮 + 内联回答框。
  # 结构照 Calculator 模板：Cards 纯逻辑内核（不透明 Hash → 投影结构，
  # CRuby 可测、不触 UI）+ App 薄壳（只渲染与派发事件）。
  # 数据一律经 LinkService.instance 的只读 signal（见 src/link.rb 契约），
  # 本文件零 IO、零 Opal/JS。被包 entry（src/main.rb）require，自身不 require；
  # LinkService 未加载/未启动时渲染占位文案，裸 Citrine.render（无 boot）也不崩。
  class InboxWindow < Emerald::App
    app_id :agentos_inbox
    app_title '收件箱'
    app_icon '📥'
    singleton true
    default_geometry { { x: 200, y: 120, w: 500, h: 540 } }

    # ── 纯逻辑内核：不透明 Hash → 投影结构，全字段防御 ──────────

    # 投影结构：字段已归一为 String（缺失即 ''），view 直接渲染、
    # 不再触碰原始 Hash；显示不了的字段由 view 跳过。
    Card = Struct.new(:icon, :title, :body, :from, :time)
    Question = Struct.new(:id, :from, :body, :time)

    class Cards
      TIME_KEYS = %w[at created_at time timestamp].freeze
      BODY_KEYS = %w[body content text message].freeze
      TITLE_KEYS = %w[title subject].freeze
      QUESTION_BODY_KEYS = %w[content body text title].freeze
      # kind → 图标兜底（对齐 AgentOS Human::CARD_ICONS；'icon' 字段优先）
      KIND_ICONS = {
        'question' => '❓', 'result' => '📊',
        'alert' => '🔔', 'progress' => '⏳'
      }.freeze
      DEFAULT_ICON = '✉️'

      class << self
        # 单卡投影：cards 元素是不透明 Hash（Observer 侧已 string 键化），
        # 逐字段挑最可能承载文本的键；非 Hash 元素或字段缺失一律回落。
        def project(card)
          return Card.new(DEFAULT_ICON, '', '', '', '') unless card.is_a?(Hash)

          kind = card['kind'].to_s
          icon = pick(card, ['icon'])
          icon = KIND_ICONS.fetch(kind, DEFAULT_ICON) if icon.empty?
          Card.new(icon, pick(card, TITLE_KEYS), pick(card, BODY_KEYS),
                   pick(card, ['from']), time_key(card))
        end

        # 质询投影：LinkCore 保证 'id'/'from' 存在，其余键仍防御提取；
        # 缺 'id' 的元素是脏数据，返回 nil 由 view 跳过。
        def project_question(q)
          return nil unless q.is_a?(Hash)

          id = q['id']
          return nil if id.nil? || id.to_s.empty?

          Question.new(id.to_s, pick(q, ['from']), pick(q, QUESTION_BODY_KEYS), time_key(q))
        end

        # 按时间倒序：主键是时间字符串（ISO 8601 字典序即时间序），
        # 缺失归一为 '' 恒排最后；平手以原下标决胜（Ruby sort 不稳定）。
        def sort_desc(cards)
          Array(cards).each_with_index.sort do |(a, ai), (b, bi)|
            cmp = time_key(b) <=> time_key(a)
            cmp.zero? ? ai <=> bi : cmp
          end.map(&:first)
        end

        # 时间排序键：候选键取第一个非空值；非 String 值 to_s 后比较
        def time_key(card)
          return '' unless card.is_a?(Hash)

          pick(card, TIME_KEYS)
        end

        private

        # 候选键依次取第一个非空值（nil 或纯空白都算缺失），全部缺失给 ''
        def pick(hash, keys)
          keys.each do |k|
            v = hash[k]
            next if v.nil?

            s = v.to_s
            return s unless s.strip.empty?
          end
          ''
        end
      end
    end

    # ── 样式（内联 snake_case，渲染边界各自归一）────────────────

    ROOT_STYLE = {
      width: '100%', height: '100%', padding: '12px',
      background: '#ffffff', color: '#1f2937', overflow_y: 'auto',
      font_family: 'ui-sans-serif, system-ui, sans-serif', font_size: 13
    }.freeze
    BADGE_BASE = {
      border_radius: 999, padding: '1px 9px', color: '#ffffff',
      font_size: 12, font_weight: 700, min_width: '18px', text_align: 'center'
    }.freeze
    BADGE_IDLE = BADGE_BASE.merge(background: '#9ca3af').freeze # 0 条：灰
    BADGE_HOT  = BADGE_BASE.merge(background: '#ea580c').freeze # 有质询：橙红
    TITLE_STYLE = { font_size: 16, font_weight: 700 }.freeze
    SECTION_TITLE_STYLE = { font_size: 12, font_weight: 600, color: '#6b7280' }.freeze
    PLACEHOLDER_STYLE = { padding: '24px 12px', color: '#9ca3af', text_align: 'center' }.freeze
    EMPTY_STYLE = { color: '#9ca3af', font_size: 12 }.freeze

    QUESTION_STYLE = {
      background: '#fff7ed', border: '1px solid #fb923c',
      border_radius: 8, padding: '8px 10px', gap: '6px'
    }.freeze
    QUESTION_BODY_STYLE = { white_space: 'pre-wrap', word_break: 'break-word' }.freeze
    QUESTION_META_STYLE = { font_size: 11, color: '#b45309' }.freeze
    ANSWER_INPUT_STYLE = {
      flex: 1, min_width: 0, border: '1px solid #fdba74', border_radius: 6,
      padding: '4px 8px', font_size: 12, outline: 'none', background: '#ffffff'
    }.freeze
    ANSWER_BUTTON_STYLE = {
      border: 'none', border_radius: 6, padding: '5px 12px',
      background: '#ea580c', color: '#ffffff', cursor: 'pointer', font_size: 12
    }.freeze

    CARD_STYLE = {
      background: '#f8fafc', border: '1px solid #e2e8f0',
      border_radius: 8, padding: '8px 10px', gap: '8px', align_items: 'flex-start'
    }.freeze
    CARD_ICON_STYLE = { font_size: 16, line_height: '20px' }.freeze
    CARD_TITLE_STYLE = { font_weight: 600 }.freeze
    CARD_BODY_STYLE = { white_space: 'pre-wrap', word_break: 'break-word' }.freeze
    CARD_META_STYLE = { font_size: 11, color: '#6b7280' }.freeze

    # ── view ────────────────────────────────────────────

    def view
      stack(css_class: 'agentos-inbox', gap: 12, style: ROOT_STYLE) do
        if link
          header
          question_section
          card_stream
        else
          label(css_class: 'agentos-inbox-placeholder', style: PLACEHOLDER_STYLE) { 'AgentOS 连接未启动' }
        end
        nil
      end
    end

    private

    # 数据中枢访问点。契约：窗口一律经 LinkService.instance 读数据；
    # 实例为 nil（Service 未启动）或常量尚未加载（裸渲染 / 单测只 require
    # 本文件）时一律视为未连接，view 渲染占位而不是崩溃。
    def link
      defined?(AgentOSDesk::LinkService) ? AgentOSDesk::LinkService.instance : nil
    end

    # 顶部：未回答质询计数徽标（0 灰 / >0 橙红）+ 标题
    def header
      count = link&.pending_questions&.get&.size || 0
      row(css_class: 'agentos-inbox-header', gap: 8, style: { align_items: 'center' }) do
        label(css_class: 'agentos-inbox-badge', style: count > 0 ? BADGE_HOT : BADGE_IDLE) { count.to_s }
        label(css_class: 'agentos-inbox-title', style: TITLE_STYLE) { '收件箱' }
        nil
      end
    end

    # 待回答质询区：每条渲染橙色高亮卡片（正文/来自/时间，字段缺失防御跳过）
    def question_section
      svc = link
      questions = Array(svc && svc.pending_questions.get).map { |q| Cards.project_question(q) }.compact
      stack(css_class: 'agentos-inbox-questions', gap: 6) do
        label(css_class: 'agentos-inbox-section-title', style: SECTION_TITLE_STYLE) { "待回答质询（#{questions.size}）" }
        if questions.empty?
          label(css_class: 'agentos-inbox-empty', style: EMPTY_STYLE) { '暂无待回答的质询' }
        else
          questions.each { |q| question_card(q) }
        end
        nil
      end
    end

    def question_card(q)
      stack(css_class: 'agentos-inbox-question', key: "q-#{q.id}", gap: 6, style: QUESTION_STYLE) do
        unless q.body.empty?
          label(css_class: 'agentos-inbox-question-body', style: QUESTION_BODY_STYLE) { q.body }
        end
        row(css_class: 'agentos-inbox-question-meta', gap: 10, style: QUESTION_META_STYLE) do
          label { "来自 #{q.from}" } unless q.from.empty?
          label { q.time } unless q.time.empty?
          nil
        end
        answer_row(q.id)
        nil
      end
    end

    # 回答输入行：每个质询一把独立输入（keyed_signal 按 id 懒建），
    # 回车或点提交均可；提交即 answer_question 并清空输入，
    # 质询卡片消失等下一轮轮询刷新 signal 后自然撤下。
    def answer_row(id)
      row(css_class: 'agentos-inbox-answer', gap: 6, style: { align_items: 'center' }) do
        text_input(css_class: 'agentos-inbox-answer-input',
                   value: keyed_signal(:answer, id), placeholder: '输入回答…',
                   on_enter: -> { submit_answer(id) }, style: ANSWER_INPUT_STYLE)
        button(css_class: 'agentos-inbox-answer-submit', on_click: -> { submit_answer(id) },
               style: ANSWER_BUTTON_STYLE) { '提交' }
        nil
      end
    end

    def submit_answer(id)
      svc = link
      return unless svc

      input = keyed_signal(:answer, id)
      text = input.peek.to_s.strip # 事件回调里取快照即可，不建立订阅
      return if text.empty?

      svc.answer_question(id, text)
      input.set('')
    end

    # 卡片流：cards 按时间倒序投影渲染（元素不透明，显示不了的字段跳过）
    def card_stream
      svc = link
      cards = Cards.sort_desc(svc ? svc.cards.get : [])
      stack(css_class: 'agentos-inbox-cards', gap: 6) do
        label(css_class: 'agentos-inbox-section-title', style: SECTION_TITLE_STYLE) { "卡片流（#{cards.size}）" }
        if cards.empty?
          label(css_class: 'agentos-inbox-empty', style: EMPTY_STYLE) { '暂无卡片' }
        else
          cards.each_with_index { |card, i| card_row(card, i) }
        end
        nil
      end
    end

    def card_row(card, index)
      view = Cards.project(card)
      key = card.is_a?(Hash) ? (card['message_id'] || card['id'] || "card-#{index}") : "card-#{index}"
      row(css_class: 'agentos-inbox-card', key: key.to_s, gap: 8, style: CARD_STYLE) do
        label(css_class: 'agentos-inbox-card-icon', style: CARD_ICON_STYLE) { view.icon }
        stack(css_class: 'agentos-inbox-card-main', gap: 2, style: { flex: 1, min_width: 0 }) do
          unless view.title.empty?
            label(css_class: 'agentos-inbox-card-title', style: CARD_TITLE_STYLE) { view.title }
          end
          unless view.body.empty?
            label(css_class: 'agentos-inbox-card-body', style: CARD_BODY_STYLE) { view.body }
          end
          row(css_class: 'agentos-inbox-card-meta', gap: 10, style: CARD_META_STYLE) do
            label { "来自 #{view.from}" } unless view.from.empty?
            label { view.time } unless view.time.empty?
            nil
          end
          nil
        end
        nil
      end
    end
  end
end

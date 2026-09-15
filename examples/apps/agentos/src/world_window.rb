# frozen_string_literal: true

module AgentOSDesk
  # World 总览窗口（设计文档 §3.4：桌面自检口）：AgentOS 运行时的整体面貌——
  # 观测端在线状态横幅、总览/配置键值区、Registry 名单（每个 Agent/Service
  # 一行，行内「开窗」按钮经 ctx[:launcher] 拉起对应 endpoint 的专属窗口）。
  #
  # 窗口是状态的投影（emerald D10）：全部数据经 LinkService.instance 的只读
  # signal 读取，本类零 IO、无 Opal 依赖（纯 CRuby 可渲染可测）；LinkService
  # 未激活（instance 为 nil，如未启动直接渲染）时输出占位文案，任何情况下
  # 不得崩溃。
  class WorldWindow < Emerald::App
    app_id :agentos_world
    app_title 'AgentOS'
    app_icon '🌐'
    singleton true
    default_geometry { { x: 60, y: 40, w: 560, h: 620 } }

    # 观测端地址展示串（与 LinkCore 默认地址一致；可配置常量在 LinkCore 侧）
    OBSERVER_ADDRESS = '127.0.0.1:4470'

    # 缺失值展示兜底
    MISSING = '—'

    # AgentOS TaskResult 状态词表 → 状态点颜色（agent.rb；未知/nil 兜底灰）
    AGENT_STATUS_COLORS = {
      completed: '#10b981',         # 完成 → 绿
      failed: '#ef4444',            # 失败 → 红
      step_limit: '#f59e0b',        # 达到最大步数中止 → 橙
      restart_requested: '#f59e0b', # 请求重启 → 橙
      cancelled: '#9ca3af'          # 取消 → 灰
    }.freeze
    SERVICE_RUNNING_COLOR = '#10b981' # Service running 状态点（绿）
    DOT_FALLBACK_COLOR = '#9ca3af'    # 未知/缺失状态点（灰）

    ROOT_STYLE = {
      width: '100%', height: '100%', padding: '12px', overflow: 'auto',
      font_size: '13px', color: '#1f2937'
    }.freeze
    PLACEHOLDER_STYLE = { padding: '16px', color: '#6b7280' }.freeze
    OFFLINE_BANNER_STYLE = {
      padding: '8px 12px', border_radius: '8px', font_weight: '600',
      background: '#fef2f2', color: '#b91c1c', border: '1px solid #fecaca'
    }.freeze
    SECTION_TITLE_STYLE = {
      font_weight: '600', font_size: '12px', color: '#6b7280', margin_top: '6px'
    }.freeze
    KV_ROW_STYLE = { align_items: 'center', gap: '8px' }.freeze
    KV_KEY_STYLE = { width: '88px', flex_shrink: '0', color: '#6b7280' }.freeze
    KV_VALUE_STYLE = {
      flex: 1, font_family: 'ui-monospace, Menlo, monospace', word_break: 'break-all'
    }.freeze
    BADGE_BASE = {
      padding: '1px 8px', border_radius: '10px', font_size: '11px', font_weight: '600'
    }.freeze
    BADGE_OK_STYLE = BADGE_BASE.merge(background: '#dcfce7', color: '#15803d').freeze
    BADGE_ERR_STYLE = BADGE_BASE.merge(background: '#fee2e2', color: '#b91c1c').freeze
    ENDPOINT_ROW_STYLE = {
      align_items: 'center', gap: '8px', padding: '6px 8px',
      border_radius: '8px', background: '#f9fafb', border: '1px solid #e5e7eb'
    }.freeze
    DOT_STYLE = { width: '8px', height: '8px', border_radius: '50%', flex_shrink: '0' }.freeze
    ENDPOINT_NAME_STYLE = {
      flex: 1, overflow: 'hidden', text_overflow: 'ellipsis',
      white_space: 'nowrap', font_weight: '500'
    }.freeze
    MAILBOX_STYLE = { color: '#6b7280', font_size: '12px', white_space: 'nowrap' }.freeze
    LAUNCH_BUTTON_STYLE = {
      padding: '3px 10px', font_size: '12px', cursor: 'pointer', flex_shrink: '0',
      border: '1px solid #d1d5db', border_radius: '6px', background: '#ffffff'
    }.freeze
    UNWIRED_STYLE = { color: '#9ca3af', font_size: '12px', flex_shrink: '0' }.freeze
    EMPTY_STYLE = { color: '#9ca3af', font_size: '12px' }.freeze

    def view
      stack(css_class: 'aos-world', gap: 10, style: ROOT_STYLE) do
        if link_service
          offline_banner if offline?
          overview_section
          registry_section
        else
          label(css_class: 'aos-world-placeholder', style: PLACEHOLDER_STYLE) { 'AgentOS 连接未启动' }
        end
      end
    end

    private

    # LinkService 单例；未激活（未启动/已停用）时为 nil
    def link_service
      AgentOSDesk::LinkService.instance
    end

    # 读 LinkService 暴露的只读 signal（view 内 .get 建立订阅）；实现侧若直接
    # 返回值或尚未就绪（nil）也兼容
    def read(source)
      source.respond_to?(:get) ? source.get : source
    end

    def offline?
      read(link_service.offline) ? true : false
    end

    # ── ① 离线横幅（顶部醒目提示，数据保留最后值照常展示）──────────

    def offline_banner
      box(css_class: 'aos-world-offline', style: OFFLINE_BANNER_STYLE) do
        label { "⚠ 观测端离线（#{OBSERVER_ADDRESS}）" }
      end
    end

    # ── ② 总览/配置键值区 ──────────────────────────────────────

    def overview_section
      overview = read(link_service.overview) || {}
      config = read(link_service.config) || {}
      stack(css_class: 'aos-world-overview', gap: 4) do
        section_title('总览')
        kv_row('版本', display(overview[:version]))
        kv_row('数据目录', display(overview[:data_dir]))
        kv_row('Git 提交', short_text(overview[:git_commit]))
        kv_row('检查点', display(overview[:checkpoint]))
        kv_row('历史事件', display(overview[:history_events]))
        kv_row('Mailbox 恢复', bool_text(overview[:mailbox_recovered]))
        section_title('配置')
        kv_row('驱动', display(config[:driver]))
        kv_row('模型', display(config[:model]))
        api_key_row(config)
      end
    end

    # api_key_set 徽标：已设置 → 绿，未设置 → 红
    def api_key_row(config)
      set = config[:api_key_set] == true
      row(key: 'kv:api_key', css_class: 'aos-world-kv', style: KV_ROW_STYLE) do
        label(style: KV_KEY_STYLE) { 'API Key' }
        box(css_class: set ? 'aos-badge is-set' : 'aos-badge is-unset',
            style: set ? BADGE_OK_STYLE : BADGE_ERR_STYLE) { set ? '已设置' : '未设置' }
      end
    end

    # ── ③ Registry 名单区（主体）────────────────────────────────

    def registry_section
      agents = read(link_service.agents) || []
      services = read(link_service.services) || []
      stack(css_class: 'aos-world-registry', gap: 4, style: { flex: 1, min_height: '0px' }) do
        section_title("Agents（#{agents.size}）")
        if agents.empty?
          label(style: EMPTY_STYLE) { '（无 Agent）' }
        else
          agents.each { |agent| agent_row(agent) }
        end
        section_title("Services（#{services.size}）")
        if services.empty?
          label(style: EMPTY_STYLE) { '（无 Service）' }
        else
          services.each { |service| service_row(service) }
        end
      end
    end

    def agent_row(agent)
      return unless agent.is_a?(Hash)

      name = agent[:name].to_s
      name = '（未命名）' if name.empty?
      endpoint_row('agent', :agentos_agent, '🤖', name,
                   agent_status_color(agent[:last_status]), mailbox_text(agent))
    end

    def service_row(service)
      return unless service.is_a?(Hash)

      name = service[:name].to_s
      name = '（未命名）' if name.empty?
      dot_color = service[:running] ? SERVICE_RUNNING_COLOR : DOT_FALLBACK_COLOR
      endpoint_row('service', :agentos_service, '⚙️', name, dot_color, mailbox_text(service))
    end

    # 名单行：图标 + 名 + 状态点 + mailbox 计数 + 开窗按钮
    def endpoint_row(kind, app_id, icon, name, dot_color, mailbox)
      row(key: "#{kind}:#{name}", css_class: 'aos-world-endpoint', style: ENDPOINT_ROW_STYLE) do
        label { icon }
        label(style: ENDPOINT_NAME_STYLE) { name }
        status_dot(dot_color)
        label(style: MAILBOX_STYLE) { mailbox }
        launch_button(app_id, name)
      end
    end

    def status_dot(color)
      box(css_class: 'aos-status-dot', style: DOT_STYLE.merge(background: color))
    end

    # 「开窗」按钮：launch 只能在事件回调里调用（beryl F6——渲染期调用会同步
    # 重入渲染），渲染期只探 launcher 可用性；不可用则降级为「（未接线）」
    def launch_button(app_id, endpoint)
      launcher = current_launcher
      if launcher
        button(on_click: -> { launcher.launch(app_id, endpoint: endpoint) },
               css_class: 'aos-world-launch', style: LAUNCH_BUTTON_STYLE) { '开窗' }
      else
        # TODO(集成阶段)：ctx[:launcher] 未注入（独立宿主/无 boot 渲染）时降级为
        # 纯文本占位；桌面壳注入 AppRegistry 后本按钮拉起对应 endpoint 专属窗口。
        label(css_class: 'aos-world-unwired', style: UNWIRED_STYLE) { '（未接线）' }
      end
    end

    # ctx[:launcher] 即 AppRegistry（shell 注入的服务表；ctx['launcher'] 兜底）
    def current_launcher
      ctx && (ctx[:launcher] || ctx['launcher'])
    end

    # ── 展示格式化（纯函数）───────────────────────────────────

    def agent_status_color(status)
      key = status.respond_to?(:to_sym) ? status.to_sym : nil
      AGENT_STATUS_COLORS.fetch(key, DOT_FALLBACK_COLOR)
    end

    def section_title(text)
      label(css_class: 'aos-world-section-title', style: SECTION_TITLE_STYLE) { text }
    end

    def kv_row(key, value)
      row(key: "kv:#{key}", css_class: 'aos-world-kv', style: KV_ROW_STYLE) do
        label(style: KV_KEY_STYLE) { key }
        label(style: KV_VALUE_STYLE) { value }
      end
    end

    def mailbox_text(item)
      "待办 #{to_count(item[:mailbox_pending])} · 处理中 #{to_count(item[:mailbox_processing])}"
    end

    # 缺失/空值 → '—'，其余 to_s
    def display(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?) ? MISSING : value.to_s
    end

    # 长值截断（git commit 等），保留可辨识前缀
    def short_text(value, max = 12)
      text = display(value)
      text.length > max ? "#{text[0, max]}…" : text
    end

    def bool_text(value)
      value.nil? ? MISSING : (value ? '是' : '否')
    end

    def to_count(value)
      value.to_i
    rescue StandardError
      0
    end
  end
end

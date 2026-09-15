# frozen_string_literal: true

# DevTools —— Emerald 内置 App（M5 系统内自省）：在 Emerald 桌面里经窗口系统
# 开窗口，实时调试同桌面的应用。四个分区消费 M1 时序探针：
# 事件流 / flush 轨迹 / 信号写入 / 组件树（桌面无组件边界时降级元素轮廓）。
#
# 与 debugger.rb 浮层相比的两点规避：
#   - 指纹比较（条目 inspect 拼接成串）替代 == 深比较——debugger.rb 的
#     snap == writes 在 Opal 下疑似恒 false，每轮轮询都自赋值、回灌探针；
#   - 面板自身信号（state 写入，及由这些写入触发的 flush）从对应分区过滤——
#     否则稳态下每 400ms 分区内容必变、永不停手（自写回灌的正反馈）。
#
# entry 在运行时已加载（Emerald::App 可用）的前提下求值，自身不 require。
# 桌面根节点由宿主入口在挂窗口前捕获，经 CITRINE_DEVTOOLS_ROOT 常量注入。
class DevToolsApp < Emerald::App
  app_id :devtools
  app_title 'DevTools'
  app_icon '🔧'
  singleton true
  default_geometry { { x: 480, y: 60, w: 580, h: 600 } }

  POLL_INTERVAL = 400
  MAX_EVENTS = 20
  MAX_FLUSHES = 15
  MAX_WRITES = 30
  TABS = [['事件流', :events], ['flush', :flushes], ['信号写入', :writes], ['组件树', :tree]].freeze

  state(:tab) { :tree }
  state(:writes) { [] }
  state(:flushes) { [] }
  state(:events) { [] }
  state(:tree_lines) { [] }
  state(:tree_kind) { :components }

  TAB_STYLE = { padding: '3px 10px', font_size: '12px' }.freeze
  TAB_ACTIVE_STYLE = { padding: '3px 10px', font_size: '12px', background: '#4f8cff',
                       border: '1px solid #4f8cff', color: '#ffffff' }.freeze
  HEAD_STYLE = { font_size: '12px', font_weight: '700', color: '#4f8cff',
                 margin: '4px 0 2px' }.freeze
  ROW_STYLE = { font_family: 'ui-monospace, monospace', font_size: '11px',
                color: '#c9d4e6', white_space: 'pre' }.freeze
  DIM_STYLE = { color: '#7d8aa5', font_size: '11px' }.freeze

  def boot(ctx)
    super
    # 面板自身信号的 id 表：信号写入/flush 两个分区据此剔除自噪声
    @own_sig_ids = %i[tab writes flushes events tree_lines tree_kind]
                   .map { |name| signal(name).object_id }
    @fp = {} # 各分区上次已赋值内容的指纹（fingerprint）
    @poll_timer = Beryl::Timer.after(300) { poll }
  end

  # 生命周期收尾（窗口关闭 = 实例终点）：撤掉自链轮询，
  # 不再对已注销实例写入 state
  def deactivate
    Beryl::Timer.cancel(@poll_timer)
    @poll_timer = nil
  end

  # 拉取四个探针的最新数据；指纹没变就不赋值——赋值本身也是信号写入，
  # 会进探针环形缓冲，无差别赋值就是自写回灌正反馈
  def poll
    take_events
    take_flushes
    take_writes
    take_tree
    @poll_timer = Beryl::Timer.after(POLL_INTERVAL) { poll }
  end

  def view
    stack(gap: 6, style: { height: '100%', padding: '8px', box_sizing: 'border-box',
                           overflow: 'hidden' }) do
      row(gap: 4, style: { align_items: 'center', flex_shrink: 0 }) do
        label(style: { font_size: '13px', font_weight: '700', color: '#4f8cff',
                       margin_right: '4px' }) { '◆ DevTools' }
        TABS.each { |name, key| tab_button(name, key) }
      end
      stack(gap: 2, style: { flex: 1, overflow: 'auto' }) do
        case tab
        when :events then events_section
        when :flushes then flushes_section
        when :writes then writes_section
        else tree_section
        end
      end
    end
  end

  private

  # ── 轮询取数（各自带自噪声过滤 + 指纹短路）────────────────

  def take_events
    # 面板自身的 state 写入不走 handle_event，事件流无自噪声，取原始 tail
    assign(:events, Citrine.debug_event_stream.to_a.last(MAX_EVENTS).reverse)
  end

  def take_flushes
    own = @own_sig_ids
    snap = Citrine.debug_flush_trace.to_a.reject do |f|
      triggers = f[:trigger_signal_ids] || []
      !triggers.empty? && (triggers - own).empty?
    end.last(MAX_FLUSHES).reverse
    assign(:flushes, snap)
  end

  def take_writes
    own = @own_sig_ids
    snap = Citrine.debug_write_log.to_a.reject do |w|
      own.include?(w[:signal_id])
    end.last(MAX_WRITES).reverse
    assign(:writes, snap)
  end

  def take_tree
    root = defined?(CITRINE_DEVTOOLS_ROOT) ? CITRINE_DEVTOOLS_ROOT : nil
    lines = []
    if root
      comp_tree = Citrine.debug_component_tree(root)
      if comp_tree && comp_tree[:children].empty?
        # shell 直接拼子组件 .view（无组件边界）——退化为元素轮廓展示
        build_outline(root, 0, lines)
        self.tree_kind = :elements unless tree_kind == :elements
      else
        build_tree_lines(comp_tree, 0, lines)
        self.tree_kind = :components unless tree_kind == :components
      end
    end
    assign(:tree_lines, lines)
  end

  # 指纹比较：内容没变就不赋值（规避 Opal 下 == 深比较恒 false 的坑）
  def assign(key, snap)
    fp = snap.map { |e| e.inspect }.join("\n")
    return if @fp[key] == fp

    @fp[key] = fp
    case key
    when :events  then self.events = snap
    when :flushes then self.flushes = snap
    when :writes  then self.writes = snap
    when :tree_lines then self.tree_lines = snap
    end
  end

  # ── 视图分区 ──────────────────────────────────────────────

  def tab_button(name, key)
    count = { events: events.size, flushes: flushes.size, writes: writes.size,
              tree: tree_lines.size }[key]
    style = tab == key ? TAB_ACTIVE_STYLE : TAB_STYLE
    button(on_click: -> { self.tab = key }, style: style) { "#{name} #{count}" }
  end

  def section_head(text)
    label(style: HEAD_STYLE) { text }
  end

  def row_line(text)
    label(style: ROW_STYLE) { text }
  end

  def dim_line(text)
    label(style: DIM_STYLE) { text }
  end

  def events_section
    section_head("事件流 · 最近 #{events.size} 条")
    if events.empty?
      dim_line('（暂无）')
    else
      events.each { |e| row_line(fmt_event(e)) }
    end
  end

  def flushes_section
    section_head("flush 轨迹 · 最近 #{flushes.size} 条")
    if flushes.empty?
      dim_line('（暂无）')
    else
      flushes.each { |f| row_line(fmt_flush(f)) }
    end
  end

  def writes_section
    section_head("信号写入 · 最近 #{writes.size} 条")
    if writes.empty?
      dim_line('（暂无）')
    else
      writes.each { |w| row_line(fmt_write(w)) }
    end
  end

  def tree_section
    kind = tree_kind == :elements ? '元素树（无组件边界，降级）' : '组件树'
    section_head("#{kind} · #{tree_lines.size} 行")
    if tree_lines.empty?
      dim_line('（暂无）')
    else
      tree_lines.each { |l| row_line(l) }
    end
  end

  # ── 条目格式化（口径与 debugger.rb 一致）──────────────────

  def short_id(n)
    n.is_a?(Integer) ? (n % 100_000).to_s : n.to_s
  end

  def fmt_val(v)
    return 'nil' if v.nil?

    s = v.to_s
    s.size > 60 ? "#{s[0, 57]}…" : s
  end

  def fmt_src(src)
    src == :external ? 'ext' : "fx#{short_id(src)}"
  end

  def fmt_write(w)
    "sig#{short_id(w[:signal_id])}  #{fmt_val(w[:old])} → #{fmt_val(w[:new])}  src=#{fmt_src(w[:source])}"
  end

  def fmt_flush(f)
    triggers = (f[:trigger_signal_ids] || []).map { |id| short_id(id) }.join(',')
    total = f[:effects].sum { |e| e[:duration_ms] }
    fx = f[:effects].map { |e| "fx#{short_id(e[:effect_id])}×#{e[:runs]} #{e[:duration_ms]}ms" }.join(' ')
    "flush##{f[:flush_id]}  #{total}ms  触发[#{triggers}]  #{fx}"
  end

  def fmt_event(e)
    flushes = (e[:flush_ids] || []).join(',')
    "ev #{e[:event_type]}  #{e[:target_component]}##{short_id(e[:component_id])}" \
      "  h=#{e[:handler_name]}  →flush[#{flushes}]"
  end

  # 组件树条目（有组件边界时）：一个组件一行
  def build_tree_lines(node, depth, out)
    return if node.nil? || out.size >= 80 || depth > 6

    key = node[:reuse_key] ? " key=#{node[:reuse_key]}" : ''
    out << "#{'· ' * depth}#{node[:component]} ##{short_id(node[:node_id])}#{key}"
    (node[:children] || []).each { |c| build_tree_lines(c, depth + 1, out) }
  end

  # 元素轮廓（无组件边界时降级）：VDOM 原始节点树，组件边界若有则标 ▸
  def build_outline(node, depth, out)
    return if node.nil? || out.size >= 80 || depth > 6

    comp = node.rendered_component
    tag = comp ? (comp.class.name || comp.class.to_s) : node.type.to_s
    mark = comp ? '▸' : '·'
    key = node.reuse_key ? " key=#{node.reuse_key}" : ''
    out << "#{'  ' * depth}#{mark} #{tag} ##{short_id(node.object_id)}#{key}"
    node.children.each { |c| build_outline(c, depth + 1, out) }
  end
end

# frozen_string_literal: true
# backtick_javascript: true
# Emerald 桌面 + DevTools 调试浮层（M1 探针的端到端演示）
# 运行：cd citrine && bin/citrine dev ../emerald/examples -I ../beryl/lib -I ../emerald/lib
# 打开 http://127.0.0.1:4402/debugger.html ——左侧 Emerald 桌面照常玩，
# 右侧面板实时消费 write_log / flush_trace / event_stream / component_tree 四个探针。
require 'citrine/browser'
require 'citrine/debug'
require 'emerald'
require_relative 'apps/calculator/src/main'
require_relative 'apps/stickynote/src/main'

Citrine.debug_tracking = true

shell = Emerald::DesktopShell.new
shell.registry.register(Calculator)
shell.registry.register(StickyNote)
Beryl::Renderer.mount_at('app', shell)
# 开机先开一个计算器窗口：调试面板一上来就有组件子树可看（否则桌面空闲态无嵌套组件）
shell.launch_app(:calculator)
# mount_at 复用同一渲染器，但 Beryl::Renderer#root_node 会被后挂载者覆盖——
# 挂调试面板之前先抓桌面的根节点（组件树探针的遍历入口）
DBG_ROOT = Citrine.renderer.root_node

class DebugPanel < Citrine::Component
  state :writes, default: []
  state :flushes, default: []
  state :events, default: []
  state :tree_lines, default: []
  state :tree_kind, default: :components
  state :demo, default: 0

  # 拉取四个探针的最新数据；内容没变就不赋值——避免面板自己的 state 写入
  # 反过来灌爆 write_log（每次 poll 四条记录）。
  # 注意：Opal 下数组/哈希的 == 深比较疑似恒 false，必须用指纹串比较（M5 同口径）；
  # 且显示侧要过滤面板自身信号——否则自写入会实时刷出满屏噪声。
  def poll
    raw_writes = Citrine.debug_write_log.to_a.last(40).reverse
    fp = raw_writes.map(&:inspect).join
    if fp != @writes_fp
      @writes_fp = fp
      self.writes = raw_writes.reject { |w| own_signal_ids.include?(w[:signal_id]) }
    end

    raw_flushes = Citrine.debug_flush_trace.to_a.last(15).reverse
    fp = raw_flushes.map(&:inspect).join
    if fp != @flushes_fp
      @flushes_fp = fp
      # 只过滤"触发集 ⊆ 面板自身"的 flush——真实 flush 里混有自身信号仍保留显示
      self.flushes = raw_flushes.reject do |f|
        triggers = f[:trigger_signal_ids] || []
        triggers.any? && (triggers - own_signal_ids).empty?
      end
    end

    raw_events = Citrine.debug_event_stream.to_a.last(15).reverse
    fp = raw_events.map(&:inspect).join
    if fp != @events_fp
      @events_fp = fp
      self.events = raw_events.reject { |e| e[:target_component].to_s == "DebugPanel" }
    end

    lines = []
    comp_tree = Citrine.debug_component_tree(DBG_ROOT)
    if comp_tree && comp_tree[:children].empty?
      # shell 直接拼子组件 .view（无组件边界）——退化为元素轮廓展示
      build_outline(DBG_ROOT, 0, lines)
      self.tree_kind = :elements unless tree_kind == :elements
    else
      build_tree_lines(comp_tree, 0, lines)
      self.tree_kind = :components unless tree_kind == :components
    end
    tree_fp = lines.join
    if tree_fp != @tree_fp
      @tree_fp = tree_fp
      self.tree_lines = lines
    end
    Beryl::Timer.after(400) { poll }
  end

  def bump_demo
    self.demo += 1
  end

  def view
    stack(gap: 2, style: { height: "100%", overflow: "auto", padding: "10px",
                           box_sizing: "border-box" }) do
      row(gap: 6, style: { align_items: "center", margin_bottom: "4px" }) do
        label(style: { font_size: "13px", font_weight: "700", color: "#4f8cff" }) { "◆ Citrine DevTools" }
        box(style: { flex: 1 }) {}
        button(on_click: :bump_demo, css_class: "dbg-btn") { "信号写入 ＋#{demo}" }
      end
      label(css_class: "dbg-dim") { "M1 探针 · 实时 · 去左边桌面点图标/菜单/窗口试试" }

      label(css_class: "dbg-head") { "事件流 · 最近 #{events.size}" }
      if events.empty?
        label(css_class: "dbg-dim") { "（暂无事件）" }
      else
        events.each { |e| label(css_class: "dbg-row") { fmt_event(e) } }
      end

      label(css_class: "dbg-head") { "flush 轨迹 · 最近 #{flushes.size}" }
      if flushes.empty?
        label(css_class: "dbg-dim") { "（暂无 flush）" }
      else
        flushes.each { |f| label(css_class: "dbg-row") { fmt_flush(f) } }
      end

      label(css_class: "dbg-head") { "信号写入 · 最近 #{writes.size}" }
      if writes.empty?
        label(css_class: "dbg-dim") { "（暂无写入）" }
      else
        writes.each { |w| label(css_class: "dbg-row") { fmt_write(w) } }
      end

      kind = tree_kind == :elements ? "元素树（无组件边界，降级）" : "组件树"
      label(css_class: "dbg-head") { "#{kind} · #{tree_lines.size} 行（截断）" }
      tree_lines.each { |l| label(css_class: "dbg-row") { l } }
    end
  end

  private

  def short_id(n)
    n.is_a?(Integer) ? (n % 100_000).to_s : n.to_s
  end

  def fmt_val(v)
    return "nil" if v.nil?

    s = v.to_s
    s.size > 60 ? "#{s[0, 57]}…" : s
  end

  def fmt_src(src)
    src == :external ? "ext" : "fx#{short_id(src)}"
  end

  def fmt_write(w)
    "sig#{short_id(w[:signal_id])}  #{fmt_val(w[:old])} → #{fmt_val(w[:new])}  src=#{fmt_src(w[:source])}"
  end

  def fmt_flush(f)
    triggers = (f[:trigger_signal_ids] || []).map { |id| short_id(id) }.join(",")
    total = f[:effects].sum { |e| e[:duration_ms] }.round(2)
    fx = f[:effects].map { |e| "fx#{short_id(e[:effect_id])}×#{e[:runs]} #{e[:duration_ms].round(2)}ms" }.join(" ")
    "flush##{f[:flush_id]}  #{total}ms  触发[#{triggers}]  #{fx}"
  end

  def fmt_event(e)
    flushes = (e[:flush_ids] || []).join(",")
    "ev #{e[:event_type]}  #{e[:target_component]}##{short_id(e[:component_id])}" \
      "  h=#{e[:handler_name]}  →flush[#{flushes}]"
  end

  def own_signal_ids
    @own_signal_ids ||= %i[writes flushes events tree_lines tree_kind demo].map { |name| signal(name).object_id }
  end

  # 树形缩进：制表符连线（非空白字符，不依赖 white-space:pre 也不会被折叠）
  def tree_indent(depth)
    return "" if depth.zero?

    "│   " * (depth - 1) + "├── "
  end

  # 组件树条目（有组件边界时）：一个组件一行
  def build_tree_lines(node, depth, out)
    return if node.nil? || out.size >= 80 || depth > 6

    key = node[:reuse_key] ? " key=#{node[:reuse_key]}" : ""
    out << "#{tree_indent(depth)}#{node[:component]} ##{short_id(node[:node_id])}#{key}"
    (node[:children] || []).each { |c| build_tree_lines(c, depth + 1, out) }
  end

  # 元素轮廓（无组件边界时降级）：VDOM 原始节点树，组件边界若有则标 ▸
  def build_outline(node, depth, out)
    return if node.nil? || out.size >= 80 || depth > 6

    comp = node.rendered_component
    tag = comp ? (comp.class.name || comp.class.to_s) : node.type.to_s
    mark = comp ? "▸" : "·"
    key = node.reuse_key ? " key=#{node.reuse_key}" : ""
    out << "#{tree_indent(depth)}#{mark} #{tag} ##{short_id(node.object_id)}#{key}"
    node.children.each { |c| build_outline(c, depth + 1, out) }
  end
end

panel = DebugPanel.new
Beryl::Renderer.mount_at('devtools', panel)
# 轮询由外部一次性点火，之后 poll 自链（Beryl::Timer 是 setTimeout 一次性语义）
Beryl::Timer.after(300) { panel.poll }

# e2e 验收钩子（M2-4）：?demo=1 时自动对桌面图标派发一次合成点击——
# 走完 event → batch → flush → signal_write 全链路（headless 浏览器无法真人点击）
if defined?(Opal) && `location.search.indexOf("demo=1") >= 0`
  Beryl::Timer.after(1500) do
    %x{
      var el = document.querySelector('.d-icon');
      if (el) el.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    }
  end
end

`window.EmeraldShell = shell` if defined?(Opal)

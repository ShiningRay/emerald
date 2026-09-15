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
      rebuild_dom_index
    end
    Beryl::Timer.after(400) { poll }
  end

  def bump_demo
    self.demo += 1
  end

  # ── 悬浮高亮（数据属性驱动，JS 事件委托在文件底部绑定一次）────────
  # kind: node/component → 直接索引到 DOM 元素；
  #       signal/flush   → 找到订阅者 effect 挂在哪些节点上，高亮那些节点。
  def show_highlight(kind, ids)
    targets = highlight_targets(kind, ids)
    hide_highlight
    targets.each { |dom| draw_highlight_box(dom, kind, ids) }
  end

  def hide_highlight
    %x{ document.querySelectorAll('.dbg-hl').forEach(function (n) { n.remove(); }); }
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
        events.each do |e|
          label(css_class: "dbg-row", data_hl_kind: "component",
                data_hl_ids: e[:component_id].to_s) { fmt_event(e) }
        end
      end

      label(css_class: "dbg-head") { "flush 轨迹 · 最近 #{flushes.size}" }
      if flushes.empty?
        label(css_class: "dbg-dim") { "（暂无 flush）" }
      else
        flushes.each do |f|
          props = { css_class: "dbg-row" }
          triggers = (f[:trigger_signal_ids] || [])
          if triggers.any?
            props[:data_hl_kind] = "signal"
            props[:data_hl_ids] = triggers.join(",")
          end
          label(**props) { fmt_flush(f) }
        end
      end

      label(css_class: "dbg-head") { "信号写入 · 最近 #{writes.size}" }
      if writes.empty?
        label(css_class: "dbg-dim") { "（暂无写入）" }
      else
        writes.each do |w|
          label(css_class: "dbg-row", data_hl_kind: "signal",
                data_hl_ids: w[:signal_id].to_s) { fmt_write(w) }
        end
      end

      kind = tree_kind == :elements ? "元素树（无组件边界，降级）" : "组件树"
      label(css_class: "dbg-head") { "#{kind} · #{tree_lines.size} 行（截断）" }
      tree_lines.each do |line, nid|
        label(css_class: "dbg-row", data_hl_kind: "node", data_hl_ids: nid.to_s) { line }
      end
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

  # object_id → DOM 元素索引（每次 poll 随树快照重建一次，75 节点量级）
  def dom_index
    @dom_index ||= {}
  end

  def rebuild_dom_index
    index = {}
    stack = [DBG_ROOT]
    until stack.empty?
      node = stack.pop
      next if node.nil?

      dom = (node.dom rescue nil)
      index[node.object_id] = dom if dom
      comp = node.rendered_component
      index[comp.object_id] = dom if comp && dom
      owner = node.owner
      index[owner.object_id] = dom if owner.is_a?(Citrine::Component) && dom
      stack.concat(node.children)
    end
    @dom_index = index
  end

  def highlight_targets(kind, ids)
    case kind
    when "node", "component"
      ids.map { |id| dom_index[id] }.compact
    when "signal", "flush"
      subs = ids.map { |id| Citrine::Signal.all.find { |s| s.object_id == id } }
                  .compact.flat_map { |s| s.instance_variable_get(:@subs) || [] }
      return [] if subs.empty?

      nodes_with_effects(subs)
    else
      []
    end
  end

  # 深度优先 walk：节点自带的 owned_effects / props_effect / block_effect
  # 与目标 effect 集有交集 → 该节点的 DOM 就是"这个 effect 画出来的东西"
  def nodes_with_effects(targets)
    found = []
    stack = [DBG_ROOT]
    until stack.empty?
      node = stack.pop
      next if node.nil?

      owned = [node.props_effect, node.block_effect, *(node.owned_effects || [])].compact
      dom = (node.dom rescue nil)
      found << dom if dom && owned.any? { |e| targets.include?(e) }
      stack.concat(node.children)
    end
    found
  end

  def draw_highlight_box(dom, kind, ids)
    dom_n = dom.to_n
    %x{
      var el = #{dom_n};
      if (el && el.getBoundingClientRect) {
        var r = el.getBoundingClientRect();
        if (r.width > 0 || r.height > 0) {
          var box = document.createElement('div');
          box.className = 'dbg-hl';
          box.style.cssText = 'position:fixed;z-index:9999;pointer-events:none;'
            + 'left:' + (r.left - 2) + 'px;top:' + (r.top - 2) + 'px;'
            + 'width:' + (r.width + 4) + 'px;height:' + (r.height + 4) + 'px;'
            + 'border:2px solid #4f8cff;border-radius:4px;background:#4f8cff22;'
            + 'box-shadow:0 0 0 1px #0b0e14,0 0 12px #4f8cff88;';
          var tag = document.createElement('div');
          tag.textContent = #{kind} + ' #' + #{ids.join(",")};
          tag.style.cssText = 'position:absolute;top:-18px;left:-2px;background:#4f8cff;'
            + 'color:#fff;font:10px/16px ui-monospace,Menlo,monospace;'
            + 'padding:0 5px;border-radius:3px;white-space:nowrap;';
          box.appendChild(tag);
          document.body.appendChild(box);
        }
      }
    }
  end

  # 树形缩进：制表符连线（非空白字符，不依赖 white-space:pre 也不会被折叠）
  def tree_indent(depth)
    return "" if depth.zero?

    "│   " * (depth - 1) + "├── "
  end

  # 组件树条目（有组件边界时）：一个组件一行；pair = [显示行, node_id]
  def build_tree_lines(node, depth, out)
    return if node.nil? || out.size >= 80 || depth > 6

    key = node[:reuse_key] ? " key=#{node[:reuse_key]}" : ""
    out << ["#{tree_indent(depth)}#{node[:component]} ##{short_id(node[:node_id])}#{key}", node[:node_id]]
    (node[:children] || []).each { |c| build_tree_lines(c, depth + 1, out) }
  end

  # 元素轮廓（无组件边界时降级）：VDOM 原始节点树，组件边界若有则标 ▸
  def build_outline(node, depth, out)
    return if node.nil? || out.size >= 80 || depth > 6

    comp = node.rendered_component
    tag = comp ? (comp.class.name || comp.class.to_s) : node.type.to_s
    mark = comp ? "▸" : "·"
    key = node.reuse_key ? " key=#{node.reuse_key}" : ""
    out << ["#{tree_indent(depth)}#{mark} #{tag} ##{short_id(node.object_id)}#{key}", node.object_id]
    node.children.each { |c| build_outline(c, depth + 1, out) }
  end
end

panel = DebugPanel.new
Beryl::Renderer.mount_at('devtools', panel)
# 轮询由外部一次性点火，之后 poll 自链（Beryl::Timer 是 setTimeout 一次性语义）
Beryl::Timer.after(300) { panel.poll }

# 悬浮高亮：#devtools 上事件委托一次绑定（行每 400ms 重建，委托不受影响）。
# 行内标签带 data-hl-kind / data-hl-ids（透传属性），hover 时经 Ruby 侧
# 找到对应 DOM 画描边 overlay；signal/flush 高亮其订阅 effect 渲染的节点。
if defined?(Opal)
  %x{
    window.__hlShow = #{panel.method(:show_highlight).to_proc.to_n};
    window.__hlHide = #{panel.method(:hide_highlight).to_proc.to_n};
    (function () {
      var dev = document.getElementById('devtools');
      if (!dev || dev.__hlBound) return;
      dev.__hlBound = true;
      dev.addEventListener('mouseover', function (ev) {
        var t = ev.target && ev.target.closest ? ev.target.closest('[data-hl-kind]') : null;
        if (!t || t === dev.__hlCurrent) return;
        dev.__hlCurrent = t;
        var ids = (t.getAttribute('data-hl-ids') || '').split(',').filter(Boolean).map(Number);
        window.__hlShow(t.getAttribute('data-hl-kind'), ids);
      });
      dev.addEventListener('mouseout', function (ev) {
        var t = ev.target && ev.target.closest ? ev.target.closest('[data-hl-kind]') : null;
        if (!t) return;
        if (ev.relatedTarget && t.contains(ev.relatedTarget)) return;
        dev.__hlCurrent = null;
        window.__hlHide();
      });
    })();
  }
end

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

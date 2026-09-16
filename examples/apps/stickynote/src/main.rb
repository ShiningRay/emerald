# frozen_string_literal: true

# 便利贴 —— 异形窗口演示（beryl WindowFrame#shape：clip-path 折角 +
# 包裹层 drop-shadow；标题栏样式化为"胶带"）。多实例便签：
# argv[:path] 打开既有便签；新便签首次保存时落到 /Notes/note-N.txt。
# entry 在运行时已加载（Emerald::App 可用）的前提下求值，自身不 require。
class StickyNote < Emerald::App
  app_id :stickynote
  app_title '便利贴'
  app_icon '🗒️'
  singleton false
  default_geometry { { x: 260, y: 160, w: 240, h: 240 } }

  # 右下角折角裁剪；吸附/缩放/最大化是矩形假设，对异形窗口全部关闭。
  # css_class 同时落在 .panel-wrap 与 .panel 上（desktop.html 的样式锚点）
  DOGEAR = 'polygon(0 0, 100% 0, 100% calc(100% - 26px), calc(100% - 26px) 100%, 0 100%)'
  window_opts shape: DOGEAR, css_class: 'sticky-note-win',
              resizable: false, maximizable: false, snap: false

  state :buf, default: ''
  state :dirty, default: false

  attr_reader :path

  def boot(ctx)
    super
    @path = argv && argv[:path]
    self.buf = load_content
    @snapshot = buf
    Citrine::Effect.create { self.dirty = (buf != @snapshot) }
  end

  def view
    stack(css_class: 'sticky-note', gap: 0) do
      textarea(css_class: 'sticky-note-area', value: signal(:buf),
               on_submit: ->(_e) { save })
      row(css_class: 'sticky-note-status', gap: 6,
          style: { align_items: 'center' }) do
        # 保存钮放左侧：右下角是折角裁剪区（shape DOGEAR），放右侧会被裁
        Beryl::Button.new(text: '保存', kind: :primary, size: :sm,
                          disabled: !dirty, on_click: -> { save }).view
        box(style: { flex: 1 })
        Beryl::Badge.new(text: '未保存 · ⌘⏎', kind: 'warn').view if dirty
        label { path.to_s } unless dirty
      end
    end
  end

  # 保存：有 path 直写；无 path 分配 /Notes/note-N.txt（首个空位）。
  # 渲染容忍 ctx 为 nil（无 vfs 时 save 空操作，StringRenderer 直渲染安全）
  def save
    vfs = ctx && ctx[:vfs]
    return unless vfs

    target = path || fresh_path(vfs)
    vfs.write(target, buf)
    @path = target
    @snapshot = buf
    self.dirty = false            # Effect 只在 buf 变化时重跑，保存须显式复位
    ctx[:notify]&.push('便利贴已保存', kind: :success)
  end

  private

  def load_content
    vfs = ctx && ctx[:vfs]
    return '' unless @path && vfs

    vfs.read(@path)
  rescue Emerald::VFS::NotFound
    ''
  end

  def fresh_path(vfs)
    vfs.mkdir('/Notes') unless vfs.exist?('/Notes')
    n = 1
    n += 1 while vfs.exist?("/Notes/note-#{n}.txt")
    "/Notes/note-#{n}.txt"
  end
end

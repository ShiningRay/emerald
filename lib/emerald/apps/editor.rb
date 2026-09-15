# frozen_string_literal: true

module Emerald
  module Apps
    # 文本编辑器（E3b）：头部（文件名 + ● 未保存标记）+ textarea（Signal 双向
    # 绑定 + ⌘⏎ 提交保存）+ 底部状态行（字符数 + 保存提示）。
    #
    # 状态：buf（内容）/ dirty（未保存）。dirty 由 boot 时建立的 Effect 自动
    # 推导（buf != @snapshot）——textarea 双向绑定直写 buf，任何编辑路径都
    # 逃不过 dirty 追踪；save 成功时 @snapshot 对齐 buf 并显式复位 dirty。
    #
    # 保存语义：有 path 直写 vfs；无 path（未命名）弹 Prompt 取名（相对名
    # 自动补 '/' 根前缀），写后进入正常路径。文件不存在（boot 时）→ 告警
    # 通知 + 空 buf，按新文件对待。
    #
    # 渲染容忍 ctx 为 nil：view 不直接消费 ctx（保存/加载才用服务），
    # 未 boot 实例经 StringRenderer 直渲染安全。
    class Editor < Emerald::App
      app_id :editor
      app_title '文本编辑器'
      app_icon '📝'
      singleton false
      default_geometry { { x: 140, y: 90, w: 560, h: 420 } }

      state :buf, default: ''
      state :dirty, default: false          # 未保存标记（Effect 自动推导）
      state :save_as, default: nil          # 无 path 首次保存的 Prompt：{ input: Signal }

      attr_reader :path

      def boot(ctx)
        super
        path = argv && argv[:path]
        content = path && ctx && ctx[:vfs] ? load_content(path) : ''
        @path = path
        @snapshot = content
        self.buf = content
        track_dirty
      end

      # 实例注销（窗口关闭）：停掉 dirty 追踪 Effect（E7 deactivate 链）
      def deactivate
        @dirty_effect&.dispose
        @dirty_effect = nil
      end

      def view
        stack(css_class: 'em-editor', gap: 6) do
          header_row
          textarea(css_class: 'em-editor-area', value: signal(:buf),
                   on_submit: ->(_e) { save })
          status_row
          save_as_dialog
        end
      end

      # 保存：path ? 直写 : Prompt 取名。写后 dirty=false + 成功通知。
      def save
        if path
          write_to(path)
        elsif ctx && ctx[:vfs]
          self.save_as = { input: Citrine.signal('未命名.txt') }
        end
      end

      def write_to(target)
        ctx[:vfs].write(target, buf)
        @path = target
        @snapshot = buf
        self.dirty = false
        ctx[:notify]&.push('已保存', kind: :success)
        ctx[:reload_source]&.call(target) # E7：/Applications 包源码保存 → 热更新
      end

      def confirm_save_as(name)
        name = name.to_s.strip
        write_to(absolute(name)) unless name.empty?
      ensure
        self.save_as = nil
      end

      def display_name
        path ? path.split('/').last : '未命名'
      end

      private

      def load_content(path)
        ctx[:vfs].read(path)
      rescue Emerald::VFS::NotFound
        ctx[:notify]&.push("文件不存在: #{path}", kind: :warning)
        ''
      end

      # 相对名补根前缀（VFS 只收绝对路径）
      def absolute(name)
        name.start_with?('/') ? name : "/#{name}"
      end

      def track_dirty
        @dirty_effect = Citrine::Effect.create { self.dirty = (buf != @snapshot) }
      end

      def header_row
        row(css_class: 'em-editor-head', gap: 6) do
          label(css_class: 'em-editor-name') { display_name }
          label(css_class: 'em-editor-dirty') { '●' } if dirty
        end
      end

      def status_row
        row(css_class: 'em-editor-status', gap: 12) do
          label(css_class: 'em-editor-count') { "#{buf.length} 字符" }
          box(css_class: 'em-editor-spring', style: { flex: 1 })
          label(css_class: 'em-editor-hint') { '⌘⏎ 保存' }
        end
      end

      def save_as_dialog
        dlg = save_as
        return unless dlg

        Beryl::Prompt.new(title: '保存文件', message: '文件路径：', input: dlg[:input],
                          confirm_text: '保存',
                          on_confirm: ->(name) { confirm_save_as(name) },
                          on_cancel: -> { self.save_as = nil }).view
      end
    end
  end
end

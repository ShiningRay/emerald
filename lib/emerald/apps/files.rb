# frozen_string_literal: true

module Emerald
  module Apps
    # 文件管理器（E3b）：Tree 侧栏（VFS 目录树）+ 面包屑/刷新/新建工具行 +
    # 文件表格 + 行右键菜单（重命名/删除）+ 确认/输入对话框。
    #
    # 数据流：行数据来自 VFS#list(dir)；dir 是受控 state（导航即赋值）。
    # 目录 watch 信号（VFS#watch → [path, version]）的版本号在表格内容块内
    # 读取（beryl F7 订阅边界）——目录自身或直接子级变更只重建表格，
    # 不波及侧栏与工具行；「刷新」钮走 refresh_tick 计数，语义同为仅重建表格。
    #
    # 渲染容忍 ctx 为 nil（StringRenderer 直渲染未 boot 实例的测试场景）：
    # 侧栏与表格行数据都有 `ctx && ctx[:vfs]` 守卫，无 vfs 时渲染空骨架。
    class Files < Emerald::App
      app_id :files
      app_title '文件管理器'
      app_icon '🗂️'
      singleton true
      default_geometry { { x: 60, y: 40, w: 640, h: 440 } }

      state :dir, default: '/'            # 当前目录（导航即赋值，受控）
      state :tree_open, default: ['/'].freeze # Tree 展开集（受控；dup 后写回，默认值冻结安全）
      state :refresh_tick, default: 0     # 手动刷新计数（订阅源）
      state :menu_target, default: nil    # 右键菜单：{ entry:, x:, y: }
      state :dialog, default: nil         # 模态：{ kind:, entry?, input? }

      def boot(ctx)
        super
        self.dir = initial_dir
      end

      def view
        stack(css_class: 'em-files', gap: 4) do
          label(css_class: 'em-files-hint') { '双击打开 · 右键菜单' }
          row(css_class: 'em-files-body', gap: 8) do
            sidebar
            main_area
          end
          context_menu
          dialog_layer
        end
      end

      # ---- 导航 ----

      def navigate(path)
        self.dir = Emerald::VFS.normalize(path)
      end

      # ---- 行行为（双击 / 右键 / 菜单动作）----

      def open_entry(entry)
        if entry[:kind] == :dir
          navigate(join_path(dir, entry[:name]))
        else
          ctx[:open_file]&.call(join_path(dir, entry[:name]))
        end
      end

      def open_row_menu(entry, event)
        x, y = event_xy(event)
        self.menu_target = { entry: entry, x: x, y: y }
      end

      def close_menu
        self.menu_target = nil
      end

      def ask_rename(entry)
        self.dialog = { kind: :rename, entry: entry, input: Citrine.signal(entry[:name]) }
      end

      def ask_delete(entry)
        self.dialog = { kind: :delete, entry: entry }
      end

      def ask_new_file
        self.dialog = { kind: :new_file, input: Citrine.signal('') }
      end

      # 删除（Confirm 确认后进入）：vfs.delete + 成功通知
      def do_delete(entry)
        ctx[:vfs].delete(join_path(dir, entry[:name]))
        ctx[:notify]&.push("已删除 #{entry[:name]}", kind: :success)
      ensure
        self.dialog = nil
      end

      # 重命名（Prompt 确认后进入）：vfs.move
      def do_rename(entry, name)
        name = name.to_s.strip
        ctx[:vfs].move(join_path(dir, entry[:name]), join_path(dir, name)) unless name.empty?
        ctx[:notify]&.push("已重命名为 #{name}", kind: :success) unless name.empty?
      ensure
        self.dialog = nil
      end

      # 新建文件（Prompt 确认后进入）：写空内容 → 进入编辑
      def do_new_file(name)
        name = name.to_s.strip
        unless name.empty?
          path = join_path(dir, name)
          ctx[:vfs].write(path, '')
          ctx[:notify]&.push("已创建 #{name}", kind: :success)
          ctx[:open_file]&.call(path)
        end
      ensure
        self.dialog = nil
      end

      def refresh
        self.refresh_tick = refresh_tick + 1
      end

      # ---- 视图分块（helper 一律返回块/组件渲染结果，beryl F8）----

      private

      def initial_dir
        path = argv && argv[:path]
        return '/' if path.nil? || path.to_s.empty?

        path = path.to_s
        stat = ctx && ctx[:vfs] ? safe_stat(path) : nil
        return path if stat&.kind == :dir

        parent_of(path) # 文件（或不存在路径）取目录部分
      rescue ArgumentError
        '/'
      end

      def safe_stat(path)
        ctx[:vfs].stat(path)
      rescue Emerald::VFS::NotFound
        nil
      end

      def parent_of(path)
        np = Emerald::VFS.normalize(path)
        idx = np.rindex('/')
        idx.zero? ? '/' : np[0...idx]
      end

      def join_path(parent, name)
        parent == '/' ? "/#{name}" : "#{parent}/#{name}"
      end

      def event_xy(event)
        return [0, 0] unless event

        x = event[:clientX]
        y = event[:clientY]
        x = event['clientX'] if x.nil? && event.respond_to?(:[])
        y = event['clientY'] if y.nil? && event.respond_to?(:[])
        [x || 0, y || 0]
      end

      def sidebar
        box(css_class: 'em-files-sidebar', style: { width: '180px' }) do
          next unless ctx && ctx[:vfs]

          Beryl::Tree.new(nodes: tree_nodes('/'),
                          expanded: signal(:tree_open),
                          on_toggle: ->(n) { toggle_tree(n) },
                          on_select: ->(n) { navigate(Beryl.pick(n, :id)) }).view
        end
      end

      # VFS 目录树：从 '/' 递归两层（目录节点带 children 才有展开箭头）
      def tree_nodes(path, depth = 0)
        ctx[:vfs].list(path).select { |n| n.kind == :dir }.map do |n|
          child = join_path(path, n.name)
          node = { id: child, label: n.name }
          node[:children] = tree_nodes(child, depth + 1) if depth < 1
          node
        end
      rescue Emerald::VFS::NotFound
        []
      end

      def toggle_tree(node)
        id = Beryl.pick(node, :id)
        cur = tree_open.dup
        cur.include?(id) ? cur.delete(id) : cur << id
        self.tree_open = cur
      end

      def main_area
        stack(css_class: 'em-files-main', gap: 6) do
          toolbar_row
          file_table
        end
      end

      def toolbar_row
        row(css_class: 'em-files-toolbar', gap: 8) do
          Beryl::Breadcrumb.new(items: crumbs).view
          box(css_class: 'em-files-spring', style: { flex: 1 })
          button(css_class: 'em-files-refresh', on_click: :refresh) { '刷新' }
          button(css_class: 'em-files-new', on_click: :ask_new_file) { '新建文件' }
        end
      end

      def crumbs
        items = [{ label: '/', on_click: -> { navigate('/') } }]
        segs = dir.split('/').reject(&:empty?)
        path = +''
        segs.each do |seg|
          path = "#{path}/#{seg}"
          target = path.dup
          items << { label: seg, on_click: -> { navigate(target) } }
        end
        items
      end

      def file_table
        box(css_class: 'em-files-table') do
          # 订阅边界（beryl F7）：watch 版本号与刷新计数只在本内容块内读取，
          # 目录变更 / 导航 / 手动刷新时仅重建表格
          watch_bump
          refresh_tick
          table_body
        end
      end

      def watch_bump
        return 0 unless ctx && ctx[:vfs]

        _watched, version = ctx[:vfs].watch(dir).get
        version
      end

      def table_body
        stack(css_class: 'b-table em-files-rows', gap: 0) do
          row(css_class: 'b-table-head', gap: 0) do
            box(css_class: 'b-table-th') { '名称' }
            box(css_class: 'b-table-th') { '类型' }
            box(css_class: 'b-table-th') { '修改时间' }
          end
          entries = listed_entries
          if entries.empty?
            row(css_class: 'b-table-row is-empty', gap: 0) do
              box(css_class: 'b-table-td') { '（空目录）' }
            end
          else
            entries.each { |entry| file_row(entry) }
          end
        end
      end

      def listed_entries
        return [] unless ctx && ctx[:vfs]

        ctx[:vfs].list(dir).map do |node|
          { name: node.name, kind: node.kind, mtime: node.mtime }
        end
      rescue Emerald::VFS::NotFound
        []
      end

      def file_row(entry)
        row(css_class: 'b-table-row', gap: 0,
            on_dblclick: ->(_e) { open_entry(entry) },
            on_menu: ->(e) { open_row_menu(entry, e) }) do
          box(css_class: 'b-table-td em-files-name') { entry[:name] }
          box(css_class: 'b-table-td') { entry[:kind] == :dir ? '目录' : '文件' }
          box(css_class: 'b-table-td') { entry[:mtime].to_s }
        end
      end

      def context_menu
        target = menu_target
        return unless target

        entry = target[:entry]
        Beryl::Menu.new(x: target[:x] || 0, y: target[:y] || 0,
                        on_close: -> { close_menu },
                        items: [
                          { label: '重命名', action: -> { ask_rename(entry) } },
                          { label: '删除', action: -> { ask_delete(entry) } },
                        ]).view
      end

      def dialog_layer
        dlg = dialog
        return unless dlg

        case dlg[:kind]
        when :delete
          delete_dialog(dlg[:entry])
        when :rename
          rename_dialog(dlg)
        when :new_file
          new_file_dialog(dlg)
        end
      end

      def delete_dialog(entry)
        Beryl::Confirm.new(title: '删除',
                           message: "确定删除「#{entry[:name]}」吗？此操作不可撤销。",
                           confirm_text: '删除',
                           on_confirm: -> { do_delete(entry) },
                           on_cancel: -> { self.dialog = nil }).view
      end

      def rename_dialog(dlg)
        Beryl::Prompt.new(title: '重命名', message: '新名称：', input: dlg[:input],
                          on_confirm: ->(name) { do_rename(dlg[:entry], name) },
                          on_cancel: -> { self.dialog = nil }).view
      end

      def new_file_dialog(dlg)
        Beryl::Prompt.new(title: '新建文件', message: '文件名：', input: dlg[:input],
                          confirm_text: '创建',
                          on_confirm: ->(name) { do_new_file(name) },
                          on_cancel: -> { self.dialog = nil }).view
      end
    end
  end
end

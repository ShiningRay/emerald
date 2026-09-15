# frozen_string_literal: true

module Emerald
  module Apps
    # 终端（E5c，PLAN 决策 D9：v1 = VFS shell，不做 REPL）。
    # 逻辑与视图分层：
    #   Terminal::Session —— 纯 CRuby、零 UI 依赖的 VFS shell，可完整单测
    #   Terminal          —— 薄视图壳（< Emerald::App），只负责渲染与输入派发
    class Terminal < Emerald::App
      app_id :terminal
      app_title '终端'
      app_icon '⌨️'
      singleton true
      default_geometry { { x: 180, y: 100, w: 560, h: 380 } }

      # VFS shell：注入 VFS 后可独立驱动（不依赖任何组件/渲染器）。
      # 约定：
      #   - run 永不 raise：命令错误/异常一律落成错误行（中文提示）
      #   - 路径相对 cwd 解析；'~' 视为 '/'（v1 单用户无 home 概念，见 #resolve）
      #   - 错误行格式对齐命令行惯例：`cat: xxx: 没有此文件或目录`
      class Session
        # 帮助清单（help 命令输出，多行 String）
        HELP_TEXT = <<~HELP.strip.freeze
          可用命令：
            help                  显示本清单
            pwd                   显示当前目录
            ls [目录]             列出目录内容（目录名后加 /）
            cd <目录>             切换当前目录（支持绝对/相对路径、.. 与 ~）
            cat <文件>            查看文件内容
            mkdir <目录>          新建目录（递归创建）
            touch <文件>          新建空文件；已存在则只刷新修改时间
            echo <文本> > <文件>  覆盖写入文件（父目录自动创建）
            echo <文本> >> <文件> 追加写入文件
            rm <路径>             删除文件或目录（递归）
            clear                 清屏
        HELP

        attr_reader :cwd, :history, :clear_count

        def initialize(vfs)
          @vfs = vfs
          @cwd = '/'
          @history = []       # 已执行命令（原文，v1 供 ↑ recall 用）
          @clear_count = 0    # 视图清屏次数（屏幕缓冲语义 v1.1 在此扩展）
        end

        # 执行一行命令 => String（可能多行，以 \n 连接）。
        # 空输入返回空串；任何错误都不抛出，落成错误行。
        def run(command)
          raw = command.to_s.strip
          return '' if raw.empty?

          @history << raw
          name, *args = raw.split(/\s+/)
          dispatch(name, args)
        rescue Emerald::VFS::NotFound
          "#{name}: 没有此文件或目录"
        rescue ArgumentError => e
          "#{name}: #{e.message}"
        end

        # 视图清屏时调用（run('clear') 只负责返回空串，清屏动作归视图）
        def clear!
          @clear_count += 1
          self
        end

        private

        def dispatch(name, args)
          case name
          when 'help'  then HELP_TEXT
          when 'pwd'   then @cwd
          when 'ls'    then cmd_ls(args)
          when 'cd'    then cmd_cd(args)
          when 'cat'   then cmd_cat(args)
          when 'mkdir' then cmd_mkdir(args)
          when 'touch' then cmd_touch(args)
          when 'echo'  then cmd_echo(args)
          when 'rm'    then cmd_rm(args)
          when 'clear' then ''
          else "#{name}: command not found\n输入 'help' 查看可用命令"
          end
        end

        # ls [目录]：v1 忽略选项（如 -l，参数以 - 开头的一律视为选项跳过）；
        # 目录名后加 /，排序直接沿用 vfs.list（目录在前、同 kind 按名升序）
        def cmd_ls(args)
          dir_arg = args.reject { |a| a.start_with?('-') }.first
          path = dir_arg ? resolve(dir_arg) : @cwd
          node = @vfs.stat(path)
          return "ls: #{dir_arg}: 没有此文件或目录" if node.nil?
          return "ls: #{dir_arg}: 不是目录" if node.kind == :file

          @vfs.list(path).map { |n| n.kind == :dir ? "#{n.name}/" : n.name }.join("\n")
        end

        def cmd_cd(args)
          return 'cd: 缺少参数（用法：cd <目录>）' if args.empty?

          path = resolve(args[0]) # 越根（根处 ..）已原地留在 '/'，见 resolve
          node = @vfs.stat(path)
          return "cd: #{args[0]}: 没有此文件或目录" if node.nil?
          return "cd: #{args[0]}: 不是目录" if node.kind == :file

          @cwd = path
          ''
        end

        def cmd_cat(args)
          return 'cat: 缺少参数（用法：cat <文件>）' if args.empty?

          path = resolve(args[0])
          node = @vfs.stat(path)
          return "cat: #{args[0]}: 没有此文件或目录" if node.nil?
          return "cat: #{args[0]}: 是目录" if node.kind == :dir

          @vfs.read(path)
        end

        def cmd_mkdir(args)
          return 'mkdir: 缺少参数（用法：mkdir <目录>）' if args.empty?

          @vfs.mkdir(resolve(args[0]))
          ''
        end

        # touch：不存在则建空文件（VFS write 自动补父目录）；已存在则只刷 mtime
        # ——VFS 没有裸 touch 入口，读回原文再写回，内容不变、mtime 冒泡更新
        def cmd_touch(args)
          return 'touch: 缺少参数（用法：touch <文件>）' if args.empty?

          path = resolve(args[0])
          node = @vfs.stat(path)
          return "touch: #{args[0]}: 是目录" if node&.kind == :dir

          @vfs.write(path, node ? @vfs.read(path) : '')
          ''
        end

        # echo <文本> > <文件> / >> <文件>：重定向目标前的词全部视为文本（空白折叠）；
        # 无重定向则把文本原样输出。覆盖/追加的父目录自动创建（VFS write 语义）
        def cmd_echo(args)
          return 'echo: 缺少参数（用法：echo <文本> > <文件>）' if args.empty?

          redirect_at = args.index('>') || args.index('>>')
          return args.join(' ') unless redirect_at

          target = args[redirect_at + 1]
          return 'echo: 缺少重定向目标文件' if target.nil?

          text = args[0...redirect_at].join(' ')
          path = resolve(target)
          content = args[redirect_at] == '>>' && @vfs.exist?(path) ? @vfs.read(path) : ''
          @vfs.write(path, content + text)
          ''
        end

        # rm：VFS delete 即递归删除
        def cmd_rm(args)
          return 'rm: 缺少参数（用法：rm <路径>）' if args.empty?

          path = resolve(args[0])
          return "rm: #{args[0]}: 没有此文件或目录" unless @vfs.exist?(path)

          @vfs.delete(path)
          ''
        end

        # 路径解析：相对 cwd；'~' 视为 '/'（v1 单用户无 home 概念，~/x 即 /x）；
        # '..' 越出根时按 POSIX 语义原地留在 '/'（normalize 的越根 ArgumentError 吸收于此）
        def resolve(path)
          expanded = path.sub(/\A~(?=\/|\z)/, '/')
          combined = expanded.start_with?('/') ? expanded : join(@cwd, expanded)
          Emerald::VFS.normalize(combined)
        rescue ArgumentError
          '/'
        end

        def join(dir, name)
          dir == '/' ? "/#{name}" : "#{dir}/#{name}"
        end
      end

      # ── 视图壳 ──────────────────────────────────────────

      MONO = "ui-monospace, Menlo, monospace"

      WELCOME = '欢迎来到 Emerald 终端'
      HELP_HINT = "输入 'help' 查看可用命令"

      state :lines do
        [WELCOME, HELP_HINT]
      end
      state :input, default: ''

      attr_reader :session

      # ctx 缺 VFS 时 session 为 nil，view 层守卫跳过会话区（仍渲染占位提示）
      def boot(ctx)
        super
        @session = ctx && ctx[:vfs] ? Session.new(ctx[:vfs]) : nil
      end

      def view
        stack(style: { width: '100%', height: '100%', background: '#1e1e2e', color: '#cdd6f4' }) do
          if session
            output_area
            input_row
          else
            label(style: { padding: 12 }) { '终端不可用：缺少 VFS 服务' }
          end
        end
      end

      # 回车执行：非空命令追加「提示符 + 输出行」，然后清空输入。
      # clear 特判：清屏后只留欢迎语（输出行与提示符一并丢弃）
      def exec
        return unless session

        cmd = input.to_s.strip
        return if cmd.empty?

        prompt = "#{session.cwd} > #{cmd}"
        out = session.run(cmd)
        self.input = ''
        if cmd == 'clear'
          session.clear!
          self.lines = [WELCOME]
          return
        end
        self.lines = lines + [prompt, *out.split("\n")]
      end

      private

      # 输出区：lines 逐行 label，等宽字 + 溢出滚动（F8：helper 返回 .view 结果）
      def output_area
        box(style: {
              flex: 1, min_height: 0, overflow: 'auto',
              font_family: MONO, font_size: 12, line_height: 1.5,
              padding: 8, white_space: 'pre-wrap', word_break: 'break-all'
            }) do
          lines.each { |l| label { l } }
        end
      end

      # 输入行：cwd 提示符 + 受控输入框（autofocus）
      def input_row
        box(style: { padding: 6, border_top: '1px solid #313244', align_items: 'center' }) do
          label(style: { color: '#89b4fa', white_space: 'pre' }) { "#{session.cwd} > " }
          text_input(value: signal(:input), on_enter: -> { exec }, autofocus: true,
                     style: { flex: 1, background: 'transparent', color: '#cdd6f4',
                              border: 'none', outline: 'none',
                              font_family: MONO, font_size: 12 })
        end
      end
    end
  end
end

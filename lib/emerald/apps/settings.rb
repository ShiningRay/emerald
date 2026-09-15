# frozen_string_literal: true

module Emerald
  module Apps
    # 设置（E4，见 docs/PLAN.md §3.8）：分组表单——外观（主题/强调色/密度）、
    # 壁纸、存储统计、关于。全部写操作即时 settings.set + Theme.apply 重应用
    #（CRuby 下 apply 只解析并返回应写入的变量表，no-op；Opal 下写 :root）。
    #
    # 受控约定（beryl F4）：Select 开合传受控 open signal；RadioGroup/Select/
    # ColorPicker 的 value 是「只读信号适配」（SettingValue）——SettingsStore#get
    # 本身就是订阅式读取，包一层补齐 Signal 形状即可；写路径不经它（受控值语义：
    # 写 = on_change → store.set，store 是唯一事实源，控件勾选态经订阅自动跟随）。
    #
    # ctx 容忍：ctx 为 nil（未 boot 直渲染）或个别服务缺失时不炸——设置项回落到
    # 自带默认 SettingsStore，VFS/注册表缺失时对应区块渲染占位。
    class Settings < Emerald::App
      app_id :settings
      app_title '设置'
      app_icon '⚙️'
      singleton true
      default_geometry { { x: 220, y: 110, w: 460, h: 400 } }

      # 设置项默认值：与 SettingsStore 的约定一致（fallback store 必须带全
      # 四个 key，否则未知 key 会 ArgumentError）
      DEFAULTS = { theme: :dark, accent: '#4f8cff', wallpaper: :aurora, density: :comfortable }.freeze

      THEME_OPTIONS = [['深色', :dark], ['浅色', :light]].freeze
      DENSITY_OPTIONS = [['舒适', :comfortable], ['紧凑', :compact]].freeze

      # 壁纸预设：值存 settings.set(:wallpaper, v)。渐变是「近似预览」——桌面真正
      # 铺壁纸由 shell 读同一设置项决定；aurora 与 Theme 内置默认壁纸同构图。
      WALLPAPER_OPTIONS = [['极光', :aurora], ['石墨', :graphite], ['草甸', :meadow]].freeze
      WALLPAPER_GRADIENTS = {
        aurora: 'radial-gradient(ellipse at 30% 20%, #16233d, #0b0e14)',
        graphite: 'linear-gradient(135deg, #333a47, #14171d)',
        meadow: 'linear-gradient(160deg, #24513a, #101f16)',
      }.freeze

      # 「清除全部数据」确认文案：storage 适配协议只有 load/dump，没有 delete/
      # clear 通道（LocalStorage 后端同样无 removeItem 可达），应用层做不到真正
      # 清空——按钮保留但如实说明，确认 = 关弹窗 + 通知指引手动清站点数据。
      # 取舍：不假装清空了数据，也不做半吊子的「清 VFS 内存树」（刷新即复活，
      # 比不清更误导）。
      CLEAR_NOTICE = '浏览器端数据存于 localStorage，存储协议仅支持读写、' \
                     '无删除通道。如需清空全部数据，请手动清除本站点数据' \
                     '（浏览器设置 → 隐私 → 清除站点数据）后刷新。'

      # Select 开合、确认框显隐一律受控 signal（beryl F4：内部态活不过父块重渲染）
      state :density_open, default: false
      state :wallpaper_open, default: false
      state :clear_dialog_open, default: false

      # beryl 受控件的 value 约定传 Signal：这里把 store 的某个 key 包成
      # 只读信号壳（.get → store.get，订阅语义原样保留）。
      class SettingValue
        def initialize(store, key)
          @store = store
          @key = key
        end

        def get
          @store.get(@key)
        end
      end

      # 设置存储：优先 ctx 注入；缺省时回落到自带默认 store（storage: nil
      # 不持久化），保证未接入服务的场景（如单测直渲染）控件仍有合法值可读。
      def settings_store
        store = ctx && ctx[:settings]
        store || (@fallback_store ||= Emerald::SettingsStore.new(storage: nil, defaults: DEFAULTS))
      end

      # ── 写路径：全部 on_change 经这里——store.set + Theme.apply 即时重应用 ──

      def change_theme(mode)
        settings_store.set(:theme, mode)
        reapply_theme!
      end

      def change_accent(color)
        settings_store.set(:accent, color)
        reapply_theme!
      end

      def change_density(density)
        settings_store.set(:density, density)
        reapply_theme!
      end

      def change_wallpaper(name)
        settings_store.set(:wallpaper, name)
      end

      # 重应用主题：handlers 里用 peek 按需读（不订阅），值刚刚 set 落库
      def reapply_theme!
        Theme.apply(settings_store.peek(:theme),
                    accent: settings_store.peek(:accent),
                    density: settings_store.peek(:density))
      end

      # ── view ────────────────────────────────────────────

      def view
        stack(css_class: 'emerald-settings', gap: 18,
              style: { padding: '14px', height: '100%', overflow_y: 'auto' }) do
          appearance_section
          wallpaper_section
          storage_section
          about_section
          nil
        end
      end

      private

      # 分组容器：标题 + 内容区（helper 内全是元素 emit；结尾显式 nil，
      # 避免块返回值被 citrine 当成节点文本——容器节点已有子节点时本无害，
      # 空容器时它是双保险）
      def group(title, &block)
        stack(css_class: 'settings-group', gap: 8) do
          label(css_class: 'settings-group-title') { title }
          stack(css_class: 'settings-group-body', gap: 10, &block)
          nil
        end
      end

      def setting_value(key)
        @setting_values ||= {}
        @setting_values[key] ||= SettingValue.new(settings_store, key)
      end

      def appearance_section
        group('外观') do
          row(gap: 12) do
            label { '主题' }
            Beryl::RadioGroup.new(options: THEME_OPTIONS,
                                  value: setting_value(:theme),
                                  on_change: ->(v) { change_theme(v) },
                                  direction: :row).view
          end
          row(gap: 12) do
            label { '强调色' }
            Beryl::ColorPicker.new(value: setting_value(:accent),
                                   on_change: ->(c) { change_accent(c) }).view
          end
          row(gap: 12) do
            label { '密度' }
            Beryl::Select.new(options: DENSITY_OPTIONS,
                              value: setting_value(:density),
                              open: signal(:density_open),
                              on_change: ->(v) { change_density(v) }).view
          end
          nil
        end
      end

      def wallpaper_section
        group('壁纸') do
          row(gap: 12) do
            label { '壁纸' }
            Beryl::Select.new(options: WALLPAPER_OPTIONS,
                              value: setting_value(:wallpaper),
                              open: signal(:wallpaper_open),
                              on_change: ->(v) { change_wallpaper(v) }).view
          end
          row(gap: 8) do
            label { '预览' }
            box(css_class: 'wallpaper-preview',
                style: { background: wallpaper_gradient, width: '96px', height: '40px' })
          end
          nil
        end
      end

      # 预览渐变：预设表查不到的值回落 Theme.vars 的 --wallpaper（主题内置壁纸）
      def wallpaper_gradient
        WALLPAPER_GRADIENTS[settings_store.get(:wallpaper)] ||
          Theme.vars(settings_store.get(:theme))['--wallpaper']
      end

      def storage_section
        group('存储') do
          vfs = ctx && ctx[:vfs]
          if vfs
            # 订阅根目录 watch：任何 commit 的 bump 沿祖先链上冒到根，
            # 统计数字随 VFS 变更自动刷新（SSR 无 Effect，读一次即走）
            vfs.watch(Emerald::VFS::ROOT).get
            stats = vfs_stats(vfs)
            label(css_class: 'settings-storage-stats') do
              "目录 #{stats[:dirs]} · 文件 #{stats[:files]} · #{format_bytes(stats[:bytes])}"
            end
          else
            label(css_class: 'settings-storage-missing') { 'VFS 服务未接入，无法统计' }
          end
          button(css_class: 'b-btn danger',
                 on_click: ->(_e) { self.clear_dialog_open = true }) { '清除全部数据' }
          clear_confirm_dialog if clear_dialog_open
          nil
        end
      end

      def clear_confirm_dialog
        Beryl::Confirm.new(title: '清除全部数据',
                           message: CLEAR_NOTICE,
                           confirm_text: '我知道了',
                           on_confirm: -> { acknowledge_clear },
                           on_cancel: -> { self.clear_dialog_open = false }).view
      end

      # 确认 = 关弹窗 + 通知指引（见 CLEAR_NOTICE 的取舍说明）
      def acknowledge_clear
        self.clear_dialog_open = false
        notifier = ctx && ctx[:notify]
        notifier&.push('存储协议无删除通道：请手动清除站点数据后刷新', kind: :warning)
      end

      # 递归统计（VFS 只提供 list，遍历在此自实现）：目录数/文件数/总字节。
      # 字节口径用 String#size——VFS 面向文本内容，统计为近似值（Opal 同口径）。
      def vfs_stats(vfs, path = Emerald::VFS::ROOT)
        dirs = 0
        files = 0
        bytes = 0
        vfs.list(path).each do |node|
          if node.kind == :dir
            dirs += 1
            child = vfs_stats(vfs, Emerald::VFS.normalize("#{path}/#{node.name}"))
            dirs += child[:dirs]
            files += child[:files]
            bytes += child[:bytes]
          else
            files += 1
            bytes += node.content.to_s.size
          end
        end
        { dirs: dirs, files: files, bytes: bytes }
      end

      def format_bytes(n)
        return "#{n} B" if n < 1024

        kb = n / 1024.0
        return format('%.1f KB', kb) if kb < 1024

        format('%.1f MB', kb / 1024.0)
      end

      def about_section
        group('关于') do
          label { 'Emerald OS · 设置' }
          button(css_class: 'b-btn', on_click: ->(_e) { launch_about }) { '关于本系统…' }
          nil
        end
      end

      # 从事件回调进入（beryl F6 安全区）；ctx 未注入注册表时 no-op。
      # 约定 services 里注册表键为 :apps（与 :vfs/:settings 等同属 ServiceHub）。
      def launch_about
        registry = ctx && ctx[:apps]
        registry&.launch(:about)
      end
    end
  end
end

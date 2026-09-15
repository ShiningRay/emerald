# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  # 桌面外壳（E1/E4 · docs/PLAN.md §3.1/§3.7 + 决策 D2/D3/D4）：
  # 整机根组件——组装壁纸层 / 桌面图标网格 / 窗口渲染循环 / 菜单栏 / 任务栏 /
  # 托盘（时钟 + 通知角标）/ Toast 堆叠，并在 initialize（渲染器外，beryl F6
  # 安全区）完成全部系统服务的构建与内置应用注册。
  #
  # 纯 CRuby 可测（beryl F5）：initialize 在 CRuby 下全程可执行
  # （StringRenderer 渲染路径）；所有 Opal 代码 defined?(Opal) 守卫，
  # 反引号 JS 仅出现在 current_viewport / viewport 跟踪两处。
  class DesktopShell < Citrine::Component
    # 应用未声明 default_geometry 时的兜底几何
    FALLBACK_GEOMETRY = { x: 120, y: 90, w: 480, h: 360 }.freeze
    # 多实例级联偏移：同应用第 N 个存活实例 x/y 各 +24（第一个实例 +0）
    CASCADE_OFFSET = 24
    # 托盘时钟走字间隔
    CLOCK_INTERVAL_MS = 30_000
    # 桌面图标来源目录（VFS seed 保证存在）
    DESKTOP_DIR = '/Desktop'
    # 设置项默认值（docs/PLAN.md §3.4；wallpaper 预设留待 Settings 应用消费）
    DEFAULT_SETTINGS = {
      theme: :dark, accent: '#4f8cff', wallpaper: :aurora, density: :comfortable
    }.freeze

    # shell 自身交互态全部受控 signal（beryl F4）：
    # 菜单栏开合索引 / 图标选择集 / 托盘时钟文本
    state :menu_open, default: nil
    state(:selected_icons) { [] }
    state :clock, default: '--:--'

    # 全局键盘 → Emerald.hotkey（citrine window_key 接线）
    window_key :dispatch_hotkey

    # 生命周期：托盘时钟启停 + 视口跟踪挂载/移除（SSR 下 on_mount 也会跑，
    # 时钟首次走字、Timer 无后端时安全跳过；视口跟踪 defined?(Opal) 守卫）
    on_mount :start_clock, :track_viewport
    on_unmount :stop_clock, :untrack_viewport

    # 主题响应式重应用：settings.get 在 watch 的 Effect 里读即订阅（CRuby 下
    # SSR 不建 Effect，no-op；Opal 下写 :root CSS 变量）
    watch :reapply_theme

    # 公开读访问器：测试与将来应用取服务用
    attr_reader :registry, :wm, :vfs, :settings, :notify, :services, :clipboard,
                :router, :commands, :hub, :installer, :apphost

    # 启动序列（渲染器外 = F6 安全区）：服务构建 → 注册表/窗口管理器 →
    # 内置应用注册 → 预装包 seed → /Applications 扫描注册 → 贡献点接线 →
    # 全局快捷键 → 首渲染前应用主题（防闪变）。
    def initialize
      super()
      storage = defined?(Opal) ? Emerald::Storage::LocalStorage.new : Emerald::Storage::Memory.new
      @settings = Emerald::SettingsStore.new(storage: storage, defaults: DEFAULT_SETTINGS)
      @settings.load
      @vfs = Emerald::VFS.new(storage: storage)
      @notify = Emerald::NotificationCenter.new(limit: 5)
      @clipboard = Emerald::Clipboard.new
      @commands = Emerald::CommandRegistry.new
      @hub = Emerald::ServiceHub.new
      @router = build_router
      @installer = Emerald::Pkg::Installer.new(vfs: @vfs)
      @apphost = Emerald::Pkg::AppHost.new(vfs: @vfs, lock: @installer.lock,
                                           compiler: pkg_compiler, loader: pkg_loader)
      @services = { vfs: @vfs, settings: @settings, notify: @notify,
                    clipboard: @clipboard, router: @router,
                    commands: @commands, hub: @hub, installer: @installer }
      @wm = Beryl::WindowManager.new(viewport: current_viewport)
      @registry = Emerald::AppRegistry.new(services: @services)
      @registry.wm = @wm
      @services[:launcher] = @registry
      @services[:apps] = @registry # 别名：设置应用等按「应用列表」语义读取
      @services[:open_file] = ->(path) { open_file_with(path) }
      @services[:reload_source] = ->(path) { on_app_source_saved(path) }
      register_builtin_apps
      seed_preinstalled_packages
      scan_installed_apps
      register_contributions
      register_system_commands
      @hub.activate_startup(@services)
      register_global_hotkeys
      Emerald::Pkg::OpalParser.preload if defined?(Opal)
      Emerald::Theme.apply(@settings.peek(:theme), accent: @settings.peek(:accent),
                           density: @settings.peek(:density))
    end

    # ── 启动序列的分步 ────────────────────────────────────

    # 文件类型路由：.txt/.md/.rb → 编辑器（FileTypeRouter 纯服务，见 router.rb）；
    # .emz 的安装路由在 open_file_with 里特判（Installer 不是窗口应用）
    def build_router
      Emerald::FileTypeRouter.new.tap do |router|
        %w[.txt .md .rb].each { |ext| router.register(ext, :editor) }
      end
    end

    # ── 预装 / 扫描 / 贡献点（E7 · PLAN §3.10）────────────

    # 内置应用 = 预装应用：把包正本（源码）seed 进 /Applications（幂等，
    # 用户编辑过的正本不覆盖）；类本身已随 bundle 定义（编译产物形态），
    # lock 打 bundled 标记让 AppHost 扫描跳过求值（开机不加载 opal-parser，D12）
    def seed_preinstalled_packages
      Emerald::Packages.builtin.each do |id, files|
        dir = "#{Emerald::Pkg::Installer::APPS_DIR}/#{id}"
        next if @vfs.exist?("#{dir}/manifest.json")

        @installer.install_dir(dir, files)
        @installer.lock.mark_bundled(id)
      end
    rescue StandardError => e
      @notify.push("预装应用初始化失败：#{e.message}", kind: :warning)
    end

    # 扫描 /Applications：源码应用经编译缓存求值后注册；失败项逐个通知，
    # 不拖垮整机（PLAN §8：用户改坏 /Applications ≠ 系统崩）
    def scan_installed_apps
      @apphost.scan(@registry).each do |r|
        @notify.push("应用 #{r[:id]} 装载失败：#{r[:message]}", kind: :warning) if r[:status] == :failed
      end
    end

    # 包 manifest 贡献点接线（SPEC §4.1）：commands → CommandRegistry +
    # 快捷键；file_types → FileTypeRouter。v1 所有命令都归约为「打开该应用」
    # （命令体真正跑包内代码列 v1.1，见 PLAN 实施记录）。
    def register_contributions
      @installer.list.each do |entry|
        next unless entry['kind'] == 'app'

        id = entry['id']
        manifest = begin
          Emerald::Pkg::Manifest.parse(@vfs.read("#{Emerald::Pkg::Installer::APPS_DIR}/#{id}/manifest.json"))
        rescue StandardError
          next
        end
        manifest.commands.each do |cmd|
          next if @commands.command?(cmd[:id])

          app_id = id.to_sym
          @commands.register(cmd[:id], title: cmd[:title], hotkey: cmd[:hotkey]) { launch_app(app_id) }
          Emerald.hotkey.register(cmd[:hotkey]) { @commands.run(cmd[:id]) } if cmd[:hotkey]
        end
        manifest.file_types.each { |ext| @router.register(ext, id) }
      end
    end

    # 系统级命令：每个注册应用一个 app.<id>（菜单/启动器/快捷键三处可达）
    def register_system_commands
      @registry.apps.each do |app|
        cid = "app.#{app[:id]}"
        next if @commands.command?(cid)

        app_id = app[:id]
        @commands.register(cid, title: "打开 #{app[:title]}") { launch_app(app_id) }
      end
    end

    # 编译边界（浏览器 = opal-parser 懒加载 chunk；CRuby 测试为 nil——
    # 仅 bundled 预装可装载，源码应用装载会在 AppHost 报 failed）
    def pkg_compiler
      return nil unless defined?(Opal)

      ->(src, _id) { Emerald::Pkg::OpalParser.compile(src) }
    end

    def pkg_loader
      return nil unless defined?(Opal)

      ->(js) { Emerald::Pkg::OpalParser.run_module(js) }
    end

    # ── 包安装 / 卸载 / 热更新（事件回调专用入口）─────────

    # 安装管线统一收尾：reload（注册或 reopen）→ 贡献点重接 → 通知
    def install_and_register
      result = yield
      id = result[:manifest].id
      report = @apphost.reload(@registry, id)
      register_contributions
      case result[:status]
      when :installed then @notify.push("#{result[:manifest].name} 已安装", kind: :success)
      when :updated   then @notify.push("#{result[:manifest].name} 已更新", kind: :success)
      end
      @notify.push("应用 #{id} 装载失败：#{report[:message]}", kind: :warning) if report[:status] == :failed
      result
    rescue StandardError => e
      @notify.push("安装失败：#{e.message}", kind: :error)
      nil
    end

    # 浏览器文件选择器（Settings 安装区）：bytes 为字节 Array<Integer>
    def install_package_bytes(filename, bytes)
      install_and_register { @installer.install_file(filename, bytes) }
    end

    # git URL 导入（浏览器走平台 archive HTTP；未支持平台报错走通知）
    def install_git_url(url)
      install_and_register { @installer.install_git(url) }
    end

    # Files 双击 .emz：VFS 里的包文件是 latin1 串形态（字符码 = 字节）
    def install_vfs_emz(path)
      bytes = Emerald::Pkg::Bytes.from_latin1(@vfs.read(path))
      install_and_register { @installer.install_file(path, bytes) }
    end

    # 卸载：先关该应用全部窗口（复用关闭链路），再删包与 lock
    def uninstall_package(id)
      @registry.each_running.select { |i| i.class.app_id == id.to_sym }
               .each { |i| close_window(i.win_id) }
      ok = @installer.uninstall(id)
      @commands.unregister("app.#{id}")
      @notify.push(ok ? "已卸载 #{id}" : "未安装 #{id}", kind: ok ? :success : :warning)
      ok
    end

    # Editor 保存钩子（services[:reload_source]）：改动 /Applications 下的
    # 包源码 → 重编 + reopen 热更新该应用类
    def on_app_source_saved(path)
      return unless path.start_with?("#{Emerald::Pkg::Installer::APPS_DIR}/")

      app_id = path.split('/')[2]
      return if app_id.nil? || app_id.empty?

      report = @apphost.reload(@registry, app_id)
      if report[:status] == :failed
        @notify.push("应用 #{app_id} 重载失败（保留上一版本）：#{report[:message]}", kind: :error)
      else
        @notify.push("应用 #{app_id} 已热更新", kind: :success)
      end
    end

    # 内置应用按可用性注册：Files/Editor/Settings/Terminal 由并行里程碑填充，
    # 此时可能还是没声明 app_id 的桩（register 会 ArgumentError）或常量未定义
    # （NameError）——失败不阻塞外壳启动，应用就绪（重载）后自动进注册表。
    def register_builtin_apps
      %i[About Files Editor Settings Terminal].each do |name|
        next unless Emerald::Apps.const_defined?(name, false)

        begin
          @registry.register(Emerald::Apps.const_get(name, false))
        rescue ArgumentError
          next # 桩期（未声明 app_id）等注册失败不阻塞外壳
        end
      end
    end

    # 全局快捷键（Emerald.hotkey 单例，PLAN §3.6）：meta+w 关闭激活窗、
    # meta+1..9 聚焦第 N 个窗口。块以定义处闭包执行（beryl F1），
    # 重复初始化覆盖注册（ShortcutRegistry 同键覆盖语义）。
    def register_global_hotkeys
      Emerald.hotkey.register('meta+w') { close_active_window }
      (1..9).each { |n| Emerald.hotkey.register("meta+#{n}") { focus_window_at(n) } }
    end

    # ── 应用启动 / 关闭（事件回调专用入口，D2）────────────

    # 启动应用并开窗：registry 只建实例（D3），开窗归 shell——
    # 单例复用：窗口已注册则直接返回已有实例（registry 已 focus），不重复 open。
    def launch_app(id, **argv)
      inst = @registry.launch(id, **argv)
      return inst if @wm.windows.include?(inst.win_id)

      @wm.open(inst.win_id, title: inst.class.app_title, geometry: geometry_for(inst))
      inst
    end

    # 关闭链路（D2/D4）：先注销窗口再回收实例；渲染侧一律以 wm.windows 守卫
    def close_window(win_id)
      @wm.close(win_id)
      @registry.dispose(win_id)
    end

    # 文件打开路由（services[:open_file] 的实体）：.emz → 安装器；命中注册
    # 类型 → 启动对应应用（argv 带 path）；未命中 → 警告通知
    def open_file_with(path)
      return install_vfs_emz(path) if path.end_with?('.emz')

      app_id = @router.app_for(path)
      if app_id
        launch_app(app_id, path: path)
      else
        @notify.push('没有可打开此类型文件的应用', kind: :warning)
        nil
      end
    end

    # 级联几何：default_geometry 块求值；同应用多实例按存活序号（0 起）
    # x/y 各 +24 级联偏移
    def geometry_for(inst)
      klass = inst.class
      base = klass.default_geometry ? klass.default_geometry.call : FALLBACK_GEOMETRY
      seq = @registry.each_running.count { |other| other.class.app_id == klass.app_id } - 1
      offset = [seq, 0].max * CASCADE_OFFSET
      { x: base[:x] + offset, y: base[:y] + offset, w: base[:w], h: base[:h] }
    end

    # ── 全局快捷键处理器（Emerald.hotkey 回调）────────────

    # meta+w：激活窗口 = z 序（order）最后一个非最小化窗
    def close_active_window
      active = @wm.windows.reverse.find { |id| !@wm.minimized?(id) }
      close_window(active) if active
    end

    # meta+1..9：聚焦窗口列表第 N 个（越界忽略）
    def focus_window_at(n)
      id = @wm.windows[n - 1]
      @wm.focus(id) if id
    end

    # window_key 接线：scope 取激活窗所属应用的 app_id（查不到回退 :global；
    # hotkey 内部先查 scope 表再回退全局表）。chord_for 兼容 citrine
    # KeyEvent 鸭子类型（key/meta?/ctrl?/alt?/shift?），零转换。
    def dispatch_hotkey(ev)
      Emerald.hotkey.dispatch(ev, scope: active_app_scope)
    end

    def active_app_scope
      top = @wm.windows.last
      inst = top && @registry.instance(top)
      inst ? inst.class.app_id : :global
    end

    # ── 视图组装（PLAN §3.1）────────────────────────────

    def view
      wallpaper
      icon_grid
      each_window_frame
      menubar
      Beryl::Taskbar.new(wm: @wm).view
      tray
      toast_stack
    end

    # 壁纸层：铺满桌面的最底级（--wallpaper 由 Theme 写入 :root）
    def wallpaper
      box(css_class: 'desktop-wallpaper',
          style: { position: 'fixed', inset: '0', background: 'var(--wallpaper)', z_index: 0 })
    end

    # 桌面图标网格（PLAN §3.7）：注册表应用（注册序）+ VFS /Desktop 文件条目；
    # v1 固定网格自动布局（拖拽换位不做），单击选中、双击启动
    def icon_grid
      box(css_class: 'icon-grid') do
        @registry.apps.each { |app| app_icon(app) }
        desktop_entries.each { |node| file_icon(node) }
      end
    end

    # /Desktop 目录条目（只读视图）；watch 信号建立订阅——目录自身或直接
    # 子级变更（拖入/删除文件）时本块重跑刷新图标
    def desktop_entries
      @vfs.watch(DESKTOP_DIR).get
      @vfs.list(DESKTOP_DIR)
    rescue Emerald::VFS::NotFound
      []
    end

    def app_icon(app)
      key = "app:#{app[:id]}"
      icon_tile(key, glyph: app[:icon].to_s, name: app[:title].to_s,
                on_open: -> { launch_app(app[:id]) })
    end

    def file_icon(node)
      key = "file:#{node.name}"
      icon_tile(key, glyph: '📄', name: node.name,
                on_open: -> { @services[:open_file].call("#{DESKTOP_DIR}/#{node.name}") })
    end

    # 图标块：纵向（图形/emoji + 文字），单击选中（受控选择集）、双击启动
    def icon_tile(key, glyph:, name:, on_open:)
      box(css_class: icon_tile_class(key),
          on_click: ->(_e) { self.selected_icons = [key] },
          on_dblclick: on_open) do
        box(css_class: 'd-icon-glyph') { glyph }
        label(css_class: 'd-icon-name') { name }
      end
    end

    def icon_tile_class(key)
      selected_icons.include?(key) ? 'd-icon is-selected' : 'd-icon'
    end

    # 窗口渲染循环（D3 插槽模式 + D4 条件渲染）：app 实例生命周期归 registry，
    # 渲染一律以 wm.windows 成员表为准——✕ 注销后无守卫的 frame 会 raise
    # 并把任务栏连带搞崩（beryl 踩坑 §8）
    # 窗口渲染循环（D3 插槽模式 + D4 条件渲染）：app 实例生命周期归 registry，
    # 渲染一律以 wm.windows 成员表为准——✕ 注销后无守卫的 frame 会 raise
    # 并把任务栏连带搞崩（beryl 踩坑 §8）。
    # 开头必须无条件读一次 windows 信号建立订阅：mount 时无存活实例的话，
    # 循环体不会执行、信号未被读，之后 launch/close 都不会触发本块重渲染
    #（E7 浏览器验收发现：窗口注册成功但 DOM 永不出现在启动后的首次渲染）。
    def each_window_frame
      wins = @wm.windows
      @registry.each_running do |inst|
        next unless wins.include?(inst.win_id)

        @wm.frame(inst.win_id, content: -> { inst.view },
                  on_close: -> { close_window(inst.win_id) }).view
      end
      nil
    end

    # 菜单栏（beryl F4 受控开合）：「应用」= 注册表启动器；「桌面」= 暗色主题
    # checked 切换 + 关于
    def menubar
      Beryl::MenuBar.new(menus: menubar_data, viewport: current_viewport,
                         open_index: signal(:menu_open)).view
    end

    def menubar_data
      [
        { label: '应用', items: @registry.apps.map { |app|
          { label: app[:title], action: -> { launch_app(app[:id]) } } } },
        { label: '桌面', items: [
          { label: '暗色主题', checked: dark_theme?, action: -> { toggle_theme } },
          { separator: true },
          { label: '关于 Emerald OS', action: -> { launch_app(:about) } },
        ] },
      ]
    end

    def dark_theme?
      @settings.get(:theme) == :dark
    end

    def toggle_theme
      @settings.set(:theme, dark_theme? ? :light : :dark)
    end

    # 托盘：右侧固定条——时钟（30s 走字）+ 通知计数角标
    def tray
      box(css_class: 'tray') do
        label(css_class: 'tray-clock') { clock }
        box(css_class: 'tray-badge') { @notify.count.to_s } if @notify.count.positive?
      end
    end

    # Toast 堆叠（PLAN §3.5）：auto_dismiss 到期按序号 dismiss
    def toast_stack
      @notify.each do |note, i|
        Beryl::Toast.new(msg: note['msg'], kind: note['kind'], duration_ms: 3000,
                         on_expire: -> { @notify.dismiss(i) }).view
      end
    end

    # ── 生命周期与订阅 ────────────────────────────────────

    # 主题重应用（watch 订阅）：theme/accent/density 任一变化重写 CSS 变量
    def reapply_theme
      Emerald::Theme.apply(@settings.get(:theme), accent: @settings.get(:accent),
                           density: @settings.get(:density))
    end

    # 托盘时钟：挂载即走字一次，之后每 30s 更新（Beryl::Timer 一次性语义，
    # tick 内重排）。CRuby 下 Timer 无后端时 after 返回 nil——安全跳过。
    def start_clock
      tick_clock
    end

    def tick_clock
      self.clock = current_time
      @clock_timer = Beryl::Timer.after(CLOCK_INTERVAL_MS) { tick_clock }
    end

    def stop_clock
      Beryl::Timer.cancel(@clock_timer)
      @clock_timer = nil
    end

    def current_time
      Time.now.strftime('%H:%M')
    end

    # 视口跟踪（PLAN §3.1）：resize 事件回调里写 wm.viewport（不在 view 里——F6）
    def track_viewport
      return unless defined?(Opal)

      @resize_listener = ->(_raw) { @wm.viewport = current_viewport }
      Native(`window`).addEventListener('resize', @resize_listener)
    end

    def untrack_viewport
      return unless defined?(Opal) && @resize_listener

      Native(`window`).removeEventListener('resize', @resize_listener)
      @resize_listener = nil
    end

    # Opal 下取真实视口，CRuby 测试给固定值
    def current_viewport
      defined?(Opal) ? { w: `window.innerWidth`, h: `window.innerHeight` } : { w: 1280, h: 800 }
    end
  end
end

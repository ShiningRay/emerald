# frozen_string_literal: true

module Emerald
  # 服务运行时（PLAN §3.9 Service/View 双子——ServiceHub 正式化的第一步）：
  # 把桌面外壳启动序列里与桌面无关的服务构造抽出来，供 DesktopShell 与
  # Standalone 独立宿主共用同一构造（独立宿主与桌面宿主同源，行为零分叉）。
  #
  # 构造顺序对齐 DesktopShell 原启动序列：storage → SettingsStore（同表默认值，
  # 首渲染前 load 防主题闪变）→ VFS → NotificationCenter / Clipboard /
  # FileTypeRouter（.txt/.md/.rb → :editor）→ 组装 services Hash → apply_theme。
  #
  # 纯 CRuby 可测（beryl F5）：本文件不含任何 Opal/JS 代码；
  # storage 默认按环境选择是唯一的环境分支（defined?(Opal) 守卫）。
  class Runtime
    # 设置项默认值（docs/PLAN.md §3.4；wallpaper 预设留待 Settings 应用消费）。
    # 自 DesktopShell 上提至此（shell 引用本常量），两宿主共用同一张默认表。
    DEFAULT_SETTINGS = {
      theme: :dark, accent: '#4f8cff', wallpaper: :aurora, density: :comfortable
    }.freeze

    # services 键集：:storage :vfs :settings :notify :clipboard :router。
    # 注意 :launcher/:apps/:open_file 是桌面 shell 在 services 建好之后才注入的
    # （AppRegistry 与开窗语义归 shell），Runtime 不感知、不代建。
    attr_reader :storage, :services

    def initialize(storage: nil)
      @storage = storage || default_storage
      @settings = Emerald::SettingsStore.new(storage: @storage, defaults: DEFAULT_SETTINGS)
      @settings.load
      @vfs = Emerald::VFS.new(storage: @storage)
      @notify = Emerald::NotificationCenter.new(limit: 5)
      @clipboard = Emerald::Clipboard.new
      @router = build_router
      @services = { storage: @storage, vfs: @vfs, settings: @settings,
                    notify: @notify, clipboard: @clipboard, router: @router }
      apply_theme
    end

    # 读访问器：与 services 里对应键是同一对象
    def vfs = @vfs

    def settings = @settings

    def notify = @notify

    def clipboard = @clipboard

    def router = @router

    # 引导单个应用实例：argv 赋值 → boot(services)（ctx 即本 Runtime 的
    # services Hash，PLAN §3.2 R1/R3）；返回实例本身便于链式使用。
    def boot_app(app_instance, argv: {})
      app_instance.argv = argv
      app_instance.boot(@services)
      app_instance
    end

    # 首渲染前应用主题（防闪变，对齐 DesktopShell 原行为）；
    # CRuby 下返回应写入的 CSS 变量表（Theme.apply 契约），Opal 下另写 :root。
    def apply_theme
      Emerald::Theme.apply(@settings.peek(:theme), accent: @settings.peek(:accent),
                           density: @settings.peek(:density))
    end

    private

    # storage 为 nil 时按环境选默认：Opal（浏览器）→ localStorage；
    # 否则 → 内存后端。独立宿主与桌面宿主共用同一构造。
    def default_storage
      defined?(Opal) ? Emerald::Storage::LocalStorage.new : Emerald::Storage::Memory.new
    end

    # 文件类型路由：.txt/.md/.rb → 编辑器（FileTypeRouter 纯服务，见 router.rb）。
    # 原 DesktopShell#build_router 下提至此。
    def build_router
      Emerald::FileTypeRouter.new.tap do |router|
        %w[.txt .md .rb].each { |ext| router.register(ext, :editor) }
      end
    end
  end
end

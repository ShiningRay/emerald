# frozen_string_literal: true

module Emerald
  # Service/View 双子架构的 Service 半边（docs/PLAN.md §3.9）：无 UI 逻辑，
  # 生命周期跟激活事件走、与窗口开关无关。
  #
  # 激活声明存类实例变量——子类各自独立、父类声明不下渗，未声明的子类
  # 读到默认空声明（VS Code 语义：每个包只为自己声明激活事件）。
  #
  # 覆写 activate/deactivate 须 super：激活标记由基类维护，是 ServiceHub
  # 幂等激活的事实源。
  class Service
    class << self
      # 类级声明宏：on_command 命令 id 数组、on_file_type 扩展名数组
      # （归一小写带点）、on_startup 布尔；一次调用即一份完整声明。
      def activation(on_command: [], on_file_type: [], on_startup: false)
        @on_command = Array(on_command).map(&:to_s)
        @on_file_type = Array(on_file_type).map { |ext| normalize_ext(ext) }
        @startup = on_startup ? true : false
        self
      end

      # 声明快照 { on_command:, on_file_type:, startup: }（未声明的键给默认值）
      def activation_events
        {
          on_command: (@on_command || []).dup,
          on_file_type: (@on_file_type || []).dup,
          startup: @startup == true
        }
      end

      private

      # '.TXT' → '.txt'，'txt' → '.txt'
      def normalize_ext(ext)
        key = ext.to_s.downcase
        key.start_with?('.') ? key : ".#{key}"
      end
    end

    # ── 子类追踪（包内 Service 装载：AppHost 求值 entry 后捕获其中新定义的
    # 服务类，DesktopShell 据此注册 ServiceHub）────────────────────────
    # 全部 Emerald::Service 子类，插入序 = 定义序；对齐 Emerald::App 的
    # app_subclasses 写法（citrine/beryl 均未定义 inherited，挂接安全，
    # 仍调 super 保持可叠加）。恒以基类接收者查询（Emerald::Service.service_subclasses）。
    class << self
      def service_subclasses
        @service_subclasses ||= []
      end

      def inherited(subclass)
        service_subclasses << subclass
        super
      end
    end

    def activate(ctx)
      @ctx = ctx
      @activated = true
      self
    end

    # 默认只做生命周期簿记（清激活标记），子类的资源清理在覆写里做（须 super）
    def deactivate
      @ctx = nil
      @activated = false
      nil
    end

    def activated?
      @activated == true
    end
  end

  # Service 容器：按激活事件把服务拉起来（幂等）、按注册逆序关停。
  # activate_* 返回本次新激活实例数组，调用方（shell）拿它决定要不要弹 UI。
  class ServiceHub
    def initialize
      @services = [] # 注册序实例
    end

    # service 可传实例或类（类则 hub 内 .new）；同一实例/类重复注册 fail fast
    def register(service)
      inst =
        if service.is_a?(Class)
          raise ArgumentError, "服务 #{service} 已注册" if @services.any? { |s| s.class == service }

          service.new
        else
          raise ArgumentError, "服务 #{service.class} 实例已注册" if @services.include?(service)

          service
        end
      @services << inst
      self
    end

    # on_command 命中 cmd_id 的未激活服务全部激活（幂等），返回本次新激活数组
    def activate_for_command(cmd_id, ctx)
      id = cmd_id.to_s
      activate_matching(ctx) { |events| events[:on_command].any? { |c| c.to_s == id } }
    end

    # on_file_type 命中 ext 的未激活服务全部激活；ext 归一同声明侧（'.TXT'→'.txt'，无点补点）
    def activate_for_file_type(ext, ctx)
      key = normalize_ext(ext)
      activate_matching(ctx) { |events| events[:on_file_type].any? { |e| e == key } }
    end

    # startup 声明为 true 的全部激活（幂等），返回本次新激活数组
    def activate_startup(ctx)
      activate_matching(ctx) { |events| events[:startup] }
    end

    # 按注册逆序关停所有已激活服务（activated? 归 false），之后可重新 activate
    def deactivate_all
      @services.reverse_each { |svc| svc.deactivate if svc.activated? }
      self
    end

    # 注册序实例数组快照
    def services
      @services.dup
    end

    private

    def activate_matching(ctx)
      newly = []
      @services.each do |svc|
        next if svc.activated?
        next unless yield(svc.class.activation_events)

        svc.activate(ctx)
        newly << svc
      end
      newly
    end

    # '.ZIP' → '.zip'，'zip' → '.zip'
    def normalize_ext(ext)
      key = ext.to_s.downcase
      key.start_with?('.') ? key : ".#{key}"
    end
  end
end

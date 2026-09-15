# frozen_string_literal: true

module Emerald
  # 独立宿主（PLAN §3.9 双子结构的首个独立消费者）：让 Emerald 应用脱离
  # 桌面外壳单独运行——自带一套 Runtime 服务（storage/settings/vfs/notify/
  # clipboard/router），把 app.view 直接铺进满视口容器，并接管 Toast 堆叠。
  #
  #   host = Emerald::Standalone.boot(Emerald::Apps::About)  # 传类：内部 new + 引导
  #   host = Emerald::Standalone.boot(app_instance)          # 传实例：argv 已有则不覆盖
  #   Beryl::Renderer.mount_at('app', host)                  # 宿主是 Citrine::Component
  #
  # 纯 CRuby 可渲染（beryl F5）：Citrine.render 不炸，Opal 代码全在下游
  # 服务的 defined?(Opal) 守卫里，本文件零平台分支。
  class Standalone < Citrine::Component
    attr_reader :runtime, :app, :notify

    # 入口：传 App 类（内部 Runtime.new + 类.new + boot_app）或已建实例
    # （已 boot 的不重复引导；未 boot 的保留其现有 argv）。
    def self.boot(target)
      new(target)
    end

    def initialize(target)
      super()
      @runtime = Emerald::Runtime.new
      @notify = @runtime.notify
      @app = boot_target(target)
    end

    # 满视口容器（width/height 100%、overflow auto、position relative、
    # background 'var(--bg)'）包两块：应用内容 + Toast 堆叠
    def view
      box(css_class: 'standalone-host',
          style: { width: '100%', height: '100%', overflow: 'auto',
                   position: 'relative', background: 'var(--bg)' }) do
        app_view
        toast_stack
      end
    end

    private

    def boot_target(target)
      inst = target.is_a?(Class) ? target.new : target
      return inst if inst.ctx # 已引导的实例：不重复 boot（argv 更不动）

      @runtime.boot_app(inst, argv: inst.argv || {})
    rescue StandardError => e
      @notify.push("应用启动失败：#{e.message}", kind: :error)
      nil
    end

    # 应用内容；app 为 nil（引导失败）时渲染「应用不可用」占位
    def app_view
      app ? app.view : label(css_class: 'standalone-missing') { '应用不可用' }
    end

    # Toast 堆叠（与 shell 同语义，PLAN §3.5）：auto_dismiss 到期按序号 dismiss
    def toast_stack
      notify.each do |note, i|
        Beryl::Toast.new(msg: note['msg'], kind: note['kind'], duration_ms: 3000,
                         on_expire: -> { notify.dismiss(i) }).view
      end
    end
  end
end

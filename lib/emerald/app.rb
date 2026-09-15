# frozen_string_literal: true

# E2 · 应用框架（docs/PLAN.md §3.2 + 决策 D2/D3）：
#   Emerald::App         —— 应用基类：manifest 四宏（类级声明）+ boot(ctx) 生命周期，
#                           窗口内容由子类 #view 实现（挂进 frame 的 content 槽，beryl F2）
#   Emerald::AppRegistry —— 纯服务（非组件）：注册/启动/回收，集中持有
#                           WindowManager 的变更入口（launch/dispose 带 F6 同款守卫）
#
# 纯 CRuby 可测（beryl F5）：本文件不含任何 Opal/JS 代码。

module Emerald
  # 应用基类。< Citrine::Component：app 内部仍可用全部元素 DSL 与 beryl 组件。
  class App < Citrine::Component
    class << self
      # 类级 manifest 表（id/title/icon/singleton/default_geometry）。
      # 首次访问时 dup 父类一份再改写：子类声明互不染（类实例变量继承陷阱，
      # 对齐 citrine component.rb 的 prop_defs 写法）。
      def manifest
        @manifest ||= if superclass.respond_to?(:manifest)
                        superclass.manifest.dup
                      else
                        { id: nil, title: nil, icon: nil, singleton: false, geometry: nil }
                      end
      end

      # 应用标识：注册表键、窗口 id 前缀。Symbol/String 均可，归一为 Symbol。
      def app_id(v = nil)
        v.nil? ? manifest[:id] : manifest[:id] = v.to_sym
      end

      # 展示名（菜单栏/启动器/任务栏用）
      def app_title(v = nil)
        v.nil? ? manifest[:title] : manifest[:title] = v
      end

      # 图标：Beryl::Icon 名或 emoji
      def app_icon(v = nil)
        v.nil? ? manifest[:icon] : manifest[:icon] = v
      end

      # 单例应用：重复 launch = focus 已有窗口（默认 false）
      def singleton(v = nil)
        v.nil? ? manifest[:singleton] : manifest[:singleton] = v
      end

      # 默认几何：块返回 { x:, y:, w:, h: }；无块时读取（未声明为 nil）
      def default_geometry(&blk)
        blk ? manifest[:geometry] = blk : manifest[:geometry]
      end
    end

    attr_reader :ctx, :win_id
    # argv：launch(app_id, **argv) 注入的启动参数；写入口归 AppRegistry 内部使用
    attr_accessor :argv

    # 启动钩子：默认实现存服务表（ctx 即注册时注入的 services）。
    # 子类覆写须 super（或自行存 @ctx）。
    def boot(ctx)
      @ctx = ctx
    end

    # view 由子类实现（基类 Citrine::Component#view 已 raise NotImplementedError）
  end

  # 应用注册表（纯服务，非组件）：
  #   - 窗口与 app 实例的绑定、单例/多实例、启动参数、退出回收
  #   - WindowManager 的全部变更权收于此（D2），launch/dispose 禁止在
  #     view/Effect 内调用（beryl F6：set 会同步重入渲染）
  class AppRegistry
    def initialize(services: {})
      @services = services
      @manifests = {}                          # app_id(Symbol) => App 类，插入序即注册序
      @instances = {}                          # win_id(Symbol) => 实例，插入序即启动序
      @by_app = Hash.new { |h, k| h[k] = [] }  # app_id => [win_id, ...]（存活实例，启动序）
    end

    # Beryl::WindowManager，渲染器外赋值；可能为 nil（未注入时单例命中只返回实例）
    attr_writer :wm

    # 按 manifest 的 app_id 注册。重复 id / 未声明 app_id 都当场报错（fail fast）。
    def register(klass)
      id = klass.app_id
      raise ArgumentError, "应用类 #{klass} 未声明 app_id（先调 app_id :xxx）" if id.nil?
      raise ArgumentError, "应用 #{id} 已注册（#{@manifests[id]}），id 必须唯一" if @manifests.key?(id)

      @manifests[id] = klass
      self
    end

    # 启动应用 => App 实例。
    # 单例命中：已注入 wm 则 focus 已有窗口，返回已有实例；
    # 否则 klass.new → 注入 win_id/argv → boot(ctx) → 登记实例。
    # ctx 即 initialize 注入的 services（同一对象引用）。
    def launch(app_id, **argv)
      assert_outside_effect!(:launch)
      id = normalize_id(app_id)
      klass = fetch_class!(id)

      live = @by_app[id]
      if live.any? && klass.singleton
        @wm&.focus(live.first)
        return @instances[live.first]
      end

      win_id = win_id_for(id)
      inst = klass.new
      # win_id 是只读 attr_reader：注册表内部经 ivar 注入（实例的启动身份）
      inst.instance_variable_set(:@win_id, win_id)
      inst.argv = argv
      inst.boot(@services)
      @instances[win_id] = inst
      @by_app[id] << win_id
      inst
    end

    # 该应用是否有存活实例
    def running?(app_id)
      @by_app[normalize_id(app_id)].any?
    end

    # 按窗口 id 取实例（未启动/已回收 => nil）
    def instance(win_id)
      @instances[normalize_id(win_id)]
    end

    # 按启动顺序遍历存活实例；无块返回 Enumerator
    def each_running(&block)
      return enum_for(:each_running) unless block

      @instances.each_value(&block)
    end

    # 仅注销实例，返回被注销的实例（窗口归 wm/shell 管——关闭链路先 wm.close
    # 再 dispose，见 PLAN §3.2）；未知 win_id 为 no-op（返回 nil）
    def dispose(win_id)
      assert_outside_effect!(:dispose)
      id = normalize_id(win_id)
      inst = @instances.delete(id)
      return nil unless inst

      @by_app[inst.class.app_id].delete(id)
      inst
    end

    # 下一次 launch 会得到的窗口 id（纯查询，不改状态）：
    #   单例 => :about；
    #   多实例 => 无存活时 :about（裸 id 即"第一扇窗"，与单例同构），
    #             否则 :"about#2"、:"about#3"…（per-app 自增序号，跳过仍存活的）
    def win_id_for(app_id)
      id = normalize_id(app_id)
      klass = fetch_class!(id)
      return id if klass.singleton

      live = @by_app[id]
      return id if live.empty?

      n = live.size + 1
      n += 1 while live.include?(:"#{id}##{n}")
      :"#{id}##{n}"
    end

    # 注册表快照：[{ id:, title:, icon: }]
    def apps
      @manifests.map do |id, klass|
        { id: id, title: klass.app_title, icon: klass.app_icon }
      end
    end

    private

    # 变更操作若在 Effect（view 渲染）内执行，注册表变更会同步触发订阅者重跑，
    # 造成无限递归；直接 fail fast，把问题暴露在写错的瞬间（对齐 beryl
    # WindowManager#assert_outside_effect! 的语义，PLAN 决策 D2）。
    def assert_outside_effect!(op)
      return unless Citrine::Effect.current

      raise ArgumentError,
            "AppRegistry##{op} 不能在 view/Effect 内调用：应用启动/销毁会同步变更" \
            "注册表并触发订阅者重跑。请从事件回调进入（事件回调里 Effect.current 为 nil）。"
    end

    def normalize_id(v)
      v.to_sym
    end

    def fetch_class!(id)
      @manifests.fetch(id) { raise ArgumentError, "未注册的应用: #{id}（先 AppRegistry#register）" }
    end
  end
end

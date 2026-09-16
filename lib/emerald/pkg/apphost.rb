# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  module Pkg
    # /Applications 扫描与源码应用装载（docs/PLAN.md §3.10；D11/D12）：
    # lock（installed.json）为扫描清单 → 读 entry 源码 → 编译缓存命中判定
    #（键 = 源码 sha256 + Opal 版本，SPEC「源码为正本、产物为可丢弃缓存」）→
    # 求值定义 App 子类 → 注册 AppRegistry（包内 Service 子类另经
    # defined_services 交给 shell 装载）。
    #
    # IO 边界全部注入（D5 同款，纯 CRuby 可测）：
    # - compiler: callable(ruby_source, app_id) → 可执行文本
    #   （浏览器 = opal-parser 懒加载 chunk 就绪后 Opal.compile；测试注入伪编译器）
    # - loader: callable(可执行文本)（浏览器 = eval 产物 JS；测试 = eval Ruby 源码）
    # - bundled 预装应用（类已随系统 bundle 定义）跳过求值；Editor 改源码 →
    #   sha 变化自动重编，reload 走 reopen 语义热更新类方法。
    #
    # 单应用失败绝不拖垮整机（PLAN §8：用户改坏 /Applications ≠ 系统崩）：
    # scan_one 逐条 rescue，结果进 reports 供 shell 通知。
    #
    # 多 App 包（AgentOS 桌面：1 个 Service + 4 个窗口 App）：entry 定义的
    # 全部 Emerald::App 子类一次注册（不再要求 app_id == 包 id），包 → App id
    # 的映射经 package_app_ids 供宿主接线贡献命令；entry 里定义的
    # Emerald::Service 子类经 defined_services 交给 shell 注册 ServiceHub
    # （宿主能力，包内不做自启 hack）。两张映射都留在进程内存里，reopen
    # （同进程重复 eval，inherited 不再触发）时据此回查上一次的类列表。
    class AppHost
      APPS_DIR = '/Applications'
      CACHE_DIR = '/System/Cache'

      attr_reader :reports
      # 本轮 scan/reload 交付的 Service 子类：新定义的 + reopen（同进程重复
      # eval，不再触发 inherited）时按包 id 从内存映射回查的（scan/reload 开始
      # 即重置；求值失败的包不计入）。shell 据此注册 ServiceHub（其 register
      # 幂等，重复交付无副作用）。
      attr_reader :defined_services
      # 编译/加载边界可后置注入（shell 测试注入伪实现；浏览器由 shell 构造时给）
      attr_accessor :compiler, :loader

      def initialize(vfs:, lock:, compiler: nil, loader: nil, opal_version: self.class.default_opal_version)
        @vfs = vfs
        @lock = lock
        @compiler = compiler
        @loader = loader
        @opal_version = opal_version
        @reports = []
        @defined_services = []
        @package_apps = {} # 包 id(String) => [App 类]（reopen 场景的回查映射）
        @package_services = {} # 包 id(String) => [Service 类]（同上，供 defined_services 回查）
      end

      # 包 id → 该包 entry 定义的 App id 列表（顺序 = entry 里的定义顺序）。
      # 宿主接线用：多 App 包的包 id 不是任何 App 的 app_id，贡献命令须归约到
      # 包内窗口 App（shell 的 contributes 接线）。未装载过（bundled 跳过求值 /
      # 包不存在）的包返回 []，调用侧自行保底。
      def package_app_ids(id)
        @package_apps[id.to_s].to_a.map(&:app_id)
      end

      # 扫描全部已装应用并注册；返回 reports（shell 据此发通知）。
      def scan(registry)
        @reports = []
        @defined_services = []
        @lock.entries.each { |entry| scan_one(registry, entry) }
        @reports
      end

      # 单应用重载（Editor 改源码保存后的 dogfood 通道）：绕过「同 id 已注册」
      # 与 bundled 跳过，重新求值（reopen 语义热更新类方法，已注册的类对象
      # 原地更新，下一次 launch 即新行为）。
      def reload(registry, id)
        entry = @lock.get(id)
        return report(id, :skipped, '未安装') unless entry

        @defined_services = []
        scan_one(registry, entry, force: true)
      end

      # 强制失效缓存（下次 scan/reload 必重编；正常路径下 sha 变化自动失效，
      # 此 API 留给「重置应用」类系统操作）。=> true 有缓存被清
      def invalidate_cache(id)
        had = @vfs.exist?(cache_js_path(id)) || @vfs.exist?(cache_meta_path(id))
        @vfs.delete(cache_js_path(id)) if @vfs.exist?(cache_js_path(id))
        @vfs.delete(cache_meta_path(id)) if @vfs.exist?(cache_meta_path(id))
        had
      end

      # Opal 版本号（缓存键的一半）：浏览器取运行时，CRuby 取 gem，取不到 'unknown'
      def self.default_opal_version
        return `Opal.version || 'unknown'` if defined?(Opal)

        defined?(Opal::VERSION) ? Opal::VERSION : 'unknown'
      end

      private

      def scan_one(registry, entry, force: false)
        id = entry['id']
        return report(id, :skipped, 'bundled 预装（类已随系统 bundle）') if entry['bundled'] && !force
        return report(id, :skipped, '非 app 包') unless entry['kind'] == 'app'

        # 应用目录里的 manifest.json 是扫描时的事实源（用户可能改过包内容）
        manifest = Manifest.parse(@vfs.read("#{APPS_DIR}/#{id}/manifest.json"))
        if !force && registered?(registry, id)
          return report(id, :skipped, '同 id 已注册（内置优先）')
        end

        src = @vfs.read("#{APPS_DIR}/#{id}/#{manifest.entry}")
        sha = Sha256.hexdigest(src.b.bytes)
        meta = read_meta(id)
        if meta && meta['source_sha256'] == sha && meta['opal_version'] == @opal_version
          executable = @vfs.read(cache_js_path(id))
          detail = '缓存命中'
        else
          executable = compile!(id, src, sha)
          detail = '编译'
        end
        klasses = evaluate!(executable, id)
        # 多 App 包逐个注册；同 app_id 已注册的跳过（内置优先 / 前一轮已注册）
        klasses.each { |klass| registry.register(klass) unless registered?(registry, klass.app_id) }
        report(id, :registered, detail)
      rescue StandardError => e
        # 单应用失败不拖垮整机（坏包/坏源码/缺编译器都到这）；本次失败的
        # 写入不破坏既有缓存（compile! 抛错时新产物尚未落盘）
        report(id, :failed, "#{e.class}: #{e.message}")
      end

      def compile!(id, src, sha)
        raise 'AppHost 需要注入 compiler（浏览器侧为 opal-parser 懒加载 + Opal.compile）' unless @compiler

        js = @compiler.call(src, id)
        @vfs.write(cache_js_path(id), js)
        @vfs.write(cache_meta_path(id),
                   Json.generate('id' => id, 'source_sha256' => sha,
                                 'opal_version' => @opal_version, 'compiled_at' => timestamp))
        js
      end

      # 求值可执行文本 → 本次装载的 App 类列表。
      # 注册「entry 定义的全部新 App 子类」（多 App 包：单次求值收齐所有窗口
      # App；单应用包即长度 1）——不再要求 app_id 与包 id 一致，包 id 只是
      # 安装/卸载/缓存的键。reopen（reload）不产生新子类，按包 id 从内存映射
      # 回查上一次的类列表（进程内存，非持久化）。
      # 同时收集本次交付的 Service 子类（defined_services 的填充点）。
      def evaluate!(executable, id)
        raise 'AppHost 需要注入 loader' unless @loader

        apps_before = Emerald::App.app_subclasses.dup
        services_before = Emerald::Service.service_subclasses.dup
        @loader.call(executable)
        fresh = Emerald::App.app_subclasses - apps_before
        klasses = fresh.empty? ? @package_apps[id.to_s].to_a : fresh
        raise Json::Invalid, "entry 未定义 Emerald::App 子类（包 #{id}）" if klasses.empty?

        @package_apps[id.to_s] = klasses
        @defined_services += package_services(id.to_s, services_before)
        klasses
      end

      # 本次求值交付的 Service 子类：新定义的；reopen（同进程重复 eval，
      # inherited 不再触发）则按包 id 回查上一次的类列表——照 @package_apps 的
      # 做法，否则 reload 后 defined_services 恒为空、包内 Service 漏装。两边都
      # 空则记空表（包内确实没有服务类）。
      def package_services(id, services_before)
        fresh = Emerald::Service.service_subclasses - services_before
        services = fresh.empty? ? @package_services[id].to_a : fresh
        @package_services[id] = services
        services
      end

      def registered?(registry, id)
        registry.apps.any? { |a| a[:id] == id.to_sym }
      end

      def read_meta(id)
        path = cache_meta_path(id)
        return nil unless @vfs.exist?(path)

        Json.parse(@vfs.read(path))
      rescue Json::Invalid
        nil
      end

      def cache_js_path(id)
        "#{CACHE_DIR}/#{id}.js"
      end

      def cache_meta_path(id)
        "#{CACHE_DIR}/#{id}.json"
      end

      def report(id, status, message = nil)
        r = { id: id, status: status, message: message }
        @reports << r
        r
      end

      def timestamp
        Time.now.strftime('%Y-%m-%dT%H:%M:%S')
      end
    end
  end
end

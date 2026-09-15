# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'emerald'

# E7 · AppHost（docs/PLAN.md §3.10）：/Applications 扫描 → 编译缓存 →
# 求值注册。编译/加载边界注入伪实现（恒等编译 + eval），聚焦缓存与生命周期语义。
class PkgAppHostTest < Minitest::Test
  A = Emerald::Pkg::AppHost

  MANIFEST = {
    'spec' => 1, 'kind' => 'app', 'id' => 'hello', 'name' => 'Hello',
    'version' => '0.1.0', 'entry' => 'src/main.rb',
  }.freeze

  def setup
    Beryl::Timer.backend = ->(_ms, blk) { blk.call }
    Beryl::Timer.cancel_backend = ->(_h) {}
    @vfs = Emerald::VFS.new(storage: Emerald::Storage::Memory.new)
    @lock = Emerald::Pkg::Lock.new(@vfs)
    @registry = Emerald::AppRegistry.new
    @opal = '1.8.3'
    install_hello
  end

  def teardown
    Beryl::Timer.backend = nil
    Beryl::Timer.cancel_backend = nil
    remove_hello!
  end

  def remove_hello!
    Object.send(:remove_const, :Hello) if Object.const_defined?(:Hello, false)
  end

  def install_hello(src = default_src, manifest = MANIFEST)
    files = { 'manifest.json' => JSON.generate(manifest), 'src/main.rb' => src }
    Emerald::Pkg::Installer.new(vfs: @vfs, lock: @lock).install_dir('./hello', files)
  end

  def default_src
    "class Hello < Emerald::App\n  app_id :hello\nend\n"
  end

  def new_host(opal_version: @opal, compiler: default_compiler, loader: default_loader)
    A.new(vfs: @vfs, lock: @lock, compiler: compiler, loader: loader, opal_version: opal_version)
  end

  def default_compiler
    ->(src, _id) { src } # 伪编译器：可执行文本 = Ruby 源码
  end

  def default_loader
    ->(text) { eval(text, TOPLEVEL_BINDING.dup) }
  end

  def last_report
    @host.reports.last
  end

  # ── 扫描注册 ───────────────────────────────────────
  def test_scan_compiles_and_registers
    @host = new_host
    @host.scan(@registry)
    assert last_report
    assert_equal :registered, last_report[:status]
    assert_equal '编译', last_report[:message]
    assert @registry.apps.any? { |a| a[:id] == :hello }
    assert @vfs.exist?('/System/Cache/hello.js')
    meta = JSON.parse(@vfs.read('/System/Cache/hello.json'))
    assert_equal '1.8.3', meta['opal_version']
  end

  def test_cache_hit_on_unchanged_source
    @host = new_host
    @host.scan(@registry)
    remove_hello! # 模拟重启：类消失，缓存仍在

    fresh_registry = Emerald::AppRegistry.new
    host2 = new_host
    host2.scan(fresh_registry)
    assert_equal :registered, host2.reports.last[:status]
    assert_equal '缓存命中', host2.reports.last[:message]
    assert fresh_registry.apps.any? { |a| a[:id] == :hello }
  end

  def test_cache_invalidated_when_source_changes
    @host = new_host
    @host.scan(@registry)
    @vfs.write('/Applications/hello/src/main.rb', "class Hello < Emerald::App\n  app_id :hello\n  # v2\nend\n")

    remove_hello!
    fresh_registry = Emerald::AppRegistry.new
    host2 = new_host
    host2.scan(fresh_registry)
    assert_equal '编译', host2.reports.last[:message]
    meta = JSON.parse(@vfs.read('/System/Cache/hello.json'))
    refute_equal Emerald::Pkg::Sha256.hexdigest(default_src.b.bytes), meta['source_sha256']
  end

  def test_cache_invalidated_when_opal_version_drifts
    @host = new_host
    @host.scan(@registry)
    Object.send(:remove_const, :Hello)

    fresh_registry = Emerald::AppRegistry.new
    host2 = new_host(opal_version: '9.9.9')
    host2.scan(fresh_registry)
    assert_equal '编译', host2.reports.last[:message]
  end

  def test_reload_reopens_class_with_new_methods
    @host = new_host
    @host.scan(@registry)
    @vfs.write('/Applications/hello/src/main.rb',
               "class Hello < Emerald::App\n  app_id :hello\n  def ping; :pong; end\nend\n")

    report = @host.reload(@registry, 'hello')
    assert_equal :registered, report[:status]

    inst = @registry.launch(:hello)
    assert_equal :pong, inst.ping # reopen 语义：已注册类对象原地更新
  end

  # ── 跳过与失败隔离 ─────────────────────────────────
  def test_bundled_entry_skipped
    manifest = Emerald::Pkg::Manifest.parse(JSON.generate(MANIFEST))
    src = Emerald::Pkg::Source.parse('./hello')
    @lock.add(manifest, source: src, content_sha256: 'x' * 64, bundled: true)
    @host = new_host
    @host.scan(@registry)
    assert_equal :skipped, last_report[:status]
    assert_empty @registry.apps
  end

  def test_non_app_kind_skipped
    # agent/skill 的 lock 记录不经 Installer（安装器拒装），直接造 lock 条目
    m = Emerald::Pkg::Manifest.parse(JSON.generate(MANIFEST.merge('kind' => 'skill')))
    @lock.add(m, source: Emerald::Pkg::Source.parse('./x'), content_sha256: 'a' * 64)
    @host = new_host
    @host.scan(@registry)
    assert_equal :skipped, last_report[:status]
    assert_empty @registry.apps
  end

  def test_same_id_already_registered_skipped_builtin_priority
    @registry.register(Class.new(Emerald::App) { app_id :hello })
    @host = new_host
    @host.scan(@registry)
    assert_equal :skipped, last_report[:status]
    assert_includes last_report[:message], '已注册'
  end

  def test_app_id_mismatch_fails_isolated
    install_hello("class Hello < Emerald::App\n  app_id :other\nend\n")
    @host = new_host
    @host.scan(@registry)
    assert_equal :failed, last_report[:status]
    assert_includes last_report[:message], '不一致'
    assert_empty @registry.apps # 失败不拖垮整机
  end

  def test_missing_compiler_fails_with_clear_message
    @host = A.new(vfs: @vfs, lock: @lock, loader: default_loader)
    @host.scan(@registry)
    assert_equal :failed, last_report[:status]
    assert_includes last_report[:message], 'compiler'
  end

  def test_invalidate_cache_removes_artifacts
    @host = new_host
    @host.scan(@registry)
    assert @host.invalidate_cache('hello')
    refute @vfs.exist?('/System/Cache/hello.js')
    refute @vfs.exist?('/System/Cache/hello.json')
  end

  # ── AppRegistry dispose → deactivate 链（§3.9 遗留修复）──
  def test_deactivate_runs_per_disposed_instance
    klass = Class.new(Emerald::App) do
      app_id :multi

      def deactivate
        @deactivated = true
      end

      def deactivated?
        @deactivated == true
      end
    end
    @registry.register(klass)
    a = @registry.launch(:multi)
    b = @registry.launch(:multi)
    @registry.dispose(a.win_id)
    assert a.deactivated? # 每个实例注销即触发（窗口关闭 = 实例终点）
    refute b.deactivated? # 其他实例不受牵连
    @registry.dispose(b.win_id)
    assert b.deactivated?
  end
end

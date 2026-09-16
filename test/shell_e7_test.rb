# frozen_string_literal: true

# E7 · 外壳接线（docs/PLAN.md §3.10）：预装 seed → /Applications 扫描 →
# 贡献点接线 → 安装/卸载/热更新。纯 CRuby：编译边界注入伪编译器（恒等 + eval）。
require 'minitest/autorun'
require 'json'
require 'zlib'
require 'emerald'

class ShellE7Test < Minitest::Test
  def setup
    @shell = Emerald::DesktopShell.new
    @shell.apphost.compiler = ->(src, _id) { src }
    @shell.apphost.loader = ->(text) { eval(text, TOPLEVEL_BINDING.dup) }
  end

  def teardown
    %i[ShE7App ShE7World ShE7Agent ShE7DeskService ShE7LateService].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
  end

  # ── 预装（内置应用 = 预装应用）───────────────────────
  def test_preinstalled_about_seeded_to_applications
    assert @shell.vfs.exist?('/Applications/about/manifest.json')
    assert @shell.vfs.exist?('/Applications/about/src/main.rb')
    entry = @shell.installer.lock.get('about')
    assert entry['bundled'], '预装应用应打 bundled 标记（开机不求值，D12）'
    assert_includes @shell.registry.apps.map { |a| a[:id] }, :about
  end

  def test_preinstalled_source_matches_bundle_class
    # 双形态同步纪律的兜底断言（见 lib/emerald/packages.rb 头注）
    assert_includes Emerald::Packages::ABOUT_MAIN_RB, 'app_id    :about'
    assert_equal :about, Emerald::Apps::About.app_id
    assert Emerald::Apps::About.singleton
  end

  def test_preinstalled_contributions_wired
    assert @shell.commands.command?('about.open'), 'manifest commands 应进命令注册表'
    @shell.commands.run('about.open')
    assert @shell.registry.running?(:about), '运行命令 = 打开应用（v1 归约语义）'
  end

  # ── .emz 安装（zip 管线）────────────────────────────
  def test_install_package_bytes_registers_and_caches
    bytes = build_zip('ShE7' => [
                        ['manifest.json', JSON.generate(e7_manifest)],
                        ['src/main.rb', "class ShE7App < Emerald::App\n  app_id :she7\nend\n"],
                      ])
    result = @shell.install_package_bytes('./she7.emz', bytes)
    assert_equal :installed, result[:status]
    assert_includes @shell.registry.apps.map { |a| a[:id] }, :she7
    assert @shell.vfs.exist?('/System/Cache/she7.js'), '编译产物应进缓存'
    assert @shell.notify.count.positive?, '安装结果应有通知'
  end

  def test_files_double_click_emz_installs
    bytes = build_zip('ShE7' => [
                        ['manifest.json', JSON.generate(e7_manifest)],
                        ['src/main.rb', "class ShE7App < Emerald::App\n  app_id :she7\nend\n"],
                      ])
    @shell.vfs.write('/Desktop/hello.emz', Emerald::Pkg::Bytes.to_latin1(bytes))
    @shell.open_file_with('/Desktop/hello.emz')
    assert_includes @shell.registry.apps.map { |a| a[:id] }, :she7
  end

  # ── Editor 改源码 → 热更新（dogfood 闭环）────────────
  def test_editor_source_save_hot_reloads
    install_she7("class ShE7App < Emerald::App\n  app_id :she7\n  def tag; :v1; end\nend\n")
    @shell.vfs.write('/Applications/she7/src/main.rb',
                     "class ShE7App < Emerald::App\n  app_id :she7\n  def tag; :v2; end\nend\n")

    @shell.on_app_source_saved('/Applications/she7/src/main.rb')

    inst = @shell.launch_app(:she7)
    assert_equal :v2, inst.tag, 'reopen 语义：已注册类原地更新'
  end

  def test_hot_reload_failure_keeps_previous_version_notified
    install_she7("class ShE7App < Emerald::App\n  app_id :she7\n  def tag; :v1; end\nend\n")
    @shell.vfs.write('/Applications/she7/src/main.rb', "class ShE7App < Emerald::App\n  app_id :broken\nend\n")

    @shell.on_app_source_saved('/Applications/she7/src/main.rb')

    inst = @shell.launch_app(:she7)
    assert_equal :v1, inst.tag, '重载失败保留上一好版本'
    assert @shell.notify.count.positive?
  end

  # 热更新路径也要挂包内 Service（与 install_and_register 一致）：改源码新增的
  # Service 子类在 reload 后进 hub 并按其激活声明激活
  def test_editor_source_save_registers_new_package_service
    install_desk_package
    @shell.vfs.write('/Applications/she7-desk/src/main.rb',
                     "#{desk_src}\n" \
                     "class ShE7LateService < Emerald::Service\n  activation on_startup: true\nend\n")

    @shell.on_app_source_saved('/Applications/she7-desk/src/main.rb')

    svc = @shell.hub.services.find { |s| s.class == ShE7LateService }
    refute_nil svc, '热更新新增的包内 Service 应注册进 ServiceHub'
    assert svc.activated?, 'on_startup 声明随装载激活'
  end

  # ── 卸载 ───────────────────────────────────────────
  def test_uninstall_closes_windows_and_removes_package
    install_she7
    @shell.launch_app(:she7)
    assert @shell.registry.running?(:she7)

    assert @shell.uninstall_package(:she7)

    refute @shell.registry.running?(:she7)
    refute @shell.vfs.exist?('/Applications/she7')
    refute @shell.installer.installed?(:she7)
    refute @shell.commands.command?('app.she7')
  end

  def test_uninstall_invalidates_compile_cache
    install_she7
    assert @shell.vfs.exist?('/System/Cache/she7.js')

    @shell.uninstall_package(:she7)

    refute @shell.vfs.exist?('/System/Cache/she7.js'), '卸载应清编译缓存'
    refute @shell.vfs.exist?('/System/Cache/she7.json')
  end

  # ── 多 App 包 + 包内 Service 装载（AgentOS 桌面形态）──
  def test_install_package_with_multiple_apps_registers_all
    install_desk_package
    ids = @shell.registry.apps.map { |a| a[:id] }
    assert_includes ids, :she7_world
    assert_includes ids, :she7_agent
    assert @shell.vfs.exist?('/System/Cache/she7-desk.js'), '多 App 包仍以包 id 为缓存键'
  end

  def test_package_startup_service_registered_and_activated_with_shell_ctx
    install_desk_package
    svc = @shell.hub.services.find { |s| s.class == ShE7DeskService }

    refute_nil svc, '包内 Service 应由宿主注册进 ServiceHub'
    assert svc.activated?, 'on_startup 声明的包内服务应随装载激活'
    assert_same @shell.services, svc.last_ctx, '激活 ctx 即 shell 服务表'
  end

  def test_register_package_services_is_idempotent
    install_desk_package
    @shell.register_package_services # 重复调用不得重复注册（hub 会 raise）
    assert_equal 1, @shell.hub.services.count { |s| s.class == ShE7DeskService }
  end

  # ── 贡献命令的多 App 包归约（SPEC §4.1）──────────────
  # 包 id 不是任何 App 的 app_id：命令须落到包内窗口 App，否则运行即「未注册的应用」
  def test_multi_app_package_command_opens_package_window
    install_desk_package
    assert @shell.commands.command?('she7-desk.open')

    @shell.commands.run('she7-desk.open')

    assert @shell.registry.running?(:she7_world), '缺省取包内首个 App（定义序）'
    assert_equal 1, @shell.wm.windows.size, '开出的窗口应已注册进窗口管理器'
  end

  def test_contributed_command_app_field_selects_window
    install_desk_package
    @shell.commands.run('she7-desk.agent')

    assert @shell.registry.running?(:she7_agent), 'cmd[:app] 显式指明优先于包内首个 App'
    refute @shell.registry.running?(:she7_world)
  end

  def test_command_app_field_pointing_nowhere_skipped_with_warning
    manifest = desk_manifest
    manifest['contributes']['commands'][1]['app'] = 'she7_nope'
    install_desk_package(manifest)

    refute @shell.commands.command?('she7-desk.agent'), '目标 App 未注册 → 命令不接线'
    assert @shell.commands.command?('she7-desk.open'), '同包其它命令不受牵连'
    assert notify_messages.any? { |m| m.include?('she7-desk.agent') }, '应发一条 warning'
  end

  # 包内一个 App 都没注册成功（entry 求值失败）：命令不接线 + warning，不抛错
  def test_command_without_any_registered_app_skipped_with_warning
    install_desk_package(desk_manifest, "# 没有 App 类\n")

    refute @shell.commands.command?('she7-desk.open')
    refute @shell.commands.command?('she7-desk.agent')
    assert notify_messages.any? { |m| m.include?('she7-desk.open') }, '应发一条 warning'
  end

  def notify_messages
    @shell.notify.each.map { |note, _i| note['msg'] }
  end

  # ── 开窗服务（包内 App 拉起兄弟窗口的能力面）──────────
  def test_launch_app_service_opens_window_and_forwards_argv
    install_she7("class ShE7App < Emerald::App\n  app_id :she7\n  def endpoint; argv[:endpoint]; end\nend\n")
    inst = @shell.services[:launch_app].call(:she7, { endpoint: 'observer' })

    assert_equal 'observer', inst.endpoint, 'argv Hash 应展开为关键字参数'
    assert @shell.registry.running?(:she7)
    assert_includes @shell.wm.windows, inst.win_id
  end

  def test_launch_app_service_defaults_to_empty_argv
    install_she7
    assert_equal({}, @shell.services[:launch_app].call(:she7).argv)
    assert @shell.registry.running?(:she7)
  end

  # ── git 导入（浏览器无 fetcher → 明确报错通知）───────
  def test_install_git_url_without_fetcher_notifies_error
    before = @shell.notify.count
    assert_nil @shell.install_git_url('git:https://github.com/u/repo')
    assert @shell.notify.count > before
  end

  # ── 夹具 ───────────────────────────────────────────
  def e7_manifest
    {
      'spec' => 1, 'kind' => 'app', 'id' => 'she7', 'name' => 'E7 应用',
      'version' => '0.1.0', 'entry' => 'src/main.rb',
      'contributes' => { 'commands' => [{ 'id' => 'she7.open', 'title' => '打开 E7' }] },
    }
  end

  def install_she7(src = "class ShE7App < Emerald::App\n  app_id :she7\nend\n")
    files = { 'manifest.json' => JSON.generate(e7_manifest), 'src/main.rb' => src }
    result = Emerald::Pkg::Installer.new(vfs: @shell.vfs, lock: @shell.installer.lock)
                                    .install_dir('./she7', files)
    @shell.apphost.reload(@shell.registry, 'she7')
    @shell.register_contributions
    result
  end

  # 多 App 包夹具（包 id 与各 App id 都不同：AgentOS 桌面形态），带一个服务；
  # 两个贡献命令：一个不指明 app（归约到包内首个 App = World），一个显式 `app`
  def desk_manifest
    {
      'spec' => 1, 'kind' => 'app', 'id' => 'she7-desk', 'name' => 'E7 桌面',
      'version' => '0.1.0', 'entry' => 'src/main.rb',
      'contributes' => {
        'commands' => [
          { 'id' => 'she7-desk.open', 'title' => '打开桌面' },
          { 'id' => 'she7-desk.agent', 'title' => '打开 Agent 窗', 'app' => 'she7_agent' },
        ],
      },
    }
  end

  def desk_src
    <<~RUBY
      class ShE7World < Emerald::App
        app_id :she7_world
      end

      class ShE7Agent < Emerald::App
        app_id :she7_agent
      end

      class ShE7DeskService < Emerald::Service
        activation on_startup: true

        attr_reader :last_ctx

        def activate(ctx)
          super
          @last_ctx = ctx
        end
      end
    RUBY
  end

  def install_desk_package(manifest = desk_manifest, src = desk_src)
    bytes = build_zip('ShE7Desk' => [
                        ['manifest.json', JSON.generate(manifest)],
                        ['src/main.rb', src],
                      ])
    @shell.install_package_bytes('./she7-desk.emz', bytes)
  end

  # 手写最小 zip（stored，够用即可；完整对拍见 pkg_zip_test.rb）
  def build_zip(by_top)
    u16 = ->(v) { [v].pack('v').bytes }
    u32 = ->(v) { [v].pack('V').bytes }
    body = []
    central = []
    by_top.each_value do |files|
      files.each do |name, text|
        nb = name.b.bytes
        data = text.b.bytes
        crc = Zlib.crc32(text)
        lho = body.size
        body += [0x50, 0x4b, 0x03, 0x04] + u16.call(20) + u16.call(0) + u16.call(0) +
                u16.call(0) + u16.call(0) + u32.call(crc) + u32.call(data.size) +
                u32.call(data.size) + u16.call(nb.size) + u16.call(0) + nb + data
        central << [nb, data.size, crc, lho]
      end
    end
    cd_offset = body.size
    central.each do |(nb, usize, crc, lho)|
      body += [0x50, 0x4b, 0x01, 0x02] + u16.call(20) + u16.call(20) + u16.call(0) + u16.call(0) +
              u16.call(0) + u16.call(0) + u32.call(crc) + u32.call(usize) + u32.call(usize) +
              u16.call(nb.size) + u16.call(0) + u16.call(0) + u16.call(0) + u16.call(0) +
              u32.call(0) + u32.call(lho) + nb
    end
    cd_size = body.size - cd_offset
    body + [0x50, 0x4b, 0x05, 0x06] + u16.call(0) + u16.call(0) + u16.call(central.size) +
      u16.call(central.size) + u32.call(cd_size) + u32.call(cd_offset) + u16.call(0)
  end
end

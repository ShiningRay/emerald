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
    Object.send(:remove_const, :ShE7App) if Object.const_defined?(:ShE7App, false)
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

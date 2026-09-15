# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'zlib'
require 'emerald'

# E7 · Installer（docs/PLAN.md §3.10 / SPEC §5）：
# 来源解析 → manifest 校验 → /Applications 写入 → lock 固化。
class PkgInstallerTest < Minitest::Test
  I = Emerald::Pkg::Installer
  Invalid = Emerald::Pkg::Json::Invalid

  MANIFEST = {
    'spec' => 1, 'kind' => 'app', 'id' => 'hello', 'name' => 'Hello',
    'version' => '0.1.0', 'entry' => 'src/main.rb',
    'min_runtime' => { 'emerald' => '>=0.1.0' },
  }.freeze

  def setup
    Beryl::Timer.backend = ->(_ms, blk) { blk.call }
    Beryl::Timer.cancel_backend = ->(_h) {}
    @vfs = Emerald::VFS.new(storage: Emerald::Storage::Memory.new)
    @installer = I.new(vfs: @vfs)
  end

  def teardown
    Beryl::Timer.backend = nil
    Beryl::Timer.cancel_backend = nil
  end

  def dir_files(manifest = MANIFEST, src = "class Hello < Emerald::App\n  app_id :hello\nend\n")
    { 'manifest.json' => JSON.generate(manifest), 'src/main.rb' => src, 'docs/README.md' => '# Hello' }
  end

  # ── 目录来源（最短路径）──────────────────────────────
  def test_install_dir_writes_applications_and_lock
    result = @installer.install_dir('./hello', dir_files)
    assert_equal :installed, result[:status]
    assert_equal 'Hello', result[:manifest].name

    assert @vfs.exist?('/Applications/hello/manifest.json')
    assert_equal 'class Hello < Emerald::App', @vfs.read('/Applications/hello/src/main.rb').lines.first.chomp
    assert @vfs.exist?('/Applications/hello/docs/README.md')

    entry = lock_entry('hello')
    assert_equal 'dir', entry['source']['type']
    assert_equal './hello', entry['source']['path']
    assert_match(/\A[0-9a-f]{64}\z/, entry['source']['content_sha256'])
    assert entry['installed_at']
    refute entry['source'].key?('resolved_commit')
  end

  def test_reinstall_same_content_is_skipped
    @installer.install_dir('./hello', dir_files)
    result = @installer.install_dir('./hello', dir_files)
    assert_equal :skipped, result[:status]
  end

  def test_reinstall_changed_content_updates
    @installer.install_dir('./hello', dir_files)
    m2 = MANIFEST.merge('version' => '0.2.0')
    v2 = dir_files(m2, "class Hello < Emerald::App\n  app_id :hello\n  # v2\nend\n")
    result = @installer.install_dir('./hello', v2)
    assert_equal :updated, result[:status]
    assert_equal '0.2.0', lock_entry('hello')['version']
    assert_equal '0.2.0', JSON.parse(@vfs.read('/Applications/hello/manifest.json'))['version']
    assert_includes @vfs.read('/Applications/hello/src/main.rb'), '# v2'
  end

  def test_update_cleans_stale_files
    @installer.install_dir('./hello', dir_files)
    v2 = dir_files
    v2.delete('docs/README.md') # 旧包有、新包没有 → 必须消失
    @installer.install_dir('./hello', v2)
    refute @vfs.exist?('/Applications/hello/docs/README.md')
  end

  def test_min_runtime_unsatisfied_rejected
    m = MANIFEST.merge('min_runtime' => { 'emerald' => '>=99.0.0' })
    e = assert_raises(Invalid) { @installer.install_dir('./hello', dir_files(m)) }
    assert_includes e.message, '应用需要更新或系统需要升级'
  end

  def test_missing_manifest_rejected
    e = assert_raises(Invalid) { @installer.install_dir('./hello', { 'src/main.rb' => 'x = 1' }) }
    assert_includes e.message, 'manifest.json'
  end

  def test_non_app_kind_rejected
    m = MANIFEST.merge('kind' => 'skill')
    e = assert_raises(Invalid) { @installer.install_dir('./hello', dir_files(m)) }
    assert_includes e.message, '仅支持安装 app'
  end

  def test_path_escape_rejected
    files = dir_files
    files['../evil.rb'] = 'x = 1'
    assert_raises(Invalid) { @installer.install_dir('./hello', files) }
  end

  # ── .emz 来源（Zip 管线）────────────────────────────
  def test_install_file_from_zip
    # 自制 .emz：manifest.json 在包根（作者用 zip -r 打包的典型布局）
    bytes = build_zip_bytes('hello' => [
                              ['manifest.json', JSON.generate(MANIFEST)],
                              ['src/main.rb', "class Hello < Emerald::App\nend\n"],
                            ])
    result = @installer.install_file('./hello.emz', bytes)
    assert_equal :installed, result[:status]
    assert_equal 'class Hello < Emerald::App', @vfs.read('/Applications/hello/src/main.rb').lines.first.chomp

    entry = lock_entry('hello')
    assert_equal 'file', entry['source']['type']
    refute entry['source'].key?('resolved_commit') # 非 git 来源，靠内容指纹固化
  end

  def test_install_file_from_archive_with_top_dir
    # 平台 archive 落地成 .emz 的形态：顶层 <repo>-<sha>/ 包装自动剥离
    bytes = build_zip_bytes('hello-main' => [
                              ['hello-main/manifest.json', JSON.generate(MANIFEST)],
                              ['hello-main/src/main.rb', 'x = 1'],
                            ])
    @installer.install_file('./hello.emz', bytes)
    assert @vfs.exist?('/Applications/hello/manifest.json')
  end

  # ── git 来源（fetcher 注入）─────────────────────────
  def test_install_git_resolves_commit_and_subpath
    entries = zip_entries(
      'calc-1d01761a1b2' => [
        ['calc-1d01761a1b2/pkgs/hello/manifest.json', JSON.generate(MANIFEST)],
        ['calc-1d01761a1b2/pkgs/hello/src/main.rb', 'x = 1'],
        ['calc-1d01761a1b2/README.md', 'monorepo 根文件不安装'],
      ]
    )
    fetcher = ->(_source) { { entries: entries, resolved_commit: '1d01761a1b2' } }
    inst = I.new(vfs: @vfs, fetcher: fetcher)
    result = inst.install_git('git:https://github.com/u/repo#main?path=pkgs/hello')

    assert_equal :installed, result[:status]
    assert @vfs.exist?('/Applications/hello/manifest.json')
    refute @vfs.exist?('/Applications/hello/README.md') # subpath 剥离
    entry = lock_entry('hello')
    assert_equal '1d01761a1b2', entry['source']['resolved_commit']
    assert_equal 'https://github.com/u/repo', entry['source']['url']
    assert_equal 'pkgs/hello', entry['source']['subpath']
  end

  def test_install_git_derives_commit_from_top_dir
    entries = zip_entries(
      'calc-abc1234' => [
        ['calc-abc1234/manifest.json', JSON.generate(MANIFEST)],
        ['calc-abc1234/src/main.rb', 'x = 1'],
      ]
    )
    inst = I.new(vfs: @vfs, fetcher: ->(_s) { { entries: entries } })
    inst.install_git('git:https://github.com/u/repo#v1.0.0')
    assert_equal 'abc1234', lock_entry('hello')['source']['resolved_commit']
  end

  def test_install_git_same_commit_skips
    entries = zip_entries('calc-abc1234' => [
                            ['calc-abc1234/manifest.json', JSON.generate(MANIFEST)],
                            ['calc-abc1234/src/main.rb', 'x = 1'],
                          ])
    calls = 0
    inst = I.new(vfs: @vfs, fetcher: ->(_s) { calls += 1; { entries: entries } })
    inst.install_git('git:https://github.com/u/repo#v1.0.0')
    assert_equal :skipped, inst.install_git('git:https://github.com/u/repo#v1.0.0')[:status]
    assert_equal 2, calls # fetch 照常发生（解析 ref），只是落地跳过
  end

  # ── 卸载 ───────────────────────────────────────────
  def test_uninstall_removes_dir_and_lock
    @installer.install_dir('./hello', dir_files)
    assert @installer.uninstall('hello')
    refute @vfs.exist?('/Applications/hello')
    assert_empty @installer.list
    refute @installer.uninstall('hello') # 再卸 = no-op
  end

  def test_lock_survives_roundtrip_through_vfs
    @installer.install_dir('./hello', dir_files)
    reloaded = Emerald::Pkg::Lock.new(@vfs)
    assert reloaded.installed?('hello')
    assert_equal '0.1.0', reloaded.get('hello')['version']
  end

  # ── helpers ────────────────────────────────────────
  def lock_entry(id)
    Emerald::Pkg::Lock.new(@vfs).get(id) # 每次现读：验证 lock 真实落盘
  end

  # { 顶层目录名 => [[name, text], ...] } → Entry 数组（名字保留顶层前缀）
  def zip_entries(by_top)
    by_top.flat_map do |_top, files|
      files.map { |name, text| Emerald::Pkg::Zip::Entry.new(name, false, text.b.bytes) }
    end
  end

  # { 包根名 => [[name, text], ...] } → zip 字节数组（name 相对包根，不带前缀）
  def build_zip_bytes(by_top)
    # 复用 pkg_zip_test 的手写 zip 结构（保持独立，避免跨测试文件依赖）
    u16 = ->(v) { [v].pack('v').bytes }
    u32 = ->(v) { [v].pack('V').bytes }
    body = []
    central = []
    by_top.each_value do |files|
      files.each do |name, text|
      raw = Zlib::Deflate.new(9, -15).then do |z|
        begin
          z.deflate(text, Zlib::FINISH).bytes
        ensure
          z.close
        end
      end
      nb = name.b.bytes
      crc = Zlib.crc32(text)
      lho = body.size
      body += [0x50, 0x4b, 0x03, 0x04] + u16.call(20) + u16.call(0) + u16.call(8) +
              u16.call(0) + u16.call(0) + u32.call(crc) + u32.call(raw.size) +
              u32.call(text.b.bytesize) + u16.call(nb.size) + u16.call(0) + nb + raw
      central << [nb, raw.size, text.b.bytesize, crc, lho]
      end
    end
    cd_offset = body.size
    central.each do |(nb, csize, usize, crc, lho)|
      body += [0x50, 0x4b, 0x01, 0x02] + u16.call(20) + u16.call(20) + u16.call(0) + u16.call(8) +
              u16.call(0) + u16.call(0) + u32.call(crc) + u32.call(csize) + u32.call(usize) +
              u16.call(nb.size) + u16.call(0) + u16.call(0) + u16.call(0) + u16.call(0) +
              u32.call(0) + u32.call(lho) + nb
    end
    cd_size = body.size - cd_offset
    body + [0x50, 0x4b, 0x05, 0x06] + u16.call(0) + u16.call(0) + u16.call(central.size) +
      u16.call(central.size) + u32.call(cd_size) + u32.call(cd_offset) + u16.call(0)
  end
end

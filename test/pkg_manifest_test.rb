# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'emerald'

# E7 · manifest.json 模型与校验（docs/SPEC-package-format.md §3/§4）
class PkgManifestTest < Minitest::Test
  VALID = {
    'spec' => 1,
    'kind' => 'app',
    'id' => 'hello',
    'name' => 'Hello',
    'version' => '0.1.0',
    'description' => '一句话',
    'authors' => ['Alice'],
    'min_runtime' => { 'emerald' => '>=0.1.0' },
    'permissions' => ['vfs:write'],
    'entry' => 'src/main.rb',
    'contributes' => {
      'commands' => [{ 'id' => 'hello.say', 'title' => '问好', 'hotkey' => 'meta+h' }],
      'file_types' => ['.hello', 'MD'],
      'menus' => [{ 'path' => '应用/工具', 'command' => 'hello.say' }],
    },
    'activation' => { 'on_command' => ['hello.say'], 'on_file_type' => ['.hello'], 'on_startup' => false },
    'window' => { 'singleton' => true, 'default_geometry' => { 'x' => 1, 'y' => 2, 'w' => 3, 'h' => 4 } },
  }.freeze

  def deep(hash)
    Marshal.load(Marshal.dump(hash))
  end

  def parse(hash_or_str)
    src = hash_or_str.is_a?(String) ? hash_or_str : JSON.generate(hash_or_str)
    Emerald::Pkg::Manifest.parse(src)
  end

  def test_full_valid_manifest_accessors
    m = parse(VALID)
    assert m.app?
    assert_equal :hello, m.id_sym
    assert_equal 'src/main.rb', m.entry
    assert_equal [{ id: 'hello.say', title: '问好', hotkey: 'meta+h' }], m.commands
    assert_equal ['.hello', '.md'], m.file_types
    assert_equal [{ path: '应用/工具', command: 'hello.say' }], m.menus
    assert_equal({ on_command: ['hello.say'], on_file_type: ['.hello'], startup: false }, m.activation)
    assert m.singleton?
    assert_equal({ x: 1, y: 2, w: 3, h: 4 }, m.default_geometry)
    assert_equal ['vfs:write'], m.permissions
  end

  def test_minimal_manifest_defaults
    m = parse('spec' => 1, 'kind' => 'app', 'id' => 'x', 'name' => 'X', 'version' => '1.0.0', 'entry' => 'src/main.rb')
    assert_equal [], m.commands
    assert_equal [], m.file_types
    assert_equal [], m.menus
    assert_equal({ on_command: [], on_file_type: [], startup: false }, m.activation)
    refute m.singleton?
    assert_nil m.default_geometry
  end

  def test_unknown_fields_ignored_and_future_spec_kinds_known
    m = parse(VALID.merge('future_field' => { 'a' => 1 }))
    assert_equal 'app', m.kind
    assert_equal %w[app agent skill], Emerald::Pkg::Manifest::KINDS
  end

  # ── 公共字段校验 ──────────────────────────────────────
  def test_rejects_missing_or_unknown_spec
    h = VALID.reject { |k, _| k == 'spec' }
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(h) }
    e = assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('spec' => 2)) }
    assert_includes e.message, '不支持的包规格版本'
  end

  def test_rejects_unknown_kind
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('kind' => 'theme')) }
  end

  def test_rejects_bad_id
    ['Hello', '1hello', 'hello world', ''].each do |bad|
      assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('id' => bad)) }
    end
  end

  def test_rejects_bad_version
    ['1.0', 'v1.0.0', 'one.two.three', ''].each do |bad|
      assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('version' => bad)) }
    end
  end

  def test_rejects_non_string_arrays
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('authors' => 'Alice')) }
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('permissions' => [1])) }
  end

  # ── app 扩展字段 ─────────────────────────────────────
  def test_app_requires_entry
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.reject { |k, _| k == 'entry' }) }
  end

  def test_entry_must_stay_inside_package
    ['../evil.rb', '/abs/evil.rb', 'src/../../evil.rb'].each do |bad|
      assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('entry' => bad)) }
    end
  end

  # ── contributes 校验 ─────────────────────────────────
  def test_rejects_bad_commands
    no_dot = deep(VALID)
    no_dot['contributes']['commands'][0]['id'] = 'nodot'
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(no_dot) }

    no_title = deep(VALID)
    no_title['contributes']['commands'][0].delete('title')
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(no_title) }

    dup = deep(VALID)
    dup['contributes']['commands'] << { 'id' => 'hello.say', 'title' => '重复' }
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(dup) }
  end

  def test_rejects_bad_menus
    bad = deep(VALID)
    bad['contributes']['menus'][0].delete('path')
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(bad) }
  end

  # ── activation / window 校验 ─────────────────────────
  def test_rejects_bad_activation
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('activation' => { 'on_command' => 'x' })) }
    assert_raises(Emerald::Pkg::Json::Invalid) { parse(VALID.merge('activation' => { 'on_startup' => 'yes' })) }
  end

  def test_rejects_bad_window_geometry
    assert_raises(Emerald::Pkg::Json::Invalid) do
      parse(VALID.merge('window' => { 'default_geometry' => { 'x' => 'a', 'y' => 2, 'w' => 3, 'h' => 4 } }))
    end
  end

  # ── min_runtime（§3）─────────────────────────────────
  def test_runtime_ok_satisfied_and_unsatisfied
    assert parse(VALID).runtime_ok?('0.1.0')
    refute parse(VALID).runtime_ok?('0.0.9')

    m = parse(VALID.merge('min_runtime' => { 'emerald' => '>=0.2.0' }))
    e = assert_raises(Emerald::Pkg::Json::Invalid) { m.require_runtime!('0.1.0') }
    assert_includes e.message, '应用需要更新或系统需要升级'
  end

  def test_runtime_operators_and_invalid_expr
    assert parse(VALID.merge('min_runtime' => { 'emerald' => '<99.0.0' })).runtime_ok?
    assert parse(VALID.merge('min_runtime' => { 'emerald' => '==0.1.0' })).runtime_ok?
    refute parse(VALID.merge('min_runtime' => { 'emerald' => '>0.1.0' })).runtime_ok?
    assert_raises(Emerald::Pkg::Json::Invalid) do
      parse(VALID.merge('min_runtime' => { 'emerald' => '~> 0.1' })).runtime_ok?
    end
  end

  def test_broken_json_string
    assert_raises(Emerald::Pkg::Json::Invalid) { parse('{oops') }
  end
end

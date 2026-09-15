# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'

# E7 · 安装来源语法（docs/SPEC-package-format.md §5）
class PkgSourceTest < Minitest::Test
  S = Emerald::Pkg::Source

  def test_local_file_and_dir_forms
    file = S.parse('./hello.emz')
    assert file.file?
    assert_equal './hello.emz', file.path
    refute file.git?

    dir = S.parse('./pkgs/hello')
    assert dir.dir?
    assert_equal './pkgs/hello', dir.path
  end

  def test_git_full_form
    s = S.parse('git:https://github.com/u/repo#v1.2.0?path=pkgs/hello')
    assert s.git?
    assert_equal 'https://github.com/u/repo', s.url
    assert_equal 'v1.2.0', s.ref
    assert_equal 'pkgs/hello', s.subpath
  end

  def test_git_defaults
    bare = S.parse('git:https://github.com/u/repo')
    assert_nil bare.ref
    assert_nil bare.subpath

    ref_only = S.parse('git:https://github.com/u/repo#main')
    assert_equal 'main', ref_only.ref
    assert_nil ref_only.subpath
  end

  def test_git_ref_with_slash_branch
    s = S.parse('git:https://github.com/u/repo#refs/heads/feat/x')
    assert_equal 'refs/heads/feat/x', s.ref
  end

  def test_git_requires_https
    assert_raises(Emerald::Pkg::Json::Invalid) { S.parse('git:http://github.com/u/repo') }
    assert_raises(Emerald::Pkg::Json::Invalid) { S.parse('git:ftp://x') }
  end

  def test_empty_source_invalid
    assert_raises(Emerald::Pkg::Json::Invalid) { S.parse('') }
    assert_raises(Emerald::Pkg::Json::Invalid) { S.parse('   ') }
    assert_raises(Emerald::Pkg::Json::Invalid) { S.parse(nil) }
  end

  def test_github_archive_url
    assert_equal 'https://codeload.github.com/u/repo/zip/v1.2.0',
                 S.parse('git:https://github.com/u/repo.git#v1.2.0').archive_url
    assert_equal 'https://codeload.github.com/u/repo/zip/HEAD',
                 S.parse('git:https://github.com/u/repo').archive_url
  end

  def test_gitlab_archive_url
    s = S.parse('git:https://gitlab.com/g/sub/repo#v2.0')
    assert_equal 'https://gitlab.com/g/sub/repo/-/archive/v2.0/repo-v2.0.zip', s.archive_url
  end

  def test_unknown_host_unsupported_in_browser
    e = assert_raises(S::Unsupported) do
      S.parse('git:https://example.com/u/repo').archive_url
    end
    assert_includes e.message, 'CLI'
  end

  def test_non_git_has_no_archive_url
    assert_raises(S::Unsupported) { S.parse('./hello.emz').archive_url }
  end

  def test_to_s_roundtrip_shape
    assert_equal './hello.emz', S.parse('./hello.emz').to_s
    assert_equal 'git:https://github.com/u/repo#main?path=p',
                 S.parse('git:https://github.com/u/repo#main?path=p').to_s
  end
end

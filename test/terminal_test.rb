# frozen_string_literal: true

# E5c · 终端单测：Session（纯 CRuby VFS shell，真 VFS 驱动）+ Terminal 视图壳。
# Session 部分不渲染任何组件；app 部分用 Citrine.render（StringRenderer）做渲染断言。
require 'minitest/autorun'
require 'emerald'

class TerminalTest < Minitest::Test
  Session = Emerald::Apps::Terminal::Session
  Terminal = Emerald::Apps::Terminal

  # ── 夹具 ─────────────────────────────────────────────

  def setup
    @vfs = Emerald::VFS.new(storage: nil) # 空树（storage: nil 不 seed），路径全由命令自建
    @session = Session.new(@vfs)
  end

  def booted(vfs: @vfs)
    Terminal.new.tap { |app| app.boot({ vfs: vfs }) }
  end

  # ── manifest ─────────────────────────────────────────

  def test_manifest_declarations
    assert_equal :terminal, Terminal.app_id
    assert_equal true, Terminal.singleton
    assert_equal '⌨️', Terminal.app_icon
    geo = Terminal.default_geometry.call
    assert_equal({ x: 180, y: 100, w: 560, h: 380 }, geo)
  end

  # ── Session：基础行为 ────────────────────────────────

  def test_cwd_starts_at_root
    assert_equal '/', @session.cwd
  end

  def test_empty_command_is_noop
    assert_equal '', @session.run('')
    assert_equal '', @session.run('   ')
    assert_empty @session.history
  end

  def test_history_records_executed_commands
    @session.run('pwd')
    @session.run('ls')
    @session.run('no_such_cmd')
    assert_equal ['pwd', 'ls', 'no_such_cmd'], @session.history
  end

  def test_exceptions_become_error_lines_not_raises
    @vfs.write('/blocker', '文件挡住目录')
    out = @session.run('mkdir /blocker/sub') # 中间路径被同名文件挡住 → ArgumentError
    assert_match(/\Amkdir: /, out)
  end

  # ── Session：help / pwd ──────────────────────────────

  def test_help_lists_all_commands
    out = @session.run('help')
    %w[help pwd ls cd cat mkdir touch echo rm clear].each do |cmd|
      assert_includes out, cmd
    end
  end

  def test_pwd_prints_cwd
    @session.run('mkdir /docs')
    @session.run('cd docs')
    assert_equal '/docs', @session.run('pwd')
  end

  # ── Session：ls ──────────────────────────────────────

  def test_ls_marks_dirs_and_sorts_dirs_first
    @session.run('mkdir /b_dir')
    @session.run('mkdir /a_dir')
    @session.run('touch /c.txt')
    assert_equal "a_dir/\nb_dir/\nc.txt", @session.run('ls')
  end

  def test_ls_with_path_argument
    @session.run('mkdir /docs')
    @session.run('touch /docs/readme.txt')
    assert_equal 'readme.txt', @session.run('ls /docs')
    assert_equal 'docs/', @session.run('ls /') # 目录名后加 /
  end

  def test_ls_ignores_dash_options_in_v1
    @session.run('touch /x.txt')
    assert_equal 'x.txt', @session.run('ls -l')
  end

  def test_ls_missing_dir_reports_error
    assert_equal 'ls: /nope: 没有此文件或目录', @session.run('ls /nope')
  end

  def test_ls_on_file_reports_not_dir
    @session.run('touch /f.txt')
    assert_equal 'ls: f.txt: 不是目录', @session.run('ls f.txt')
  end

  # ── Session：cd ──────────────────────────────────────

  def test_cd_relative_absolute_and_dotdot
    @session.run('mkdir /docs')
    @session.run('mkdir /docs/sub')
    @session.run('cd docs')
    assert_equal '/docs', @session.cwd
    @session.run('cd sub')
    assert_equal '/docs/sub', @session.cwd
    @session.run('cd ..')
    assert_equal '/docs', @session.cwd
    @session.run('cd /')
    assert_equal '/', @session.cwd
  end

  def test_cd_missing_dir_keeps_cwd
    out = @session.run('cd /ghost')
    assert_equal 'cd: /ghost: 没有此文件或目录', out
    assert_equal '/', @session.cwd
  end

  def test_cd_to_file_reports_error
    @session.run('touch /f.txt')
    assert_equal 'cd: f.txt: 不是目录', @session.run('cd f.txt')
    assert_equal '/', @session.cwd
  end

  def test_cd_without_arg_reports_usage
    assert_equal 'cd: 缺少参数（用法：cd <目录>）', @session.run('cd')
  end

  def test_cd_dotdot_at_root_stays_put
    assert_equal '', @session.run('cd ..') # POSIX 语义：根处 .. 原地不动
    assert_equal '/', @session.cwd
  end

  def test_tilde_is_root
    @session.run('cd /docs') if @vfs.exist?('/docs')
    @session.run('mkdir /home_docs')
    @session.run('cd home_docs')
    @session.run('cd ~')
    assert_equal '/', @session.cwd
  end

  # ── Session：cat ─────────────────────────────────────

  def test_cat_reads_file
    @vfs.write('/docs/hello.txt', "你好\n世界")
    assert_equal "你好\n世界", @session.run('cat /docs/hello.txt')
  end

  def test_cat_missing_and_dir_report_errors
    assert_equal 'cat: /nope: 没有此文件或目录', @session.run('cat /nope')
    @session.run('mkdir /d')
    assert_equal 'cat: d: 是目录', @session.run('cat d')
  end

  def test_cat_without_arg_reports_usage
    assert_equal 'cat: 缺少参数（用法：cat <文件>）', @session.run('cat')
  end

  # ── Session：mkdir / touch ────────────────────────────

  def test_mkdir_creates_dir_recursively
    assert_equal '', @session.run('mkdir /a/b/c')
    assert @vfs.stat('/a/b/c').kind == :dir
    assert_equal 'c/', @session.run('ls /a/b')
  end

  def test_mkdir_without_arg_reports_usage
    assert_equal 'mkdir: 缺少参数（用法：mkdir <目录>）', @session.run('mkdir')
  end

  def test_touch_creates_empty_file
    @session.run('touch /new.txt')
    node = @vfs.stat('/new.txt')
    assert_equal :file, node.kind
    assert_equal '', @vfs.read('/new.txt')
  end

  def test_touch_existing_only_refreshes_mtime
    @vfs.write('/f.txt', '内容不变')
    before = @vfs.stat('/f.txt').mtime
    @session.run('touch /f.txt')
    after = @vfs.stat('/f.txt').mtime
    assert_equal '内容不变', @vfs.read('/f.txt')
    assert after > before, 'touch 应只刷 mtime，内容保持不变'
  end

  # ── Session：echo 重定向 ─────────────────────────────

  def test_echo_overwrite_redirect_creates_parents
    assert_equal '', @session.run('echo 你好 > /deep/nested/f.txt')
    assert_equal '你好', @vfs.read('/deep/nested/f.txt')
  end

  def test_echo_overwrite_replaces_content
    @vfs.write('/f.txt', '旧内容')
    @session.run('echo 新内容 > /f.txt')
    assert_equal '新内容', @vfs.read('/f.txt')
  end

  def test_echo_append_redirect
    @vfs.write('/f.txt', '第一行')
    @session.run('echo 第二行 >> /f.txt')
    assert_equal '第一行第二行', @vfs.read('/f.txt')
  end

  def test_echo_append_to_missing_file_creates_it
    @session.run('echo 你好 >> /f.txt')
    assert_equal '你好', @vfs.read('/f.txt')
  end

  def test_echo_without_redirect_prints_text
    assert_equal 'hello world', @session.run('echo hello world')
  end

  def test_echo_redirect_without_target_reports_error
    assert_equal 'echo: 缺少重定向目标文件', @session.run('echo hi >')
  end

  # ── Session：rm ──────────────────────────────────────

  def test_rm_deletes_recursively
    @vfs.write('/tree/a.txt', 'a')
    @vfs.write('/tree/sub/b.txt', 'b')
    assert_equal '', @session.run('rm /tree')
    refute @vfs.exist?('/tree')
  end

  def test_rm_missing_reports_error
    assert_equal 'rm: /nope: 没有此文件或目录', @session.run('rm /nope')
  end

  def test_rm_without_arg_reports_usage
    assert_equal 'rm: 缺少参数（用法：rm <路径>）', @session.run('rm')
  end

  def test_rm_root_is_rejected_as_error_line
    @vfs.write('/keep.txt', '保留')
    out = @session.run('rm /')
    assert_match(/\Arm: /, out)
    assert_equal '保留', @vfs.read('/keep.txt') # 根拒绝删除，既有文件无恙
  end

  # ── Session：clear / 未知命令 ─────────────────────────

  def test_clear_returns_empty_and_view_calls_clear_bang
    assert_equal '', @session.run('clear')
    assert_equal 0, @session.clear_count
    @session.clear!
    assert_equal 1, @session.clear_count
  end

  def test_unknown_command_with_help_hint
    assert_equal "foobar: command not found\n输入 'help' 查看可用命令", @session.run('foobar')
  end

  # ── app 层：boot / 渲染 ──────────────────────────────

  def test_boot_builds_session_from_ctx_vfs
    app = booted
    assert_instance_of Session, app.session
    assert_equal '/', app.session.cwd
    assert_same @vfs, app.session.instance_variable_get(:@vfs)
  end

  def test_boot_without_vfs_leaves_session_nil
    app = Terminal.new.tap { |a| a.boot(nil) }
    assert_nil app.session
  end

  def test_render_contains_welcome_and_input
    html = Citrine.render(booted)
    assert_includes html, Terminal::WELCOME
    assert_includes html, Terminal::HELP_HINT
    assert_includes html, '&gt; '          # cwd 提示符（转义后）
    assert_includes html, '<input'         # 输入框
    assert_includes html, 'autofocus'
    assert_includes html, 'ui-monospace, Menlo, monospace' # 等宽字
    assert_includes html, 'overflow:auto'   # 输出区滚动
  end

  def test_render_without_boot_tolerates_nil_ctx
    html = Citrine.render(Terminal.new) # 未 boot：ctx nil 守卫不炸
    assert_includes html, '终端不可用'
    refute_includes html, '<input'
  end

  # ── app 层：exec ──────────────────────────────────────

  def test_exec_appends_output_and_clears_input
    @session = nil # 防误用：直接走 app 的 session
    @vfs.write('/hello.txt', '世界')
    app = booted
    app.input = 'cat /hello.txt'
    app.exec
    assert_equal '', app.input
    assert_equal [Terminal::WELCOME, Terminal::HELP_HINT, '/ > cat /hello.txt', '世界'], app.lines
  end

  def test_exec_records_prompt_before_cd_changes_cwd
    @vfs.write('/docs/a.txt', 'A')
    app = booted
    app.input = 'cd /docs'
    app.exec
    app.input = 'cat a.txt'
    app.exec
    assert_equal ['/ > cd /docs', '/docs > cat a.txt', 'A'], app.lines.last(3)
  end

  def test_exec_empty_input_is_noop
    app = booted
    app.input = '   '
    app.exec
    assert_equal [Terminal::WELCOME, Terminal::HELP_HINT], app.lines
    assert_equal '   ', app.input
  end

  def test_exec_unknown_command_appends_error_line
    app = booted
    app.input = 'blob'
    app.exec
    assert_equal [Terminal::WELCOME, Terminal::HELP_HINT, '/ > blob',
                  'blob: command not found', "输入 'help' 查看可用命令"], app.lines
  end

  def test_exec_clear_keeps_only_welcome
    app = booted
    app.input = 'pwd'
    app.exec
    app.input = 'clear'
    app.exec
    assert_equal [Terminal::WELCOME], app.lines
    assert_equal 1, app.session.clear_count
    assert_equal '', app.input
  end
end

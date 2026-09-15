# frozen_string_literal: true

# Emerald 主题 token 服务单测：纯 CRuby（beryl F5 同款纪律，无 Opal 依赖）
require 'minitest/autorun'
require 'json'
require 'emerald'

class ThemeTest < Minitest::Test
  # dark/light 共有的完整键集合：beryl demo :root 的 7 个 + emerald 扩展 3 个
  ALL_KEYS = %w[--bg --panel --panel2 --line --fg --dim --accent --wallpaper --pad --radius].freeze

  def test_modes
    assert_equal %i[dark light], Emerald::Theme::MODES
  end

  def test_dark_vars_cover_demo_root_tokens
    vars = Emerald::Theme.vars(:dark)
    # 值逐一锁定 beryl examples/demo.html :root 的暗色表
    assert_equal '#0b0e14', vars['--bg']
    assert_equal '#11151f', vars['--panel']
    assert_equal '#151b28', vars['--panel2']
    assert_equal '#232b3b', vars['--line']
    assert_equal '#c9d4e6', vars['--fg']
    assert_equal '#7d8aa5', vars['--dim']
    assert_equal '#4f8cff', vars['--accent']
  end

  def test_dark_vars_include_emerald_extensions
    vars = Emerald::Theme.vars(:dark)
    assert_equal 'radial-gradient(ellipse at 30% 20%, #16233d, #0b0e14)', vars['--wallpaper']
    assert_equal '10px', vars['--pad']
    assert_equal '10px', vars['--radius']
  end

  def test_light_vars_same_key_set_as_dark
    assert_equal ALL_KEYS.sort, Emerald::Theme.vars(:dark).keys.sort
    assert_equal ALL_KEYS.sort, Emerald::Theme.vars(:light).keys.sort
  end

  def test_light_palette_is_not_dark_inversion
    light = Emerald::Theme.vars(:light)
    # 亮色的「深度」靠面板更白：bg 浅灰白、panel 纯白抬升（而非暗色加深关系）
    assert_equal '#eef1f6', light['--bg']
    assert_equal '#ffffff', light['--panel']
    # fg 深灰蓝，不是暗色 fg 的反色
    assert_equal '#24303f', light['--fg']
    assert_equal '#2f6fe4', light['--accent']
    assert_equal 'radial-gradient(ellipse at 30% 20%, #dce6f5, #c9d6ea)', light['--wallpaper']
  end

  def test_accent_override_and_purity
    overridden = Emerald::Theme.vars(:dark, accent: '#ff8800')
    assert_equal '#ff8800', overridden['--accent']
    # 纯函数：override 不污染常量表与后续调用
    assert_equal '#4f8cff', Emerald::Theme.vars(:dark)['--accent']
    assert_equal '#2f6fe4', Emerald::Theme.vars(:light)['--accent']
  end

  def test_density_compact_vs_comfortable
    comfy = Emerald::Theme.vars(:dark)
    compact = Emerald::Theme.vars(:dark, density: :compact)
    assert_equal '10px', comfy['--pad']
    assert_equal '6px', compact['--pad']
    assert_equal '10px', comfy['--radius']
    assert_equal '8px', compact['--radius']
    # 密度只动几何 token，颜色不受影响
    %w[--bg --panel --panel2 --line --fg --dim --accent --wallpaper].each do |key|
      assert_equal comfy[key], compact[key]
    end
  end

  def test_invalid_mode_raises
    error = assert_raises(ArgumentError) { Emerald::Theme.vars(:solarized) }
    assert_includes error.message, 'solarized'
  end

  def test_invalid_density_raises
    assert_raises(ArgumentError) { Emerald::Theme.vars(:dark, density: :cosy) }
    assert_raises(ArgumentError) { Emerald::Theme.apply(:light, density: :spacious) }
  end

  def test_apply_returns_vars_on_cruby
    vars = Emerald::Theme.apply(:dark, accent: nil, density: :comfortable)
    assert_kind_of Hash, vars
    assert_equal '#0b0e14', vars['--bg']
    # 与 vars 同契约：CRuby 下 apply 就是「解析 + 返回应写入的表」，no-op 应用
    assert_equal Emerald::Theme.vars(:dark), vars
  end

  def test_vars_returns_json_serializable_plain_hash
    raw = Emerald::Theme.vars(:light, accent: '#ff8800', density: :compact)
    parsed = JSON.parse(JSON.generate(raw))
    assert_kind_of Hash, parsed
    assert_equal raw, parsed
    assert_equal '#ff8800', parsed['--accent']
    assert_equal '6px', parsed['--pad']
  end
end

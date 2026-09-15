# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  # 主题 token 服务（E4，见 docs/PLAN.md §3.8）。
  # beryl M5 上游迁移 deferred——本模块自带 token 表自包含，不动 beryl 仓；
  # 稳定后按反哺通道上提 beryl。
  #
  # 契约：
  #   Theme.modes                       # => %i[dark light]
  #   Theme.vars(:dark)                 # => Hash（CSS 变量名 → 值，纯函数）
  #   Theme.vars(:light, accent: '#ff8800', density: :compact)
  #   Theme.apply(:dark, accent: nil, density: :comfortable)
  #
  # 键格式：完整 CSS 变量名字符串（'--bg'），Opal 侧可直接 setProperty，
  # JSON 序列化后键即变量名，无需再拼接前缀。
  #
  # 纪律（beryl F5）：vars/apply 纯 CRuby 可测；仅文件尾部 apply 的写入分支
  # 是 Opal 适配（defined?(Opal) 守卫），CRuby 下安全 no-op。
  module Theme
    # 可用模式（顺序即 Settings 应用切换列表顺序）
    MODES = %i[dark light].freeze

    # 基础调色板：beryl demo（examples/demo.html :root）在用的 7 个 token 全量收录，
    # 外加 emerald 桌面扩展 --wallpaper。密度几何 token（--pad/--radius）在 DENSITIES。
    PALETTES = {
      dark: {
        '--bg' => '#0b0e14',
        '--panel' => '#11151f',
        '--panel2' => '#151b28',
        '--line' => '#232b3b',
        '--fg' => '#c9d4e6',
        '--dim' => '#7d8aa5',
        '--accent' => '#4f8cff',
        # 桌面扩展：暗色默认壁纸——夜空蓝径向渐变，蓝心与 --bg/#16233d 同族
        '--wallpaper' => 'radial-gradient(ellipse at 30% 20%, #16233d, #0b0e14)',
      }.freeze,
      light: {
        # 亮色取色思路：不是暗色反色——亮色的「深度」靠面板更白而非更黑，
        # 故 bg 浅灰白、panel 纯白抬升；文字取深灰蓝（#24303f）与暗色 #c9d4e6 同族；
        # accent 与暗色 #4f8cff 同色相、降明度（亮底上原蓝对比度不足）
        '--bg' => '#eef1f6',
        '--panel' => '#ffffff',
        '--panel2' => '#e2e8f2',
        '--line' => '#c9d2e0',
        '--fg' => '#24303f',
        '--dim' => '#64748b',
        '--accent' => '#2f6fe4',
        # 桌面扩展：亮色默认壁纸——晨光蓝径向渐变，与暗色版同构图
        '--wallpaper' => 'radial-gradient(ellipse at 30% 20%, #dce6f5, #c9d6ea)',
      }.freeze,
    }.freeze

    # 密度档：只动少量几何 token（内边距/圆角），颜色不受密度影响
    DENSITIES = {
      comfortable: { '--pad' => '10px', '--radius' => '10px' }.freeze,
      compact: { '--pad' => '6px', '--radius' => '8px' }.freeze,
    }.freeze

    class << self
      # 解析某模式下应生效的全部 CSS 变量（纯函数：每次返回新 Hash，常量表不被污染）。
      # mode 非法 / density 非法 → ArgumentError
      def vars(mode, accent: nil, density: :comfortable)
        palette = PALETTES[mode]
        raise ArgumentError, "未知主题模式: #{mode.inspect}（可用: #{MODES.join('/')}）" unless palette

        geometry = DENSITIES[density]
        raise ArgumentError, "未知密度档: #{density.inspect}（可用: #{DENSITIES.keys.join('/')}）" unless geometry

        result = palette.merge(geometry)
        result['--accent'] = accent unless accent.nil?
        result
      end

      # 应用主题：CRuby 侧仅解析，返回 vars Hash——真正写 CSS 变量是 Opal 渲染器的事
      #（Opal 下把 vars setProperty 到 document.documentElement.style，然后同样返回 vars）。
      # 返回 Hash 使 CRuby 单测可断言「应写入的变量表」而无需 DOM。
      def apply(mode, accent: nil, density: :comfortable)
        vars = vars(mode, accent: accent, density: density)
        apply_to_document(vars) if defined?(Opal)
        vars
      end

      private

      # Opal 适配：写入 :root 的 style（唯一允许出现的 JS，defined?(Opal) 守卫）
      def apply_to_document(vars)
        root = `document.documentElement`
        vars.each do |name, value|
          `#{root}.style.setProperty(#{name}, #{value})`
        end
      end
    end
  end
end

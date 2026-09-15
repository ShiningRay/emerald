# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  # 系统剪贴板（L5 系统服务，PLAN §3.6）：内存值是真相源；
  # Opal 下 best-effort 镜像到 navigator.clipboard——权限拒绝 / 环境缺失一律静默
  # （不炸、不阻塞 copy）。CRuby 下纯内存，测试零环境依赖。
  class Clipboard
    def initialize
      @value = nil
    end

    def copy(text)
      @value = text
      write_system(text)
      @value
    end

    def read
      @value
    end

    def clear
      @value = nil
    end

    private

    # Opal 专用：writeText 返回 Promise，权限拒绝会 reject——显式 .catch 吃掉，
    # 守住「失败静默」契约；navigator.clipboard 缺失（非安全上下文）走 catch。
    # defined?(Opal) 守卫：CRuby 下纯内存 no-op（不执行反引号）。
    def write_system(text)
      return unless defined?(Opal)

      `try { if (navigator.clipboard) { navigator.clipboard.writeText(#{text}).catch(function() {}) } } catch (e) {}`
    end
  end
end

# frozen_string_literal: true

module Emerald
  module Apps
    # 关于（E1）：系统信息页——标题 / 版本行（Emerald + Citrine 内核版本）/
    # 内核说明 / 已注册应用数。单例小窗。
    # ctx 未注入（实例未启动直接渲染）时应用数容忍显示 '—'。
    class About < Emerald::App
      app_id    :about
      app_title '关于'
      app_icon  '💎'
      singleton true
      default_geometry { { x: 200, y: 120, w: 380, h: 280 } }

      def view
        stack(css_class: 'about', gap: 10, style: { padding: '14px' }) do
          label(css_class: 'about-title') { 'Emerald OS' }
          label(css_class: 'about-version') { "Emerald 0.1.0 · Citrine #{Citrine::VERSION}" }
          label(css_class: 'about-kernel') do
            '基于 Citrine 信号内核与 Beryl 组件库构建的 Ruby Web 桌面：' \
            '应用以 Ruby 组件书写，经 Opal 编译在浏览器中运行。'
          end
          label(css_class: 'about-apps') { "已注册应用：#{registered_app_count}" }
        end
      end

      private

      # ctx[:launcher] 即 AppRegistry（shell 注入的服务表）
      def registered_app_count
        launcher = ctx && (ctx[:launcher] || ctx['launcher'])
        launcher ? launcher.apps.size : '—'
      end
    end
  end
end

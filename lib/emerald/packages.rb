# frozen_string_literal: true

module Emerald
  # 预装源码应用的正本（E7 · docs/PLAN.md §3.10「内置应用 = 预装应用」）。
  #
  # 包内只有源码（D11）；桌面首次启动把这里的内容 seed 进 VFS /Applications/。
  # 浏览器 bundle 不携带源文本（Opal 编译产物无源码），因此正本以字符串常量
  # 形式随系统分发——这是 .emap「源码即可执行格式」在预装场景的等价形态。
  #
  # ⚠ 同步纪律：Packages::ABOUT_MAIN_RB 与 lib/emerald/apps/about.rb 是同一
  # 应用的两份形态（前者 = /Applications 里的可编辑源码正本；后者 = bundle
  # 内的编译产物，让开机免加载 opal-parser，D12）。改动应用逻辑须两处同步，
  # pkg_apphost_test 与 shell_test 有一致性断言兜底。
  module Packages
    ABOUT_MANIFEST_JSON = <<~'JSON'
      {
        "spec": 1,
        "kind": "app",
        "id": "about",
        "name": "关于",
        "version": "0.1.0",
        "description": "Emerald OS 系统信息页",
        "authors": ["Emerald"],
        "min_runtime": { "emerald": ">=0.1.0" },
        "permissions": [],
        "entry": "src/main.rb",
        "contributes": {
          "commands": [{ "id": "about.open", "title": "关于 Emerald OS" }]
        },
        "activation": { "on_command": ["about.open"] },
        "window": { "singleton": true, "default_geometry": { "x": 200, "y": 120, "w": 380, "h": 280 } }
      }
    JSON

    ABOUT_MAIN_RB = <<~'RB'
      # frozen_string_literal: true

      # 关于 —— Emerald 预装源码应用（docs/SPEC-package-format.md §4.1）。
      # 与 bundle 内 lib/emerald/apps/about.rb 保持同步（见 lib/emerald/packages.rb 头注）。
      module Emerald
        module Apps
          class About < Emerald::App
            app_id    :about
            app_title '关于'
            app_icon  '◈'
            singleton true
            default_geometry { { x: 200, y: 120, w: 380, h: 280 } }

            def view
              stack(css_class: 'about', gap: 10, style: { padding: '14px' }) do
                label(css_class: 'about-title') { 'Emerald OS' }
                label(css_class: 'about-version') { "Emerald #{Emerald::VERSION} · Citrine #{Citrine::VERSION}" }
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
    RB

    # 预装包表：id => { 'manifest.json' => 文本, 'src/main.rb' => 文本 }
    def self.builtin
      @builtin ||= {
        'about' => { 'manifest.json' => ABOUT_MANIFEST_JSON, 'src/main.rb' => ABOUT_MAIN_RB },
      }
    end
  end
end

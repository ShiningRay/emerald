# frozen_string_literal: true

# E0 冒烟：emerald 可加载、可渲染（StringRenderer）
require 'minitest/autorun'
require 'emerald'

class SmokeTest < Minitest::Test
  def test_emerald_module_loads
    assert defined?(Emerald)
    assert defined?(Emerald::App)
  end

  def test_component_renders_via_string_renderer
    html = Citrine.render(BootProbe.new)
    assert_includes html, 'Emerald OS'
  end
end

class BootProbe < Citrine::Component
  def view
    stack(style: { align_items: 'center', height: '100%' }) do
      label { 'Emerald OS' }
    end
  end
end

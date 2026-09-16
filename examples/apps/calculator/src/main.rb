# frozen_string_literal: true

# 计算器 —— Emerald 可分发 App 参照示例（docs/SPEC-package-format.md §4.1）
# 单文件 entry：Engine（纯计算内核，CRuby 可测、不触 UI）+ App 壳。
# entry 在运行时已加载（Emerald::App 可用）的前提下求值，自身不 require。
class Calculator < Emerald::App
  # 立即执行式计算内核：entry（当前输入/显示）、acc（左操作数）、op（待结算
  # 运算符）、fresh（下一次输入开新数）。除零进入错误态，仅 C 或新数字脱出。
  class Engine
    OPS = { '+' => :+, '-' => :-, '*' => :*, '/' => :/ }.freeze
    MAX_DIGITS = 14

    def initialize
      clear
    end

    def display
      @entry
    end

    def press(key)
      clear if @error && key != 'C'
      case key
      when '0'..'9' then digit(key)
      when '.' then dot
      when '+', '-', '*', '/' then set_op(key)
      when '=' then equals
      when '%' then percent
      when 'back' then backspace
      when 'C' then clear
      end
      self
    end

    private

    def clear
      @entry = '0'
      @acc = nil
      @op = nil
      @fresh = true
      @error = false
    end

    def digit(d)
      @entry = @fresh || @entry == '0' ? d : @entry + d
      @entry = @entry[0, MAX_DIGITS]
      @fresh = false
    end

    def dot
      return if @entry.include?('.') && !@fresh

      @entry = @fresh ? '0.' : "#{@entry}."
      @fresh = false
    end

    def percent
      @entry = format_num(entry_value / 100.0)
    end

    def backspace
      return if @fresh

      @entry = @entry.length > 1 ? @entry[0..-2] : '0'
    end

    def set_op(op)
      resolve_pending unless @fresh
      return if @error

      @acc = entry_value
      @op = op
      @fresh = true
    end

    def equals
      return unless @op && @acc

      result = apply(@acc, @op, entry_value)
      result.nil? ? error! : conclude(result)
    end

    def resolve_pending
      return unless @op && @acc

      result = apply(@acc, @op, entry_value)
      result.nil? ? error! : @entry = format_num(result)
    end

    def apply(a, op, b)
      return nil if op == '/' && b.zero?

      a.send(OPS.fetch(op), b)
    end

    def conclude(result)
      @entry = format_num(result)
      @acc = nil
      @op = nil
      @fresh = true
    end

    def error!
      @entry = '错误'
      @acc = nil
      @op = nil
      @fresh = true
      @error = true
    end

    def entry_value
      @entry.to_f
    end

    # round(10) 消除 0.1+0.2 浮点尾差；整数值不显示小数点
    def format_num(v)
      v = v.round(10)
      v == v.to_i ? v.to_i.to_s : v.to_s
    end
  end

  app_id :calculator
  app_title '计算器'
  app_icon '🧮'
  singleton true
  default_geometry { { x: 220, y: 140, w: 280, h: 420 } }

  state :display, default: '0'
  window_key :key_press

  KEYS = [
    %w[C back % /],
    %w[7 8 9 *],
    %w[4 5 6 -],
    %w[1 2 3 +],
    %w[0 . =]
  ].freeze

  KEY_LABELS = { 'back' => '⌫', '*' => '×', '/' => '÷' }.freeze
  VALID_KEYS = KEYS.flatten.freeze

  DISPLAY = {
    font_size: '28px', text_align: 'right', padding: '14px',
    background: '#111827', color: '#f9fafb', border_radius: 10,
    font_family: 'ui-monospace, monospace', min_height: '30px',
    overflow: 'hidden', white_space: 'nowrap'
  }.freeze

  KEY_BASE = {
    flex: 1, font_size: '18px', padding: '14px 0', border: 'none',
    border_radius: 10, background: '#e5e7eb', color: '#111827',
    cursor: 'pointer'
  }.freeze
  KEY_OP = KEY_BASE.merge(background: '#f59e0b', color: '#ffffff').freeze
  KEY_EQ = KEY_BASE.merge(background: '#10b981', color: '#ffffff').freeze
  KEY_CLEAR = KEY_BASE.merge(background: '#ef4444', color: '#ffffff').freeze

  def view
    stack(css_class: 'calc', gap: 8, style: { padding: '12px' }) do
      label(css_class: 'calc-display', style: DISPLAY) { display }
      KEYS.each do |row_keys|
        row(gap: 8) { row_keys.each { |k| key_button(k) } }
      end
    end
  end

  def press(key)
    engine.press(key)
    self.display = engine.display
  end

  def key_press(ev)
    key = { 'Enter' => '=', 'Escape' => 'C', 'Backspace' => 'back' }.fetch(ev.key, ev.key)
    press(key) if VALID_KEYS.include?(key)
  end

  private

  def engine
    @engine ||= Engine.new
  end

  def key_button(key)
    Beryl::Button.new(text: KEY_LABELS.fetch(key, key),
                      kind: key_kind(key),
                      css_class: "calc-key calc-key-#{key}",
                      style: key_style(key),
                      on_click: -> { press(key) }).view
  end

  # 语义 kind（= 是主操作、C 是危险操作）；键色仍由 key_style 内联样式权威
  # （b-btn-primary 的主题色被内联样式覆盖，视觉与改造前一致）
  def key_kind(key)
    case key
    when '=' then :primary
    when 'C' then :danger
    else :default
    end
  end

  def key_style(key)
    case key
    when '=' then KEY_EQ
    when 'C' then KEY_CLEAR
    when '+', '-', '*', '/', '%' then KEY_OP
    else KEY_BASE
    end
  end
end

# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald'
require 'emerald/service'

# 声明了三类激活事件的服务（on_startup: false 显式缺省）
class GreetService < Emerald::Service
  activation on_command: ['hello.say'], on_file_type: ['.hello'], on_startup: false

  attr_reader :last_ctx

  def activate(ctx)
    super
    @last_ctx = ctx
  end
end

class StartupService < Emerald::Service
  activation on_startup: true
end

class ZipService < Emerald::Service
  activation on_file_type: ['zip'] # 声明侧无点
end

# 从未调 activation 的服务：应拿到默认空声明
class QuietService < Emerald::Service; end

class TrackedService < Emerald::Service
  class << self
    attr_accessor :deactivation_order
  end
  self.deactivation_order = []

  def deactivate
    self.class.deactivation_order << object_id
    super
  end
end

class ServiceTest < Minitest::Test
  def test_activation_macro_declares_three_event_kinds
    events = GreetService.activation_events
    assert_equal ['hello.say'], events[:on_command]
    assert_equal ['.hello'], events[:on_file_type]
    assert_equal false, events[:startup]
  end

  def test_activation_normalizes_file_types_to_lowercase_dotted
    cls = Class.new(Emerald::Service)
    cls.activation on_file_type: ['TXT', '.MD']
    assert_equal ['.txt', '.md'], cls.activation_events[:on_file_type]
  end

  def test_unactivated_subclass_gets_default_empty_declaration
    events = QuietService.activation_events
    assert_equal [], events[:on_command]
    assert_equal [], events[:on_file_type]
    assert_equal false, events[:startup]
  end

  def test_parent_declaration_does_not_leak_into_subclass_or_parent_sibling
    parent = Class.new(Emerald::Service)
    parent.activation on_command: ['p.cmd']
    child = Class.new(parent)
    sibling = Class.new(Emerald::Service)

    assert_equal [], child.activation_events[:on_command]
    assert_equal [], sibling.activation_events[:on_command]
    assert_equal ['p.cmd'], parent.activation_events[:on_command]
    assert_equal [], Emerald::Service.activation_events[:on_command]
  end

  def test_subclass_declaration_does_not_touch_parent
    parent = Class.new(Emerald::Service)
    child = Class.new(parent)
    child.activation on_command: ['c.cmd']

    assert_equal ['c.cmd'], child.activation_events[:on_command]
    assert_equal [], parent.activation_events[:on_command]
  end

  def test_service_lifecycle_defaults
    svc = QuietService.new
    refute svc.activated?
    svc.activate(:ctx)
    assert svc.activated?
    svc.deactivate
    refute svc.activated?
  end
end

class ServiceHubTest < Minitest::Test
  def setup
    TrackedService.deactivation_order = []
    @hub = Emerald::ServiceHub.new
    @greet = GreetService.new
    @startup = StartupService.new
    @quiet = QuietService.new
    @hub.register(@greet)
    @hub.register(@startup)
    @hub.register(@quiet)
  end

  def test_register_class_auto_instantiates_and_duplicates_raise
    hub = Emerald::ServiceHub.new
    assert_equal hub, hub.register(QuietService)
    assert_instance_of QuietService, hub.services.first
    assert_raises(ArgumentError) { hub.register(QuietService) }   # 同类重复
    assert_raises(ArgumentError) { hub.register(hub.services.first) } # 同实例重复
  end

  def test_services_snapshot_in_registration_order
    assert_equal [@greet, @startup, @quiet], @hub.services
    @hub.services.pop
    assert_equal @quiet, @hub.services.last # 快照，防外部改穿
  end

  def test_activate_for_command_is_idempotent_and_normalizes_symbol
    ctx = Object.new
    assert_equal [@greet], @hub.activate_for_command('hello.say', ctx)
    assert @greet.activated?
    refute @quiet.activated?
    assert_equal ctx, @greet.last_ctx # 子类覆写 super 后基类仍记账
    assert_empty @hub.activate_for_command(:'hello.say', ctx) # Symbol 归一、二次不再激活
  end

  def test_activate_for_file_type_normalizes_case_and_missing_dot
    zip = @hub.register(ZipService.new).services.last
    assert_equal [@greet], @hub.activate_for_file_type('.HELLO', :ctx)
    assert_equal [zip], @hub.activate_for_file_type('ZIP', :ctx) # 无点 + 大写
    refute @quiet.activated?
  end

  def test_activate_startup_activates_all_startup_services_idempotently
    assert_equal [@startup], @hub.activate_startup(:ctx)
    assert_empty @hub.activate_startup(:ctx)
  end

  def test_deactivate_all_flips_flags_and_allows_reactivation
    @hub.activate_for_command('hello.say', :ctx)
    @hub.activate_startup(:ctx)
    assert_equal @hub, @hub.deactivate_all
    [@greet, @startup].each { |svc| refute svc.activated? }

    assert_equal [@greet], @hub.activate_for_command('hello.say', :ctx) # 可重激活
    assert @greet.activated?
  end

  def test_deactivate_all_runs_in_reverse_registration_order
    hub = Emerald::ServiceHub.new
    a = TrackedService.new
    b = TrackedService.new
    hub.register(a)
    hub.register(b)
    a.activate(:ctx)
    b.activate(:ctx)
    hub.deactivate_all
    assert_equal [b.object_id, a.object_id], TrackedService.deactivation_order
    refute a.activated?
    refute b.activated?
  end
end

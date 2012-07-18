require 'minitest/autorun'

load File.join(File.dirname(__FILE__), '..', '..', '..', 'lib', 'deltacloud', 'drivers', 'base_driver.rb')

describe Deltacloud::BaseDriver do

  before do
    class TestDriver < Deltacloud::BaseDriver

      define_hardware_profile('t1.micro') do
        cpu                1
        memory             613
        storage            160
        architecture       ['i386','x86_64']
      end

      feature :instances, :user_data
      feature :instances, :user_name do
        { :max_length => 50 }
      end

      define_instance_states do
        start.to( :pending )          .automatically
        pending.to( :running )        .automatically
        pending.to( :stopping )       .on( :stop )
        pending.to( :stopped )        .automatically
        stopped.to( :running )        .on( :start )
        running.to( :running )        .on( :reboot )
        running.to( :stopping )       .on( :stop )
        stopping.to(:stopped)         .automatically
        stopping.to(:finish)          .automatically
        stopped.to( :finish )         .automatically
      end

      def realms(credentials, opts={}); end
    end
    @driver = TestDriver.new
  end

  describe 'when creating a new driver' do

    it 'must return the proper driver name' do
      @driver.name.must_equal 'test'
      TestDriver.name.must_equal 'TestDriver'
    end

  end

  describe 'hardware profiles' do

    it 'must allow to define custom hardware profiles' do
      TestDriver.must_respond_to :define_hardware_profile
    end

    it 'should not allow to create duplicated profile' do
      TestDriver.define_hardware_profile('t1.micro').must_be_nil
      TestDriver.hardware_profiles.size.must_equal 1
    end

    it 'should return all defined hardware profiles' do
      TestDriver.must_respond_to :hardware_profiles
      TestDriver.hardware_profiles.wont_be_empty
    end

    it 'should allow to filter hardware profiles' do
      @driver.filter_hardware_profiles(TestDriver.hardware_profiles, :architecture => 'i386').wont_be_empty
      @driver.filter_hardware_profiles(TestDriver.hardware_profiles, :architecture => 'unknown').must_be_empty
      @driver.filter_hardware_profiles(TestDriver.hardware_profiles, :id => 't1.micro').wont_be_empty
      @driver.filter_hardware_profiles(TestDriver.hardware_profiles, :id => 'm1.unknown').must_be_empty
    end

  end

  describe 'features' do

    it 'should return all defined features' do
      TestDriver.features.must_be_kind_of Hash
      TestDriver.features.keys.must_include :instances
      TestDriver.features[:instances].must_be_kind_of Array
      TestDriver.features[:instances].must_include :user_data
    end

    it 'must have method to check if feature is defined' do
      TestDriver.must_respond_to :'has_feature?'
      TestDriver.has_feature?(:instances, :user_data).must_equal true
      TestDriver.has_feature?(:instances, :user_unknown).must_equal false
    end

    it 'must return feature defined constraints' do
      TestDriver.must_respond_to :'constraints'
      TestDriver.constraints.must_be_kind_of Hash
      TestDriver.constraints[:instances].must_be_kind_of Hash
      TestDriver.constraints[:instances][:user_name].must_be_kind_of Hash
      TestDriver.constraints[:instances][:user_name][:max_length].must_equal 50
      TestDriver.constraints(:collection => :instances, :feature => :user_name).must_be_kind_of Hash
      TestDriver.constraints(:collection => :instances, :feature => :user_name)[:max_length].must_equal 50
    end

  end

  describe 'instance states' do

    it 'should return defined instance state machine' do
      TestDriver.must_respond_to :instance_state_machine
      TestDriver.instance_state_machine.must_be_kind_of Deltacloud::StateMachine
    end

    it 'should return actions for given state' do
      @driver.must_respond_to :instance_actions_for
      @driver.instance_actions_for('RUNNING').must_be_kind_of Array
      @driver.instance_actions_for('RUNNING').must_include :stop
    end

  end

  describe 'capabilities' do

    it 'should return if driver has given capability' do
      @driver.has_capability?(:realms).must_equal true
      @driver.has_capability?(:images).must_equal false
    end

  end

end
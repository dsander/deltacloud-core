#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.  The
# ASF licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the
# License.  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations
# under the License.

require 'rubygems'
require 'profitbricks'

module Deltacloud
  module Drivers
    module Profitbricks

class ProfitbricksDriver < Deltacloud::BaseDriver

  feature :instances,
    :user_name,
    :realm_filter

  feature :images,
    :user_name

  define_hardware_profile('default') do
    cpu              1..48
    memory           256..(192*1024), :default => 256
    storage          1..2048
    architecture     'x86_64'
  end

  def images(credentials, opts = nil)
    new_client(credentials)
    results = []
    safely do
      results = ::Profitbricks::Image.all.collect do | img |
        Image.new(
            :id => img.id,
            :name => img.name,
            :description => "CPU Hot-Plugging: #{img.cpu_hotpluggable}, Region: #{img.region}, Os: (#{img.os_type}), Type: #{img.type}",
            :owner_id => credentials.user,
            :state => 'AVAILABLE',
            :architecture => 'x86_64',
        )
      end
    end
    # Add hardware profiles to each image
    profiles = hardware_profiles(credentials)
    results.each { |img| img.hardware_profiles = profiles }
    filter_on( results, :id, opts )
  end

  def realms(credentials, opts = nil)
    new_client(credentials)
    results = []
    safely do
      results = ::Profitbricks::DataCenter.all.collect do |data_center|
        Realm.new(
          :id => data_center.id,
          :name => "#{data_center.name} (#{data_center.region})",
          :state => 'AVAILABLE', # ProfitBricks doesn't return the states when calling getAllDataCenters()
          :limit => :unlimited
        )
      end
    end
    filter_on(results, :id, opts)
  end

  def instances(credentials, opts = {})
    new_client(credentials)
    results = safely do ::Profitbricks::Server.all.collect do |s|
        convert_instance(s, credentials.user)
      end
    end
    filter_on(results, opts, :id, :state, :realm_id)
    results
  end

  def create_instance( credentials, image_id, opts)
    new_client(credentials)
    storage = nil
    server = nil
    params = {}

    #if opts[:hwp_storage]
      params[:name] = "Storage#{rand(1000)}"
      params[:size] = opts.delete[:hwp_storage]
      params[:mount_image_id] = opts.delete[:image_id]
      params[:data_center_id] = opts[:data_center_id]

      #storage = ::Profitbricks::Storage.create(params)
      #storage = convert_storage(storage)
    #end

    puts opts

=begin
    safely do
      if opts[:realm_id]
        opts[:data_center_id] = opts.delete("realm_id")
      end

      if opts[:hwp_storage]
        params[:name] = "Storage#{rand(1000)}"
        params[:size] = opts.delete[:hwp_storage]
        params[:mount_image_id] = opts.delete[:image_id]
        params[:data_center_id] = opts[:data_center_id]
        puts params
        safely do
          storage = ::Profitbricks::Storage.create(params)
          storage = convert_storage(storage)
        end
      end

      opts[:name] = "Sever#{rand(1000)}" unless opts[:name].empty?
      opts[:ram] = opts.delete("hwp_memory")
      opts[:cpu] = opts.delete("hwp_cpu")
      opts[:availability_zone] = "AUTO"
      if storage[:id]
        opts[:boot_from_storage_id] = storage[:id]
      end
      #server = convert_instance(::Profitbricks::Server.create(opts), credentials.user)
    end
    server
=end
  end


  def reboot_instance( credentials, instance_id )
    new_client(credentials)
    safely do
      server = ::Profitbricks::Server.find(:id => instance_id)
      server.reboot
    end
  end

  def stop_instance( credentials, instance_id )
    new_client(credentials)
    safely do
      server = ::Profitbricks::Server.find(:id => instance_id)
      server.shutdown
    end
  end

  def start_instance( credentials, instance_id )
    new_client(credentials)
    safely do
      server = ::Profitbricks::Server.find(:id => instance_id)
      server.start
    end
  end

  def destroy_instance( credentials, instance_id )
    new_client(credentials)
    safely do
      server = ::Profitbricks::Server.find(:id => instance_id)
      server.delete
    end
  end


  def storage_volumes( credentials, opts = { } )
    new_client(credentials)
    results = ::Profitbricks::DataCenter.all.collect do |data_center|
      (data_center.storages || []).collect do |storage|
        convert_storage(storage)
      end.flatten
    end.flatten
    results = filter_on(results, opts, :id)
    results
  end


  def create_storage_volume(credentials, opts = {})
    new_client(credentials)
    result = nil
    params = {}
    safely do
      opts[:size] = opts.delete("capacity") || 1
      opts[:data_center_id] = opts.delete("realm_id") unless (opts["realm_id"].nil? || opts["realm_id"].empty?)
      opts[:name] = opts.delete("name") || "Storage#{rand(1000)}"
      opts.delete("commit")
      opts.delete("snapshot_id")
      opts.delete("description")
      puts opts
      result = ::Profitbricks::Storage.create(opts)
      result = convert_storage(result)
    end
    result
  end

  def destroy_storage_volume(credentials, opts = {})
    new_client( credentials )
    safely do
      storage = ::Profitbricks::Storage.find(:id => opts[:id])
      storage.delete
    end
  end

  def attach_storage_volume( credentials, opts = {} )
    new_client( credentials )
    puts opts
    raise 'Error'
  end

  def detach_storage_volume(credentials, opts = {})
    new_client( credentials )
    safely do
      storage = ::Profitbricks::Storage.find(:id => opts[:id])
      storage.disconnect(:server_id => opts[:instance_id])
    end
  end

  define_instance_states do
    start.to( :pending )          .automatically
    pending.to( :running )        .automatically

    pending.to( :stopping )       .on( :stop )
    pending.to( :stopped )        .on( :start )

    stopped.to( :running )        .on( :start )

    running.to( :running )        .on( :reboot )
    running.to( :stopping )       .on( :stop )
    running.to( :finish)          .on( :destroy)

    stopping.to(:stopped)         .automatically
    stopping.to(:finish)          .automatically
    stopped.to( :finish )         .automatically
  end

  #
  ### Private declarations
  #

  private

  def convert_instance(server, user_name)
    inst = Instance.new(
      :id                => server.id,
      :realm_id          => server.data_center_id,
      :owner_id          => user_name,
      :description       => server.name,
      :name              => server.name,
      :state             => server.running?? 'RUNNING' : 'PENDING',
      :architecture      => 'x86_64',
      :image_id          => nil,
      :instance_profile  => InstanceProfile::new('default'),
      :public_addresses  => server.public_ips,
      :private_addresses => server.private_ips,
      :username          => nil,
      :password          => nil,
      #:storage_volumes => server.connected_storages
    )
    inst.actions = instance_actions_for( inst.state )
    #inst.create_image = 'RUNNING'.eql?( inst.state )
    inst
  end

  def convert_storage (storage)
    result = StorageVolume.new(
        :id => storage.id,
        :name => storage.name,
        :description => "Capacity: #{storage.size}GB",
        :created => storage.creation_time,
        :state => storage.provisioning_state,
        :capacity => storage.size,
        :realm_id => storage.data_center_id,
        :instance_id => storage.server_ids,
        :actions => [:attach, :detach, :destroy]
    )

    result
  end
  
  def new_client(credentials)
    client = nil
    safely do
      ::Profitbricks.configure do |config|
        config.username = credentials.user
        config.password = credentials.password
      end
    end
  end

  exceptions do

    on /No offering found/ do
      status 400
    end

    on /Authentication failed/ do
      status 401
    end

    on /Error/ do
      status 500
    end

  end

  private

end

    end
  end
end


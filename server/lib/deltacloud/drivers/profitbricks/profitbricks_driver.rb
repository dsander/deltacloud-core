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
require 'pp'

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
    cpu              1..48,                            :default => 1
    memory           (1..196*4).collect { |i| i*256 }, :default => 1024
    storage          20..2048,                         :default => 50
    architecture     'x86_64'
  end

  def images(credentials, opts = {})
    new_client(credentials)
    results = []
    safely do
      #get all HDD images - filter by HDD, because only HDD images can be attached to a storage
      results = ::Profitbricks::Image.all.select { | img | img.type == 'HDD'}.collect do | img |
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
    filter_on( results, opts, :id, :region, :name)
  end

  def realms(credentials, opts = {})
    new_client(credentials)
    results = []
    safely do
      datacenters = if opts[:image]!=nil
        ::Profitbricks::DataCenter.all.select { |img| opts[:image].description =~ /Region: #{img.region},/ }
      else
        ::Profitbricks::DataCenter.all
      end
      results = datacenters.collect do |data_center|
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

    results = safely do
      if opts[:storage_id]
        storage = ::Profitbricks::Storage.find(:id => opts[:storage_id])
        ::Profitbricks::DataCenter.find(:id => storage.data_center_id).servers.collect do |s|
          convert_instance(s, credentials.user)
        end
      else
        ::Profitbricks::Server.all.collect do |s|
          convert_instance(s, credentials.user)
        end
      end
    end
    filter_on(results, opts, :id, :state, :realm_id)
    results
  end

  def create_instance( credentials, image_id, opts)
    new_client(credentials)
    params = {}
    storage = nil
    server = nil

    safely do
      #Create storage first
      if opts[:hwp_storage]
        params[:name] = "Storage#{rand(1000)}"
        params[:size] = opts.delete("hwp_storage")
        params[:mount_image_id] = opts.delete("image_id")
        if opts[:realm_id]
          params[:data_center_id] = opts[:realm_id]
        end
        storage = convert_storage(::Profitbricks::Storage.create(params))
      end

      #Create instange
      opts.delete("hwp_id");
      opts[:name] = opts.delete('name');
      opts[:name] = opts[:name] == "" ? "Sever#{rand(1000)}" : opts[:name]
      opts[:ram] = opts.delete("hwp_memory")
      opts[:cores] = opts.delete("hwp_cpu")
      opts[:availability_zone] = "AUTO"
      opts[:internet_access] = true
      opts[:lan_id] = "1"
      if storage.respond_to?('id')
        opts[:boot_from_storage_id] = storage.id
      end
      opts[:data_center_id] = opts.delete("realm_id")
      if opts[:data_center_id] == nil && storage.respond_to?('realm_id')
          opts[:data_center_id] = storage.realm_id
      end
      server = convert_instance(::Profitbricks::Server.create(opts), credentials.user)
    end
    server
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
      server.power_off
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


  def storage_volumes( credentials, opts = {} )
    new_client(credentials)
    results = if opts[:id]
      [convert_storage(::Profitbricks::Storage.find(:id => opts[:id]))]
    else
      ::Profitbricks::DataCenter.all.collect do |data_center|
        (data_center.storages || []).collect do |storage|
          convert_storage(storage)
        end.flatten
      end.flatten
    end
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
      result = convert_storage(::Profitbricks::Storage.create(opts))
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
    safely do
      storage = ::Profitbricks::Storage.find(:id => opts[:id])
      storage.connect(:server_id => opts[:instance_id])
    end
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

    #pending.to( :stopped )        .on( :start )

    stopped.to( :running )        .on( :start )
    stopped.to( :stopped )        .on( :destroy )

    running.to( :running )        .on( :reboot )
    running.to( :stopping )       .on( :stop )

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
      :state             => convert_instance_state(server),
      :architecture      => 'x86_64',
      :image_id          => convert_instance_image(server),
      :instance_profile  => InstanceProfile::new('default'),
      :public_addresses  => server.public_ips,
      :private_addresses => server.private_ips,
      :username          => nil,
      :password          => nil,
      :storage_volumes => convert_instance_storages_volumes(server)
    )
    inst.actions = instance_actions_for( inst.state )
    #inst.create_image = 'RUNNING'.eql?( inst.state )
    inst
  end

  def convert_instance_state(server)
    state = server.respond_to?('virtual_machine_state')? (server.provisioned?? server.virtual_machine_state : server.provisioning_state) : "ERROR"
    case state
      when /INPROCESS/
        "PENDING"
      when /SHUTOFF/
        "STOPPED"
      when /SHUTDOWN/
        "STOPPED"
      when /PAUSED/
        "STOPPED"
      when /INACTIVE/
        "STOPPED"
      when /CRASHED/
        "ERROR"
      when /NOSTATE/
        "ERROR"
      when /ERROR/
        "ERROR"
      when /RUNNING/
        "RUNNING"
      else
        "UNKNOWN"
    end
  end


  def convert_instance_storages_volumes(server)
    return [] if server.connected_storages.nil?
    server.connected_storages.collect { |s| {s.id => nil} }
  end

  def convert_instance_image(server)
    return nil if server.connected_storages.nil?
    server.connected_storages.each do |s|
      # FIXME due to the api not returning the bootDevice flag we just use the first image we find
      storage = ::Profitbricks::Storage.find(id: s.id)
      return storage.mount_image.id if storage.mount_image
    end
    return nil
  end


  def convert_storage (storage)
    pp storage
    result = StorageVolume.new(
        :id => storage.id,
        :name => storage.name,
        :description => "Capacity: #{storage.size}GB",
        :state => convert_storage_state(storage),
        :capacity => storage.size,
        :realm_id => storage.data_center_id,
        :actions => [:attach, :detach, :destroy]
    )
    if storage.respond_to?("server_ids")
      result.instance_id= storage.server_ids
    end
    if storage.respond_to?("creation_time")
      result.created = storage.creation_time
    end
    result
  end

  def convert_storage_state(storage)
    state = storage.respond_to?('provisioning_state')? storage.provisioning_state : "ERROR"
    case state
      when /INPROCESS/
        "PENDING"
      when /INACTIVE/
        "ERROR"
      when /ERROR/
        "ERROR"
      when /AVAILABLE/
        "AVAILABLE"
      else
        "UNKNOWN"
    end
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


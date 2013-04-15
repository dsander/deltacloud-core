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
require 'savon'

require 'cloudfiles'
require 'cloudservers'
require 'base64'

module Deltacloud
  module Drivers
    module Profitbricks

class ProfitbricksClient

  def initialize(options={})
    url = 'https://api.profitbricks.com/1.2/wsdl'
    @options = options
    @client = Savon.client( url )
    @client.http.auth.basic options[ :username ], options[ :password ]
  end

  def camel_case( string )
    s = string.to_s
    return s if s !~ /_/ && s =~ /[a-a]+.*/
    result = s.split( '_' ).map{ |e| e.capitalize }.join
    result[ 0, 1 ].downcase + result[ 1..-1 ]
  end

  def remote_call( method_name, soap_body = { } )
    response = @client.request :ns0, camel_case( method_name ) do
      soap.body = soap_body
    end
    response_block = ( method_name.to_s + '_response' ).to_sym
    response.to_hash[ response_block ][ :return ]
  end

"""=========================================================================="""

  def to_array( arg )
    if arg == nil
      return [ ]
    end
    arg.kind_of?( Array ) ? arg : [ arg ]
  end

  def list_data_centers( )
    to_array( remote_call( :get_all_data_centers ) ).find_all { | dc | dc[ :region ] = 'EUROPE' }
  end

  def list_servers( )
    result = [ ]
    for dc_info in list_data_centers
      dc = remote_call( :get_data_center, { :dataCenterId => dc_info[ :data_center_id ] } )
      if dc.has_key?( :servers )
        result.push *to_array( dc[ :servers ] )
      end
    end
    result
  end

  def get_server( id )
    remote_call( :get_server, { :serverId => id } )
  end

  def list_storages( )
    result = [ ]
    for dc_info in list_data_centers
      dc = remote_call( :get_data_center, { :dataCenterId => dc_info[ :data_center_id ] } )
      if dc.has_key?( :storages )
        result.push *to_array( dc[ :storages ] )
      end
    end
    result
  end

  def get_storage( id )
    remote_call( :get_storage, { :storageId => id } )
  end

  def list_images( )
    to_array( remote_call( :get_all_images ) ).find_all { | img | img[ :region ] = 'EUROPE' }
  end

  def connect_storage_to_server( storage_id, server_id, bus_type = nil, device_number = nil)
    bus_type = bus_type.to_s.upcase
    if bus_type != 'IDE' and bus_type != 'SCSI'
      bus_type = 'VIRTIO' # fallback to default
    end
    remote_call( :connect_storage_to_server, { :storageId => storage_id, :serverId => server_id, :busType => bus_type.upcase, } )
  end

  def disconnect_storage_from_server( storage_id, server_id )
    remote_call( :disconnect_storage_from_server, { :storageId => storage_id, :serverId => server_id } )
  end

end

"""=========================================================================="""

class ProfitbricksDriver < Deltacloud::BaseDriver

  feature :images, :user_name
  feature :instances, :realm_filter
  feature :instances, :hardware_profiles

  define_hardware_profile 'default' do
    cpu             ( 1 .. 48 )
    memory          ( 256 .. 192*1024 )
    storage         ( 1 .. 64*1024 )
    architecture    'x86_64'
  end

  #
  ### Images
  #

  def images( credentials, opts = nil )
    pb = new_client( credentials )
    results = [ ]
    safely do
      results = pb.list_images.collect do | img |
        Image.new(
          :id => img[ :image_id ].to_s,
          :name => img[ :image_name ],
          :description => img[ :image_name ] + ' (' + img[ :os_type ] + ' ' + img[ :image_type ] + ')',
          :owner_id => credentials.user,
          :state => 'AVAILABLE',
          :architecture => 'x86_64'
        )
      end
    end
    filter_on( results, :id, opts )
  end

  #
  ### Realms
  #

  def realms( credentials, opts = nil )
    pb = new_client( credentials )
    result = pb.list_data_centers.collect do | data_center |
      Realm.new(
        :id => data_center[ :data_center_id ],
        :name => data_center[ :data_center_name ] + ' (' + data_center[ :region ] + ')',
        :state => 'AVAILABLE', # ProfitBricks doesn't return the states when calling getAllDataCenters()
        :limit => :unlimited
      )
    end
  end

  #
  ### Instances
  #

  def create_instance( credentials, image_id, opts )
    raise 'Error'
  end

  def reboot_instance( credentials, instance_id )
    raise 'Error'
  end

  def destroy_instance( credentials, instance_id )
    raise 'Error'
  end
  alias_method :stop_instance, :destroy_instance

  def instances( credentials, opts = { } )
    pb = new_client( credentials )
    insts = []

    safely do
      begin
        if opts[ :id ]
          server = pb.get_server( opts[ :id ] )
          insts << convert_instance( server, credentials.user )
        else
          insts = pb.list_servers.collect do |server|
            convert_instance( server, credentials.user )
          end
        end
      rescue CloudServers::Exception::ItemNotFound
      end
    end

    insts = filter_on( insts, :id, opts )
    insts = filter_on( insts, :state, opts )
    insts
  end

  #
  ### Credentials
  #

  def valid_credentials?( credentials )
    begin
      check_credentials( credentials )
      return true
    rescue
    end
    return false
  end

  def check_credentials( credentials )
    new_client( credentials )
  end

  define_instance_states do
    start.to( :pending )    .on( :create )
    pending.to( :running )  .automatically
    running.to( :running )  .on( :reboot )
    running.to( :stopping ) .on( :stop )
    stopping.to( :stopped ) .automatically
    stopped.to( :finish )   .automatically
  end

  #
  ### Storage volumes
  #

  def storage_volumes( credentials, opts = { } )
    pb = new_client( credentials )
    stos = [ ]
    safely do
      if opts[ :id ]
        sto = pb.get_storage( opts[ :id ] )
        stos << convert_volume( sto )
      else
        stos = pb.list_storages( ).collect do | volume |
          convert_volume( volume )
        end
      end
    end
    stos
  end

  def convert_volume ( volume )
    StorageVolume.new(
      :id => volume[ :storage_id ],
      :created => volume[ :creation_time ],
      :state => volume[ :provisioning_state ],
      :capacity => volume[ :size ],
      :instance_id => volume[ :server_ids ] ? ( volume[ :server_ids ].kind_of?(Array) ? volume[ :server_ids ][ 0 ] : volume[ :server_ids ] ) : nil,
      :realm_id => volume[ :data_center_id ],
      :device => volume[ :aws_device ],
      # TODO: the available actions should be tied to the current volume state
      :actions => [:attach, :detach, :destroy]
    )
  end

  def create_storage_volume(credentials, opts={})
    check_credentials(credentials)
  end

  def destroy_storage_volume(credentials, opts={})
    check_credentials(credentials)
  end

  def attach_storage_volume( credentials, opts = { } )
    pb = new_client( credentials )
    print opts[ :id ] + "\n"
    print "\n\n@@ " + opts.inspect + " @@\n\n"
    pb.connect_storage_to_server( opts[ :id ], opts[ :instance_id ], 'VIRTIO', nil )
  end

  def detach_storage_volume(credentials, opts)
    pb = new_client( credentials )
    pb.disconnect_storage_from_server( opts[ :id ], opts[ :instance_id ] )
  end

  #
  ### Private declarations
  #

  private

  def extract_ips( server )
    ips = { :public => [ ], :private => [ ] }
    if not server.has_key?( :nics )
      return ips
    end
    nics = ( server[ :nics ].kind_of?( Array ) ? server[ :nics ] : [ server[ :nics ] ] )
    # public ips, nics with internet access
    for nic in nics.find_all { | nic | nic[ :internet_access ] }
      nic_ips = (nic[ :ips ].kind_of?( Array ) ? nic[ :ips ] : [ nic[ :ips ] ] )
      nic_ips = nic_ips.find_all{ | ip | ip != nil }
      ips[ :public ].push *nic_ips
    end
    # private ips, nics without internet access
    for nic in nics.find_all { | nic | not nic[ :internet_access ] }
      nic_ips = (nic[ :ips ].kind_of?( Array ) ? nic[ :ips ] : [ nic[ :ips ] ] )
      nic_ips = nic_ips.find_all{ | ip | ip != nil }
      ips[ :private ].push *nic_ips
    end

    ips
  end

  def convert_instance( server, user_name )
    ips = extract_ips( server )
    inst = Instance.new(
      :id => server[ :server_id ],
      :realm_id => server[ :data_center_id ],
      :owner_id => user_name,
      :description => server[ :server_name ],
      :name => ( server[ :server_name ] == nil ? 'No name' : server[ :server_name ] ),
      :state => ( server[ :virtual_machine_state ] == 'RUNNING' ) ? 'RUNNING' : 'PENDING',
      :architecture => 'x86_64',
      :image_id => nil,
      :instance_profile => InstanceProfile::new( 'default' ),
      :public_addresses => ips[ :public ].collect { | ip | InstanceAddress.new( ip ) },
      :private_addresses => ips[ :private ].collect { | ip | InstanceAddress.new( ip ) },
      :username => nil,
      :password => nil
    )
    inst.actions = instance_actions_for( inst.state )
    inst.create_image = 'RUNNING'.eql?( inst.state )
    inst
  end

  def new_client( credentials )
    client = nil
    safely do
      client = ProfitbricksClient.new( { :username => credentials.user, :password => credentials.password } )
    end
    if client == nil
      raise 'AuthFailure'
    end
    client
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

    on /CloudServers::Exception::(\w+)/ do
      status 500
    end

  end

  private

end

    end
  end
end


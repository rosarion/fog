require 'digest/sha2'
require 'fog/storage'

module Fog
  module Storage
    class Vsphere < Fog::Service

      requires :vsphere_username, :vsphere_password, :vsphere_server
      recognizes :vsphere_port, :vsphere_path, :vsphere_ns
      recognizes :vsphere_rev, :vsphere_ssl, :vsphere_expected_pubkey_hashs
      recognizes 'clusters', 'share_datastore_pattern', 'local_datastore_pattern'

      model_path 'fog/vsphere/models/storage'
      collection  :volumes
      model       :volume

      request_path 'fog/vsphere/requests/storage'
      request :vm_create_disk
      request :query_resources


      module Shared

        attr_reader :vsphere_is_vcenter
        attr_reader :vsphere_rev
        attr_reader :vsphere_server
        attr_reader :vsphere_username

        DEFAULT_SCSI_KEY = 1000
        DISK_DEV_LABEL = "abcdefghijklmnopqrstuvwxyz"

        ATTR_TO_PROP = {
            :id => 'config.instanceUuid',
            :name => 'name',
            :uuid => 'config.uuid',
            :instance_uuid => 'config.instanceUuid',
            :hostname => 'summary.guest.hostName',
            :operatingsystem => 'summary.guest.guestFullName',
            :ipaddress => 'guest.ipAddress',
            :power_state => 'runtime.powerState',
            :connection_state => 'runtime.connectionState',
            :hypervisor => 'runtime.host',
            :tools_state => 'guest.toolsStatus',
            :tools_version => 'guest.toolsVersionStatus',
            :is_a_template => 'config.template',
            :memory_mb => 'config.hardware.memoryMB',
            :cpus   => 'config.hardware.numCPU',
        }

        def convert_vm_mob_ref_to_attr_hash(vm_mob_ref)
          return nil unless vm_mob_ref

          props = vm_mob_ref.collect! *ATTR_TO_PROP.values.uniq
          # NOTE: Object.tap is in 1.8.7 and later.
          # Here we create the hash object that this method returns, but first we need
          # to add a few more attributes that require additional calls to the vSphere
          # API. The hypervisor name and mac_addresses attributes may not be available
          # so we need catch any exceptions thrown during lookup and set them to nil.
          #
          # The use of the "tap" method here is a convenience, it allows us to update the
          # hash object without explicitly returning the hash at the end of the method.
          Hash[ATTR_TO_PROP.map { |k,v| [k.to_s, props[v]] }].tap do |attrs|
            attrs['id'] ||= vm_mob_ref._ref
            attrs['mo_ref'] = vm_mob_ref._ref
            # The name method "magically" appears after a VM is ready and
            # finished cloning.
            if attrs['hypervisor'].kind_of?(RbVmomi::VIM::HostSystem) then
              # If it's not ready, set the hypervisor to nil
              attrs['hypervisor'] = attrs['hypervisor'].name rescue nil
            end
            # This inline rescue catches any standard error.  While a VM is
            # cloning, a call to the macs method will throw and NoMethodError
            attrs['mac_addresses'] = vm_mob_ref.macs rescue nil
            attrs['path'] = get_folder_path(vm_mob_ref.parent)
          end
        end

        class HostResource
          attr_accessor :mob
          attr_accessor :name
          attr_accessor :cluster            # this host belongs to which cluster
          attr_accessor :local_datastores
          attr_accessor :share_datastores
          attr_accessor :connection_state
          attr_accessor :place_share_datastores
          attr_accessor :place_local_datastores

          def local_sum
            sum = 0
            return sum if local_datastores.nil?
            local_datastores.values.each {|x| sum += x.real_free_space }
            sum
          end

          def share_sum
            sum = 0
            return sum if share_datastores.nil?
            share_datastores.values.each {|x| sum += x.real_free_space }
            sum
          end

        end

        class DatastoreResource
          attr_accessor :mob
          attr_accessor :name
          attr_accessor :shared # boolean represents local or shared
          attr_accessor :total_space
          attr_accessor :free_space
          attr_accessor :unaccounted_space

          def real_free_space
            if (@free_space - @unaccounted_space) < 0
              real_free = 0
            else
              real_free = (@free_space - @unaccounted_space)
            end
            real_free
          end

          def initialize
            @unaccounted_space = 0
          end

          def deep_clone
            _deep_clone({})
          end

          protected
          def _deep_clone(cloning_map)
            return cloning_map[self] if cloning_map.key? self
            cloning_obj = clone
            cloning_map[self] = cloning_obj
            cloning_obj.instance_variables.each do |var|
              val = cloning_obj.instance_variable_get(var)
              begin
                val = val._deep_clone(cloning_map)
              rescue TypeError
                next
              end
              cloning_obj.instance_variable_set(var, val)
            end
            cloning_map.delete(self)
          end
        end

        class Disk
          attr_accessor :type # system or swap or data
          attr_accessor :shared  # local or shared
          attr_accessor :mode # thin or thick_eager_zeroed or thick_lazy_zeroed
          attr_accessor :affinity # split or not
          attr_accessor :volumes # volumes
          attr_accessor :size # total size

          def initialize(options = {})
            @type =  options['type']
            @mode = options['mode']
            @affinity = options['affinity'] && true
            @size = options['size']
            @shared = options['shared'] || false
            @volumes = {}
          end

        end

        class VM
          attr_accessor :id
          attr_accessor :name
          attr_accessor :host_mob
          attr_accessor :host_name
          attr_accessor :req_mem # requried mem
          attr_accessor :system_disks # Disk
          attr_accessor :swap_disks # Disk
          attr_accessor :data_disks # Disk
          attr_accessor :disk_index # mapped to unit_number
          attr_accessor :datastore_pattern

          def initialize(options = {})
            @name = options['name']
            @req_mem = options['req_mem']
            options['type'] = 'system'
            options['affinity'] = true
            options['size'] = options['system_size']
            options['shared'] = options['system_shared'] || true
            options['mode'] = options['system_mode']|| 'thin'
            @system_disks = Disk.new(options)
            options['type'] = 'swap'
            options['affinity'] = true
            options['size'] = options['swap_size'] || @req_mem
            options['mode'] = options['swap_mode']
            @swap_disks = Disk.new(options)
            options['type'] = 'data'
            options['affinity'] = false
            options['size'] = options['data_size']
            options['shared'] = options['data_shared'] || false
            options['mode'] = options['data_mode']
            @data_disks = Disk.new(options)
            @disk_index =0
          end

          def get_volumes_for_os(type)
            case type
              when 'system'
                vs = system_disks.volumes.values
              when 'swap'
                vs = swap_disks.volumes.values
              when 'data'
                vs = data_disks.volumes.values
              else
                vs = data_disks.volumes.values
            end
            vs.collect { |v| "/dev/sd#{DISK_DEV_LABEL[v.unit_number]}"}.compact.sort
          end

          def get_system_ds_name
            @system_disks.volumes.values[0].datastore_name
          end

          def volume_add(type, id, mode, size, fullpath, datastore_name, unit_number = 0)
            v = Volume.new
            v.vm_mo_ref = id
            v.mode = mode
            v.fullpath = fullpath
            v.size = size
            v.datastore_name = datastore_name
            v.unit_number = unit_number
            v.scsi_key = DEFAULT_SCSI_KEY
            case type
              when 'system'
                system_disks.volumes[fullpath] = v
              when 'swap'
                swap_disks.volumes[fullpath] = v
              when 'data'
                data_disks.volumes[fullpath] = v
              else
                data_disks.volumes[fullpath] = v
            end
            v
          end

          def inspect_volume_size
            Fog::Logger.deprecation("vm.system_disks.volumes.size = #{@system_disks.volumes.size}[/]")
            Fog::Logger.deprecation("vm.swap_disks.volumes.size = #{@swap_disks.volumes.size}[/]")
            Fog::Logger.deprecation("vm.data_disks.volumes.size = #{@data_disks.volumes.size}[/]")
          end

          def inspect_fullpath
            Fog::Logger.deprecation("______________________________________________")
            Fog::Logger.deprecation("start traverse vm.system_disks.volumes:[/]")
            @system_disks.volumes.values.each do |v|
              Fog::Logger.deprecation("vm #{name} system_disks - fullpath = #{v.fullpath} with unit_number = #{v.unit_number}[/]")
            end
            Fog::Logger.deprecation("end [/]")
            Fog::Logger.deprecation("start traverse vm.swap_disks.volumes:[/]")
            @swap_disks.volumes.values.each do |v|
              Fog::Logger.deprecation("vm #{name} swap_disks - fullpath = #{v.fullpath} with unit_number = #{v.unit_number}[/]")
            end
            Fog::Logger.deprecation("end [/]")
            Fog::Logger.deprecation("start traverse vm.data_disks.volumes:[/]")
            @data_disks.volumes.values.each do |v|
              Fog::Logger.deprecation("vm #{name} data_disks - fullpath = #{v.fullpath} with unit_number = #{v.unit_number}[/]")
            end
            Fog::Logger.deprecation("end [/]")
          end

        end # end of VM

      end # end of shared module


      class Mock

        include Shared

        def initialize(options={})
          require 'rbvmomi'
          @vsphere_username = options[:vsphere_username]
          @vsphere_password = 'REDACTED'
          @vsphere_server   = options[:vsphere_server]
          @vsphere_expected_pubkey_hash = options[:vsphere_expected_pubkey_hash]
          @vsphere_is_vcenter = true
          @vsphere_rev = '4.0'
        end

      end

      class Real

        include Shared

        def initialize(options={})
          require 'rbvmomi'
          @vsphere_username = options[:vsphere_username]
          @vsphere_password = options[:vsphere_password]
          @vsphere_server   = options[:vsphere_server]
          @vsphere_port     = options[:vsphere_port] || 443
          @vsphere_path     = options[:vsphere_path] || '/sdk'
          @vsphere_ns       = options[:vsphere_ns] || 'urn:vim25'
          @vsphere_rev      = options[:vsphere_rev] || '4.0'
          @vsphere_ssl      = options[:vsphere_ssl] || true
          @vsphere_verify_cert = options[:vsphere_verify_cert] || false
          @vsphere_expected_pubkey_hash = options[:vsphere_expected_pubkey_hash]
          @vsphere_must_reauthenticate = false
          # used to initialize resource list
          @share_datastore_pattern = options['share_datastore_pattern']
          Fog::Logger.deprecation("fog: input share_datastore_pattern is #{options['share_datastore_pattern']}[/]")
          @local_datastore_pattern = options['local_datastore_pattern']
          Fog::Logger.deprecation("fog: input local_datastore_pattern is #{options['local_datastore_pattern']}[/]")
          @clusters = []
          @connection = nil
          # This is a state variable to allow digest validation of the SSL cert
          bad_cert = false
          loop do
            begin
              @connection = RbVmomi::VIM.new :host => @vsphere_server,
                                             :port => @vsphere_port,
                                             :path => @vsphere_path,
                                             :ns   => @vsphere_ns,
                                             :rev  => @vsphere_rev,
                                             :ssl  => @vsphere_ssl,
                                             :insecure => !@vsphere_verify_cert
              break
            rescue OpenSSL::SSL::SSLError
              raise if bad_cert
              bad_cert = true
            end
          end

          if bad_cert then
            validate_ssl_connection
          end

          # Negotiate the API revision
          if not options[:vsphere_rev]
            rev = @connection.serviceContent.about.apiVersion
            @connection.rev = [ rev, ENV['FOG_VSPHERE_REV'] || '4.1' ].min
          end

          @vsphere_is_vcenter = @connection.serviceContent.about.apiType == "VirtualCenter"
          @vsphere_rev = @connection.rev

          authenticate
          # initially load storage resource
          fetch_resources(options['clusters'])
        end

        def close
          @connection.close
          @connection = nil
        rescue RbVmomi::fault => e
          raise Fog::Vsphere::Errors::ServiceError, e.message
        end

        def fetch_resources(clusters = nil)
          if !(clusters.nil?)
            clusters.each {|c_name| @clusters << get_mob_ref_by_name('ComputeResource',c_name)}
          end
          if @clusters.size <=0
            Fog::Logger.deprecation("can not load into storage resources without clusters argument[/]")
          else
            fetch_host_storage_resource()
          end
        end

        def query_capacity(vms, options = {})
          if options.has_key?('share_datastore_pattern') || options.has_key?('local_datastore_pattern')
            fetch_host_storage_resource(
                'hosts' => options['hosts'],
                'share_datastore_pattern' => options['share_datastore_pattern'],
                'local_datastore_pattern' => options['local_datastore_pattern']
            )
          end
          total_share_req_size = 0
          total_local_req_size = 0
          vms.each do |vm|
            if vm.system_disks.shared
              total_share_req_size += vm.system_disks.size
            else
              Fog::Logger.deprecation("fog: required system size = #{vm.system_disks.size.to_s}")
              total_local_req_size += vm.system_disks.size
            end
            if vm.data_disks.shared
              total_share_req_size += vm.data_disks.size
            else
              total_local_req_size += vm.data_disks.size
            end
            if vm.swap_disks.shared
              total_share_req_size += vm.swap_disks.size
            else
              total_local_req_size += vm.swap_disks.size
            end
          end
          fit_hosts = []
          options['hosts'].each do |host_name|
            if @host_list.has_key?(host_name)
              @host_list[host_name].local_datastores.values.each do |ds|
                Fog::Logger.deprecation("fog: local ds for host #{host_name} name: #{ds.name}, real_free_space: #{ds.real_free_space}")
              end
              @host_list[host_name].share_datastores.values.each do |ds|
                Fog::Logger.deprecation("fog: shared ds for host #{host_name} name: #{ds.name}, real_free_space: #{ds.real_free_space}")
              end
              Fog::Logger.deprecation("fog: host #{host_name} has been fetched with local size of #{ @host_list[host_name].local_sum}")
              Fog::Logger.deprecation("fog: required size of #{total_local_req_size.to_s}")
              next if @host_list[host_name].connection_state != 'connected'
              next if @host_list[host_name].local_sum < total_local_req_size
              next if @host_list[host_name].share_sum < total_share_req_size
              fit_hosts << host_name
              Fog::Logger.deprecation("fog: host number #{fit_hosts.size}")
            end
          end
          fit_hosts
        end

        def recommendation(vms, hosts)
          solution_list = {}
          Fog::Logger.deprecation("fog: @host_list number #{@host_list.keys.size}")
          hosts = hosts.sort {|x,y| @host_list[y].local_sum <=> @host_list[x].local_sum}
          hosts.each do |host_name|
            @cached_ds = nil
            next unless @host_list.has_key?(host_name)
            solution_list[host_name]=[]
            vms.each do |vm_in_queue|
              vm = Marshal.load(Marshal.dump(vm_in_queue))
              # place system and swap
              if vm.system_disks.shared && !(@host_list[host_name].share_datastores.empty?)
                datastore_candidates = @host_list[host_name].share_datastores.values.clone
              else
                datastore_candidates = @host_list[host_name].local_datastores.values.clone
              end
              datastore_candidates = datastore_candidates.sort {|x,y| y.real_free_space <=> x.real_free_space}

              Fog::Logger.deprecation("fog: start for host #{host_name}")
              datastore_candidates.each do |ds|
                Fog::Logger.deprecation("fog: ds for host #{host_name} name: #{ds.name}, real_free_space: #{ds.real_free_space}")
              end
              Fog::Logger.deprecation("fog: end")
              if !(@cached_ds.nil?)
                datastore_candidates.delete(@cached_ds)
                datastore_candidates.unshift(@cached_ds)
              end
              sum = 0
              datastore_candidates.each {|x| sum += x.real_free_space }
              if sum < (vm.req_mem + vm.system_disks.size + vm.swap_disks.size)
                return "there is no enough space for vm #{vm.name} with all given hosts"
              end
              system_done = false
              swap_done = false
              datastore_candidates.each do |ds|
                if !(vm.datastore_pattern.nil?)
                  next unless isMatched?(ds.name, vm.datastore_pattern)
                end
                if ds.real_free_space >= (vm.req_mem + vm.system_disks.size + vm.swap_disks.size)
                  alloc_volumes(host_name, 'system', vm, [ds], vm.system_disks.size)
                  system_done = true
                  alloc_volumes(host_name, 'swap', vm, [ds], vm.swap_disks.size)
                  swap_done = true
                  @cached_ds = ds
                  break
                elsif ds.real_free_space >= (vm.req_mem + vm.system_disks.size)
                  alloc_volumes(host_name, 'system', vm, [ds], vm.system_disks.size)
                  system_done = true
                  break if swap_done
                elsif ds.real_free_space < (vm.req_mem + vm.system_disks.size)&& ds.real_free_space>= vm.swap_disks.space
                  alloc_volumes(host_name, 'swap', vm, [ds], vm.swap_disks.size)
                  swap_done = true
                  break if system_done
                end
              end # end of ds_candidate traverse
              if !system_done || !swap_done
                Fog::Logger.deprecation("there is no enough space for vm #{vm.name} on host#{}") unless system_done && swap_done
                decommission(solution_list[host_name])
                solution_list.delete(host_name)
                break
              end

              # place data disks
              if vm.data_disks.shared && !(@host_list[host_name].share_datastores.empty?)
                datastore_candidates = @host_list[host_name].share_datastores.values.clone
              else
                datastore_candidates = @host_list[host_name].local_datastores.values.clone
              end
              datastore_candidates = datastore_candidates.sort {|x,y| x.real_free_space <=> y.real_free_space}
              sum = 0
              datastore_candidates.each {|x| sum += x.real_free_space }
              Fog::Logger.deprecation("there is no enough space for vm #{vm.name} on host#{host_name}") if sum < vm.data_disks.size
              data_done = false
              aum_size =0
              ds_num =0
              ds_arr =[]
              min_found = false
              min_ds_size = 0
              buffer_size = 1024
              datastore_candidates.each do |ds|
                if !(vm.datastore_pattern.nil?)
                  next unless isMatched?(ds.name, vm.datastore_pattern)
                end
                next if ds.real_free_space == 0
                if !min_found
                  min_ds_size = (ds.real_free_space - buffer_size)/2
                  min_found = true
                end
                if ds.real_free_space >= (vm.data_disks.size + buffer_size) && ds_num == 0
                  Fog::Logger.deprecation("fog: for vm #{vm.name} allocated - allsize = #{vm.data_disks.size} - #ds #{ds.name} with left size  #{@host_list[vm.host_name].local_datastores[ds.name].real_free_space}")
                  alloc_volumes(host_name, 'data', vm, [ds], vm.data_disks.size)
                  data_done = true
                  break
                else
                  ds_num +=1
                  req_size = aum_size + ds.real_free_space - buffer_size
                  if req_size > vm.data_disks.size &&  (vm.data_disks.size.to_i/ds_num) < min_ds_size
                    ds_arr << ds
                    Fog::Logger.deprecation("fog: for vm #{vm.name} allocated - avgsize =#{vm.data_disks.size/ds_num} - ds #{ds.name} with left size  #{@host_list[vm.host_name].local_datastores[ds.name].real_free_space}")
                    alloc_volumes(host_name, 'data', vm, ds_arr, vm.data_disks.size/ds_num)
                    data_done = true
                    break
                  elsif req_size > vm.data_disks.size &&  (vm.data_disks.size/ds_num) >= min_ds_size
                    Fog::Logger.deprecation("fog: for vm #{vm.name} allocated ds #{ds.name} - mini size = #{min_ds_size}- with left size  #{@host_list[vm.host_name].local_datastores[ds.name].real_free_space}")
                    alloc_volumes(host_name, 'data', vm, ds_arr, min_ds_size)
                    last_size = vm.data_disks.size - min_ds_size * (ds_arr.size)
                    alloc_volumes(host_name, 'data', vm, [ds], last_size)
                    data_done = true
                    break
                  else
                    aum_size += min_ds_size
                    ds_arr << ds
                  end
                end
              end # end of datastore traverse
              if !data_done
                Fog::Logger.deprecation("there is no enough space for vm #{vm.name} with on host#{host_name}")
                decommission(solution_list[host_name])
                solution_list.delete(host_name)
                break
              end
              solution_list[host_name] << vm
            end # end of vms traverse
          end  # end of hosts traverse
          recover_host_place_ds(solution_list)
          solution_list
        end

        def commission(vms)
          Fog::Logger.deprecation("enter commission methods[/]")
          original_size = @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum
          Fog::Logger.deprecation("original size = #{original_size}[/]")
          difference = 0
          vms.each do |vm|
            #vs = []
            #vs = vm.system_disks.volumes.values + vm.swap_disks.volumes.values + vm.data_disks.volumes.values

            vm.system_disks.volumes.values.each do |v|

              #Fog::Logger.deprecation("fog: commit system_disk of size-#{v.size} with fullpath-#{v.fullpath} on host-#{vm.host_name}[/]")
              if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += v.size
              end
              if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += v.size
              end
              #Fog::Logger.deprecation("fog: for vm.name=#{vm.name} after commit result - #{v.datastore_name} left size = #{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
            end

            vm.swap_disks.volumes.values.each do |v|
              #Fog::Logger.deprecation("commit swap_disk of size-#{v.size} with fullpath-#{v.fullpath} on host-#{vm.host_name}[/]")
              if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += v.size
              end
              if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += v.size
              end
              #Fog::Logger.deprecation("fog: for vm.name=#{vm.name} after commit result - #{v.datastore_name} left size = #{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
            end

            vm.data_disks.volumes.values.each do |v|
              Fog::Logger.deprecation("_________________________________________")
              if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                Fog::Logger.deprecation("fog: commit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += v.size
                Fog::Logger.deprecation("fog: for vm.name=#{vm.name} after commit result-#{v.datastore_name} local left size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
              end
              if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                Fog::Logger.deprecation("fog: commit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += v.size
                Fog::Logger.deprecation("fog: for vm.name=#{vm.name} after commit result-#{v.datastore_name} share left size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
              end
            end

          end

          Fog::Logger.deprecation("finish commission methods[/]")
          difference = original_size - @host_list[vms[0].host_name].local_sum - @host_list[vms[0].host_name].share_sum
          Fog::Logger.deprecation("commit size = #{difference}[/]")
          difference
        end


        def decommission(vms)
          Fog::Logger.deprecation("enter decommission methods[/]")
          original_size = @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum
          Fog::Logger.deprecation("original size = #{original_size}[/]")
          difference = 0
          vms.each do |vm|
            #vs = []
            #vs = vm.system_disks.volumes.values + vm.swap_disks.volumes.values + vm.data_disks.volumes.values

            vm.system_disks.volumes.values.each do |v|
              #Fog::Logger.deprecation("fog: for vm.name=#{vm.name}  decommit system_disk of size-#{v.size} with fullpath-#{v.fullpath} on host-#{vm.host_name}[/]")
              if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size
              end
              if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size
              end
              #Fog::Logger.deprecation("fog: for vm.name=#{vm.name} after decommit result - #{v.datastore_name} left size = #{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
            end

            vm.swap_disks.volumes.values.each do |v|
              #Fog::Logger.deprecation("fog: for vm.name=#{vm.name}  decommit swap_disk of size-#{v.size} with fullpath-#{v.fullpath} on host-#{vm.host_name}[/]")
              if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size
              end
              if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size
              end
             #Fog::Logger.deprecation("fog: for vm.name=#{vm.name}  afetr decommit for vm.name=#{vm.name} after commit result - #{v.datastore_name} left size = #{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
            end

            vm.data_disks.volumes.values.each do |v|
              Fog::Logger.deprecation("fog: for vm.name=#{vm.name} decommit data_disk of size-#{v.size} with fullpath-#{v.fullpath} on host-#{vm.host_name}[/]")
              if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size
              end
              if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size
              end
              Fog::Logger.deprecation("fog: for vm.name=#{vm.name} after decommit result - #{v.datastore_name} left size = #{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
            end
          end

          Fog::Logger.deprecation("finish decommission methods[/]")
          difference =  @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum - original_size
          Fog::Logger.deprecation("decommit size = #{difference}[/]")
          difference
        end

        def decommission1(vms)
          Fog::Logger.deprecation("enter decommission method[/]")
          original_size = @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum
          Fog::Logger.deprecation("original size = #{original_size}[/]")
          difference = 0
          vms.each do |vm|
            if vm.system_disks.shared
              vm.system_disks.volumes.values.each do |v|
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size
              end
            else
              vm.system_disks.volumes.values.each do |v|
                Fog::Logger.deprecation("de-commit system_disk of size-#{v.size} on host-#{vm.host_name} with full path-#{v.fullpath}[/]")
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size
              end
            end
            if vm.swap_disks.shared
              vm.swap_disks.volumes.values.each do |v|
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size
              end
            else
              vm.swap_disks.volumes.values.each do |v|
                Fog::Logger.deprecation("de-commit swap_disk of size-#{v.size} on host-#{vm.host_name} with fullpath-#{v.fullpath}[/]")
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size
              end
            end
            if vm.data_disks.shared
              vm.data_disks.volumes.values.each do |v|
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size
              end
            else
              vm.data_disks.volumes.values.each do |v|
                Fog::Logger.deprecation("de-commit data_disk of size-#{v.size} on host-#{vm.host_name} with fullpath-#{v.fullpath}[/]")
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size
              end
            end
          end
          Fog::Logger.deprecation("finish decommission methods[/]")
          difference = @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum - original_size
          Fog::Logger.deprecation("de-commit size = #{difference}[/]")
          difference
        end

        def recover_host_place_ds(solution_list)
          Fog::Logger.deprecation("enter recover method[/]")
          solution_list.keys.each do |host_name|
            vms = solution_list[host_name]
            decommission(vms)
          end # end of solution_list traverse
        end

        def create_volumes(vm)
          Fog::Logger.deprecation("enter into volumes_create methods with argument(vm.id = #{vm.id}, vm.host_name =#{vm.host_name})[/]")
          vs = []
          vs += vm.swap_disks.volumes.values
          vs += vm.data_disks.volumes.values.reverse
          response = {}
          recover = []
          collection = self.volumes
          begin
            vs.each do |v|
              params = {
                  'vm_mo_ref' => vm.id,
                  'mode' => v.mode,
                  'fullpath' => v.fullpath,
                  'size'=> v.size,
                  'datastore_name' => v.datastore_name
              }
              next if params['size'] <= 0
              recover << params
              v = collection.new(params)
              response = v.save
              if !response.has_key?('task_state') || response['task_state'] != "success"
                recover.pop
                recover.each do |v|
                  v = collection.new(params)
                  response = v.destroy
                end
                break
              end
            end
          rescue => e
            response['task_state'] = 'error'
            response['error_message'] = e.to_s
            recover.pop
            recover.each do |v|
              v = collection.new(params)
              response = v.destroy
            end
          end
          Fog::Logger.deprecation("finish volumes_create methods with argument(#{vm.host_name})[/]")
          response
        end

        def delete_volumes(vm)
          Fog::Logger.deprecation("enter into volumes_delete methods with argument(vm.id = #{vm.id}, vm.host_name = #{vm.host_name})[/]")
          vs = []
          vs += vm.swap_disks.volumes.values
          vs += vm.data_disks.volumes.values
          response = {}
          begin
            vs.each do |v|
              params = {
                  'vm_mo_ref' => vm.id,
                  'mode' => v.mode,
                  'fullpath' => v.fullpath,
                  'size'=> v.size,
                  'datastore_name' => v.datastore_name
              }
              collection = self.volumes
              v = collection.new(params)
              response = v.destroy
              if !response.has_key?('task_state') || response['task_state'] != "success"
                break
              else
                v = nil
              end
            end
          rescue RbVmomi::Fault => e
            response['task_state'] = 'error'
            response['error_message'] = e.to_s
          end
          Fog::Logger.deprecation("finish volumes_delete methods with argument(#{vm.host_name})[/]")
          response
        end

        private

        def authenticate
          begin
            @connection.serviceContent.sessionManager.Login :userName => @vsphere_username,
                                                            :password => @vsphere_password
          rescue RbVmomi::VIM::InvalidLogin => e
            raise Fog::Vsphere::Errors::ServiceError, e.message
          end
        end

        # Verify a SSL certificate based on the hashed public key
        def validate_ssl_connection
          pubkey = @connection.http.peer_cert.public_key
          pubkey_hash = Digest::SHA2.hexdigest(pubkey.to_s)
          expected_pubkey_hash = @vsphere_expected_pubkey_hash
          if pubkey_hash != expected_pubkey_hash then
            raise Fog::Vsphere::Errors::SecurityError, "The remote system presented a public key with hash #{pubkey_hash} but we're expecting a hash of #{expected_pubkey_hash || '<unset>'}.  If you are sure the remote system is authentic set vsphere_expected_pubkey_hash: <the hash printed in this message> in ~/.fog"
          end
        end

        def clone_array(arr_ds_res)
          results = []
          arr.each { |x| results << x.deep_clone }
          results
        end

        def alloc_volumes(host_name, type, vm, ds_res, size)
          vm.host_name = host_name
          ds_res.each do |ds|
            case type
              when "system"
                mode =  vm.system_disks.mode
                id = vm.id
              when "swap"
                mode =  vm.swap_disks.mode
                id = vm.id
              when "data"
                mode =  vm.data_disks.mode
                id = vm.id
              else
                mode =  vm.data_disks.mode
                id = vm.id
            end
            unit_number = vm.disk_index
            vm.disk_index +=1
            if ds.shared
              fullpath = "[#{ds.name}] #{vm.name}/shared#{unit_number}.vmdk"
            else
              fullpath = "[#{ds.name}] #{vm.name}/local#{unit_number}.vmdk"
            end
            vm.volume_add(type, id, mode, size, fullpath, ds.name, unit_number)
            ds.unaccounted_space += size.to_i
          end

        end

        def match_affinity(host_name, type, vm, datastore_candidates, size)
          datastore_candidates = datastore_candidates.sort {|x,y| y.real_free_space <=> x.real_free_space}
          sum = 0
          datastore_candidates.each {|x| sum += x.real_free_space }
          return "there is no enough space for vm #{vm.name} with all given hosts" if sum < size
          if type == "system"
            system_done = false
            swap_done = false
            datastore_candidates.each do |ds|
              if ds.real_free_space >= (vm.req_mem + vm.system_disks.size + vm.swap_disks.size)
                alloc_volumes(host_name, 'system', vm, [ds], vm.system_disks.size)
                system_done = true
                alloc_volumes(host_name, 'swap', vm, [ds], vm.swap_disks.size)
                swap_done = true
                break
              elsif ds.real_free_space >= (vm.req_mem + vm.system_disks.size)
                alloc_volumes(host_name, 'system', vm, [ds], vm.system_disks.size)
                system_done = true
                break if swap_done
              elsif ds.real_free_space < (vm.req_mem + vm.system_disks.size)&& ds.real_free_space>= vm.system_disks.size
                alloc_volumes(host_name, 'swap', vm, [ds], vm.swap_disks.size)
                swap_done = true
                break if system_done
              end
            end # end of ds_candidate traverse
            return "there is no enough space for vm #{vm.name} with all given hosts" unless system_done && swap_done
          else
            done = false
            datastore_candidates.each do |ds|
              if ds.real_free_space >= (size)
                alloc_volumes(host_name, type, vm, [ds], size)
                done  = true
                break
              else
                alloc_volumes(host_name, type, vm, [ds], ds.real_free_space)
                size -= ds.real_free_space
              end
            end # end of ds_candidate traverse
            return "there is no enough space for vm #{vm.name} with all given hosts" unless done
          end
        end

        def match_unti_affinity(host_name, type, vm, datastore_candidates, size)
          datastore_candidates = datastore_candidates.sort {|x,y| x.real_free_space <=> y.real_free_space}
          sum = 0
          datastore_candidates.each {|x| sum += x.real_free_space }
          return "there is no enough space for vm #{vm.name} with all given hosts" if sum < size
          done = false
          sum =0
          ds_num =0
          ds_arr =[]
          datastore_candidates.each do |ds|
            if ds.real_free_space >= size
              alloc_volumes(host_name, 'data', vm, [ds], size)
              done = true
            else
              sum +=ds.real_free_space
              ds_num +=1
              if sum >= vm.size &&  (size/ds_num)<= datastore_candidates[0].real_free_space
                ds_arr << ds
                alloc_volumes(host_name, type, vm, ds_arr, size/ds_num)
                done = true
                break
              elsif sum >= vm..size &&  (size/ds_num) > datastore_candidates[0].real_free_space
                alloc_volumes(host_name, type, vm, ds_arr, datastore_candidates[0].real_free_space)
                alloc_volumes(host_name, type, vm, [ds], (size-datastore_candidates[0].real_free_space*(ds_num-1)))
                done = true
                break
              else
                ds_arr << ds
              end
            end
          end # end of datastore traverse
          return "there is no enough space for vm #{vm.name} with all given hosts" unless done
          ds_arr
        end

      end  # end of real
    end
  end
end

module VagrantPlugins::CIBox
  class Provisioner < Vagrant.plugin("2", :provisioner)
    def provision
      Vagrant::Util::Subprocess.execute(
        "bash",
        "-c",
        "#{config.controller} #{config.playbook} #{ansible_args}",
        :workdir => @machine.env.root_path.to_s,
        :notify => [:stdout, :stderr],
        :env => environment_variables,
      ) do |io_name, data|
        @machine.env.ui.info(data, {
         :new_line => false,
         :prefix => false,
         :color => io_name == :stderr ? :red : :green,
       })
      end
    end

    protected

    def environment_variables
      environment_variables = {}
      environment_variables["ANSIBLE_SSH_ARGS"] = ansible_ssh_args
      environment_variables["ANSIBLE_HOSTS"] = ansible_hosts
      environment_variables["PATH"] = ENV["VAGRANT_OLD_ENV_PATH"]

      return environment_variables
    end

    def ansible_ssh_args
      ansible_ssh_args = []
      ansible_ssh_args << "-o ForwardAgent=yes" if @machine.ssh_info[:forward_agent]
      ansible_ssh_args << "-o StrictHostKeyChecking=no"
      ansible_ssh_args << ENV["ANSIBLE_SSH_ARGS"]

      return ansible_ssh_args.join(' ')
    end

    def ansible_args
      ansible_args = []
      ansible_args << "--limit=#{@machine.name}"
      ansible_args << ENV["ANSIBLE_ARGS"]

      return ansible_args.join(' ')
    end

    # Auto-generate "safe" inventory file based on Vagrantfile.
    def ansible_hosts
      inventory_content = "# Generated by CIBox\n"

      # By default, in Cygwin, user's home directory is "/home/<USERNAME>" and it is not the same
      # that "C:\Users\<USERNAME>". All used software (Ansible (~/.ansible), Vagrant (~/.vagrant.d),
      # Virtualbox (~/.VirtualBox), SSH (~/.ssh)) uses correct for Windows path and this breaks a
      # lot of Linux commands (chmod - one of them and we need to use to set correct permissions to
      # SSH private key).
      if Vagrant::Util::Platform.cygwin?
        ENV["HOME"] = Vagrant::Util::Subprocess.execute("cygpath", "-wH").stdout.chomp.gsub("\\", "/") + "/" + Etc.getlogin()
      end

      @machine.env.active_machines.each do |active_machine|
        begin
          m = @machine.env.machine(*active_machine)

          if !m.ssh_info.nil?
            inventory_content += "#{m.name} ansible_ssh_host=#{m.ssh_info[:host]} ansible_ssh_port=#{m.ssh_info[:port]} ansible_ssh_user=#{m.ssh_info[:username]} ansible_ssh_private_key_file=#{m.ssh_info[:private_key_path][0].gsub(ENV["HOME"], "~")}\n"
          else
            @logger.error("Auto-generated inventory: Impossible to get SSH information for machine '#{m.name} (#{m.provider_name})'. This machine should be recreated.")
            # Let a note about this missing machine
            inventory_content += "# MISSING: '#{m.name}' machine was probably removed without using Vagrant. This machine should be recreated.\n"
          end
        rescue Vagrant::Errors::MachineNotFound => e
          @logger.info("Auto-generated inventory: Skip machine '#{active_machine[0]} (#{active_machine[1]})', which is not configured for this Vagrant environment.")
        end
      end

      inventory_dir = Pathname.new(File.join(@machine.env.local_data_path.join, %w(provisioners cibox ansible)))
      FileUtils.mkdir_p(inventory_dir) unless File.directory?(inventory_dir)
      inventory_file = Pathname.new(File.join(inventory_dir, 'inventory'))

      Mutex.new.synchronize do
        if !File.exists?(inventory_file) or inventory_content != File.read(inventory_file)
          inventory_file.open('w') do |file|
            file.write(inventory_content)
          end
        end
      end

      return inventory_file
    end
  end
end

Vagrant.require_version '>= 2.1.5'

ENV['LC_ALL'] = 'en_US.UTF-8'

# Exit early in 2.1.2 due to bug: https://github.com/hashicorp/vagrant/issues/10013
#  https://github.com/hashicorp/vagrant/pull/10030
need_restart = false
unless ['plugin'].include? ARGV[0]
  [
    {
      name: 'vagrant-guests-clearlinux',
      version: '>= 1.1.3'
    }
  ].each do |plugin|
    next if Vagrant.has_plugin?(plugin[:name], plugin[:version])

    verb = 'install'
    verb = 'update' if Vagrant.has_plugin?(plugin[:name])
    system("vagrant plugin #{verb} #{plugin[:name]}", chdir: '/tmp') || exit!
    need_restart = true
  end
end

exec "vagrant #{ARGV.join(' ')}" if need_restart

Vagrant.configure(2) do |config|
  headless = ENV['HEADLESS'] || true
  OVMF = File.join(File.dirname(__FILE__), 'OVMF.fd').freeze
  name = 'clearlinux'

  config.vm.hostname = name.to_s
  config.vm.define :name.to_s
  config.vm.synced_folder '.', '/vagrant', disabled: true
  config.vm.box_check_update = false
  # always use Vagrants' insecure key
  config.ssh.insert_key = false
  config.ssh.username = 'clear'

  %w[vmware_workstation vmware_fusion vmware_desktop].each do |vmware_provider|
    config.vm.provider(vmware_provider) do |vmware|
      vmware.whitelist_verified = true
      vmware.gui = !headless

      {
        'cpuid.coresPerSocket' => '1',
        'memsize' => '2048',
        'numvcpus' => '2'
      }.each { |k, v| vmware.vmx[k.to_s] = v.to_s }

      (0..7).each do |n|
        vmware.vmx["ethernet#{n}.virtualDev"] = 'vmxnet3'
      end
    end
  end
  config.vm.provider 'virtualbox' do |vbox|
    vbox.gui = !headless
    vbox.linked_clone = false

    {
      '--memory' => 2048,
      '--vram' => 256,
      '--cpus' => 2,
      '--hwvirtex' => 'on'
    }.each { |k, v| vbox.customize ['modifyvm', :id, k.to_s, v.to_s] }

    (1..8).each do |n|
      vbox.customize ['modifyvm', :id, "--nictype#{n}", 'virtio']
    end
  end
  config.vm.provider 'libvirt' do |libvirt, override|
    override.trigger.before :provision, :up, :resume do |req|
      req.info = "Checking 'OVMF.fd' availability"
      req.run = {
        # the 'mkdir' bellow is needed otherwise using remote libvirt hosts will
        # fail. OTOH if talking to a remote libvirt host you'll need to reset
        # 'libvirt.loader' to whatever is the location of the UEFI firmware on
        # that host... in a ClearLinux host running libvirt that would be along:
        # "libvirt.loader = '/usr/share/qemu/OVMF.fd"
        inline: "bash -c '[[ -f #{OVMF} ]] || ( mkdir -p $(dirname #{OVMF}) && \
          curl https://download.clearlinux.org/image/OVMF.fd -o #{OVMF} )'"
      }
    end
    libvirt.loader = OVMF
    libvirt.driver = 'kvm'
    libvirt.cpu_mode = 'host-passthrough'
    libvirt.nested = true
    libvirt.memory = 2048
    libvirt.cpus = 2
    libvirt.video_vram = 256
    libvirt.channel target_name: 'org.qemu.guest_agent.0',
                    type: 'unix',
                    target_type: 'virtio'
  end
  if Vagrant.has_plugin?('vagrant-proxyconf')
    config.proxy.http = (ENV['http_proxy'] || ENV['HTTP_PROXY'])
    config.proxy.https = (ENV['https_proxy'] || ENV['HTTPS_PROXY'])
    config.proxy.no_proxy =
      (ENV['no_proxy'] || ENV['NO_PROXY'] || 'localhost,127.0.0.1')
    # since we're masking it by default ...
    config.proxy.enabled = { docker: false }
  end
end

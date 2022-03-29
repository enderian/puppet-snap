# frozen_string_literal: true

require 'puppet/provider/package'
require 'puppet_x/snap/api'

Puppet::Type.type(:package).provide :snap, parent: Puppet::Provider::Package do
  desc "Package management via Snap.

    This provider supports the `install_options` attribute, which allows snap's flags to be
    passed to Snap. Namely `classic`, `dangerous`, `devmode`, `jailmode`.
    
    The 'channel' install option is deprecated and will be removed in a future release.
  "

  commands snap_cmd: '/usr/bin/snap'
  has_feature :installable, :versionable, :install_options, :uninstallable, :purgeable
  confine feature: %i[net_http_unix_lib snapd_socket]

  def self.instances
    installed_snaps.map do |snap|
      new(name: snap['name'], ensure: snap['version'], provider: 'snap')
    end
  end

  def query
    self.class.instances.find { |it| it.name == @resource[:name] }
  end

  def install
    modify_snap('install', @resource[:install_options])
  end

  def update
    modify_snap('refresh', @resource[:install_options])
  end

  def latest
    params = URI.encode_www_form(name: @resource[:name])
    res = PuppetX::Snap::API.get("/v2/find?#{params}")
    raise Puppet::Error, "Couldn't find latest version" if res['status-code'] != 200

    # Search latest version for the specified channel. If channel is unspecified, fallback to latest/stable
    channel = determine_channel(@resource[:install_options])
    selected_channel = res['result'].first&.dig('channels', channel)
    raise Puppet::Error, "No version in channel #{channel}" unless selected_channel

    # Return version
    selected_channel['version']
  end

  def uninstall
    modify_snap('remove')
  end

  # Purge differs from remove as it doesn't save snapshot with snap's data.
  def purge
    modify_snap('remove', ['purge'])
  end

  def modify_snap(action, options = nil)
    req = self.class.generate_request(action, determine_channel(options), options)
    response = PuppetX::Snap::API.post("/v2/snaps/#{@resource[:name]}", req)
    change_id = PuppetX::Snap::API.get_id_from_async_req(response)
    PuppetX::Snap::API.complete(change_id)
  end

  def determine_channel(options = nil)
    channel = self.class.channel_from_ensure(@resource[:ensure])
    channel ||= self.class.channel_from_options(options) if options
    channel ||= 'latest/stable'
    channel
  end

  def self.generate_request(action, channel, options)
    request = { 'action' => action }
    request['channel'] = channel unless channel.nil?

    if options
      # classic, devmode and jailmode params are only
      # available for install, refresh, revert actions.
      case action
      when 'install', 'refresh', 'revert'
        request['classic'] = true if options.include?('classic')
        request['devmode'] = true if options.include?('devmode')
        request['jailmode'] = true if options.include?('jailmode')
      when 'remove'
        request['purge'] = true if options.include?('purge')
      end
    end

    request
  end

  def self.channel_from_ensure(value)
    value = value.to_s
    case value
    when 'present', 'absent', 'purged', 'installed', 'latest'
      nil
    else
      value
    end
  end

  def self.channel_from_options(options)
    options&.find { |e| %r{channel} =~ e }&.split('=')&.last&.tap do |ch|
      Puppet.warning("Install option 'channel' is deprecated, use ensure => '#{ch}' instead.")
    end
  end

  def self.installed_snaps
    res = PuppetX::Snap::API.get('/v2/snaps')
    raise Puppet::Error, "Could not find installed snaps (code: #{res['status-code']})" unless [200, 404].include?(res['status-code'])

    res['status-code'] == 200 ? res['result'].map { |hash| hash.slice('name', 'version') } : []
  end
end

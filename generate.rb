require 'json'
require 'open-uri'
require 'tmpdir'
require 'yaml'

require_relative 'appstreamer'
require_relative 'desktopfile'
require_relative 'downloader'

class Source
  def initialize(upstream_name)
    @upstream_name = upstream_name
  end

  def all_qml_depends
    @all_qml_depends ||= controls.collect do |control|
      control.binaries.collect do |binary|
        next nil unless runtime_binaries.include?(binary['package'])
        deps = binary.fetch('depends', []) + binary.fetch('recommends', [])
        deps.collect do |dep|
          dep = [dep[0]] if dep.size > 1
          next nil unless dep[0].name.start_with?('qml-module')
          dep = dep.each { |y| y.architectures = nil; y.version = nil; y.operator = nil }
          # puts "---> #{dep} ---> #{dep[0].substvar?}"
          dep = dep.reject(&:substvar?)
          dep.collect(&:to_s)
        end.compact
      end.flatten
    end.flatten
  end

  def dev_binaries
    dev_only(all_packages)
  end

  def runtime_binaries
    runtime_only(all_packages)
  end

  def all_build_depends
    @all_build_depends ||= controls.collect do |control|
      bdeps = control.source.fetch('build-depends', []) +
              control.source.fetch('build-depends-indep', [])
      bdeps.collect do |x|
        # TODO: this makes a bunch of assumptions as we have no proper
        #   resolver for dependencies. in alternates the first always wins
        #   architecture restrictions are entirely ignored
        x = [x[0]] if x.size > 1
        x = x.each { |y| y.architectures = nil; y.version = nil; y.operator = nil }
        x.collect(&:to_s)
      end.compact
    end.flatten
  end

  private

  def parse_control(src)
    system("apt-get --download-only source #{src}") || raise
    system('dpkg-source -x *.dsc source') || raise
    require_relative 'debian/control'
    control = Debian::Control.new('source')
    control.parse!
    control
  end

  def controls
    @controls ||= sources.collect do |src|
      Dir.mktmpdir do |tmpdir|
        Dir.chdir(tmpdir) do
          parse_control(src)
        end
      end
    end
  end


  def all_packages
    @all_packages ||= controls.collect do |control|
      control.binaries.collect { |x| x.fetch('package') }
    end.flatten
  end

  def dev_only(packages)
    packages.select do |pkg|
      pkg.include?('-dev') && !(pkg == 'qt5-qmake-arm-linux-gnueabihf')
    end
  end

  def runtime_only(packages)
    packages.delete_if do |pkg|
      pkg.include?('-dev') || pkg.include?('-doc') || pkg.include?('-dbg') ||
        pkg.include?('-examples') || pkg == 'qt5-qmake-arm-linux-gnueabihf'
    end
  end

  MAP = {
    'qt5' => %w(qtbase-opensource-src
                qtscript-opensource-src
                qtdeclarative-opensource-src
                qttools-opensource-src
                qtsvg-opensource-src
                qtx11extras-opensource-src),
    'kwallet' => %w(kwallet-kf5),
    'kdnssd' => [],
    'baloo' => %w(baloo-kf5),
    'kdoctools' => %w(kdoctools5),
    'kfilemetadata' => %w(kfilemetadata-kf5),
    'attica' => %w(attica-kf5),
    'kactivities' => %w(kactivities-kf5)
  }.freeze

  def sources
    MAP.fetch(@upstream_name, [@upstream_name])
  end
end

class SnapcraftConfig
  module AttrRecorder
    def attr_accessor(*args)
      record_readable(*args)
      super
    end

    def attr_reader(*args)
      record_readable(*args)
      super
    end

    def record_readable(*args)
      @readable_attrs ||= []
      @readable_attrs += args
    end

    def readable_attrs
      @readable_attrs
    end
  end

  module YamlAttributer
    def encode_with(c)
      c.tag = nil # Unset the tag to prevent clutter
      self.class.readable_attrs.each do |readable_attrs|
        next unless data = method(readable_attrs).call
        next if data.respond_to?(:empty?) && data.empty?
        c[readable_attrs.to_s.tr('_', '-')] = data
      end
      super(c) if defined?(super)
    end
  end

  class Part
    extend AttrRecorder
    prepend YamlAttributer

    # Array<String>
    attr_accessor :after
    # String
    attr_accessor :plugin
    # Array<String>
    attr_accessor :build_packages
    # Array<String>
    attr_accessor :stage_packages
    # Hash
    attr_accessor :filesets
    # Array<String>
    attr_accessor :stage
    # Array<String>
    attr_accessor :snap
    # Hash<String, String>
    attr_accessor :organize

    attr_accessor :source
    attr_accessor :configflags

    def initialize
      @after = []
      @plugin = 'nil'
      @build_packages = []
      @stage_packages = []
      @filesets = {
        'exclusion' => %w(
          -usr/lib/*/cmake/*
          -usr/include/*
          -usr/share/ECM/*
          -usr/share/doc/*
          -usr/share/man/*
          -usr/share/icons/breeze-dark*
          -usr/bin/X11
          -usr/lib/gcc/x86_64-linux-gnu/6.0.0
        )
      }
      @stage = []
      @snap = %w($exclusion)
      # @organize = {
      #   'etc/*' => 'slash/etc/',
      #   'usr/*' => 'slash/usr/'
      # }
    end
  end

  # This is really ContentSlot :/
  class Slot
    extend AttrRecorder
    prepend YamlAttributer

    attr_accessor :content
    attr_accessor :interface
    attr_accessor :read
  end

  class DBusSlot
    extend AttrRecorder
    prepend YamlAttributer

    attr_accessor :interface
    attr_accessor :name
    attr_accessor :bus

    def initialize
      @interface = 'dbus'
    end
  end

  class Plug
    extend AttrRecorder
    prepend YamlAttributer

    attr_accessor :content
    attr_accessor :interface
    attr_accessor :default_provider
    attr_accessor :target
  end

  class App
    extend AttrRecorder
    prepend YamlAttributer

    attr_accessor :command
    attr_accessor :plugs
  end

  extend AttrRecorder
  prepend YamlAttributer

  attr_accessor :name
  attr_accessor :version
  attr_accessor :summary
  attr_accessor :description
  attr_accessor :confinement
  attr_accessor :grade
  attr_accessor :apps
  attr_accessor :slots
  attr_accessor :plugs
  attr_accessor :parts

  def initialize
    @parts = {}
    @slots = {}
    @plugs = {}
    @apps = {}
  end
end

DEV_EXCLUSION = %w(cmake debhelper pkg-kde-tools).freeze
STAGED_DEV_PATH = 'http://build.neon.kde.org/job/kde-frameworks-5-release_amd64.snap/lastSuccessfulBuild/artifact/stage-dev.json'.freeze

source_name = File.read('appname').strip
source_version = nil
desktop_id = "org.kde.#{source_name}.desktop"
dev_stage = JSON.parse(open(STAGED_DEV_PATH).read)
dev_stage.reject! { |x| x.include?('doctools') }

config = SnapcraftConfig.new
config.name = source_name
config.summary = source_name
config.description = source_name
config.confinement = 'strict'
config.grade = 'stable'

FileUtils.mkpath('setup/gui')
appstreamer = AppStreamer.new(desktop_id)
appstreamer.expand(config)
icon_url = appstreamer.icon_url
File.write("setup/gui/icon#{File.extname(icon_url)}", open(icon_url).read)

desktopfile = nil
Dir.mktmpdir do |tmpdir|
  debfile = APT::Downloader.new(tmpdir).get(appstreamer.component.pkgname)
  deb = Deb.new(debfile)
  source_version = deb.upstream_version
  config.version = source_version
  deb.extract(tmpdir)
  desktoppath = Dir.glob("#{tmpdir}/usr/share/applications/**/#{desktop_id}")
  raise "not one desktop found [#{desktoppath}]" unless desktoppath.size == 1
  FileUtils.cp(desktoppath[0], 'setup/gui/')
  desktopfile = Desktopfile.new(desktoppath[0])
end

app = SnapcraftConfig::App.new
app.command = "kf5-launch #{source_name}"
app.plugs = %w(kde-frameworks-5-plug home x11 opengl network network-bind unity7 pulseaudio)
config.apps[source_name] = app

if desktopfile.dbus?
  slot = SnapcraftConfig::DBusSlot.new
  slot.name = desktopfile.service_name
  slot.bus = 'session'
  config.slots['session-dbus-interface'] = slot
end

plug = SnapcraftConfig::Plug.new
plug.content = 'kde-frameworks-5-all'
plug.interface = 'content'
plug.target = 'kf5'
plug.default_provider = 'kde-frameworks-5'
config.plugs['kde-frameworks-5-plug'] = plug

dev = SnapcraftConfig::Part.new
dev.plugin = 'dump'
dev.source = 'http://build.neon.kde.org/job/kde-frameworks-5-release_amd64.snap/lastSuccessfulBuild/artifact/kde-frameworks-5-dev_amd64.tar.xz'
# dev.source = '/home/me/Downloads/kde-frameworks-5-dev_amd64.tar.xz'
dev.stage_packages = []
dev.filesets = nil # no default sets needed
dev.snap = %w(-*)
config.parts['kde-frameworks-5-dev'] = dev

env = SnapcraftConfig::Part.new
env.plugin = 'dump'
env.source = 'https://github.com/apachelogger/kf5-snap-env.git'
env.filesets = nil # no default sets needed
env.snap = %w(kf5-launch kf5)
config.parts['kde-frameworks-5-env'] = env

source = Source.new(source_name)
source.all_build_depends

apppart = SnapcraftConfig::Part.new
apppart.after = %w(kde-frameworks-5-dev)
apppart.build_packages = (source.all_build_depends - dev_stage) - DEV_EXCLUSION + ['libpulse0']
apppart.stage_packages = (source.all_qml_depends - dev_stage)
apppart.stage = %w(-usr/bin/x11
                   -usr/lib/gcc/x86_64-linux-gnu/6.0.0)
apppart.configflags = %w(
  -DKDE_INSTALL_USE_QT_SYS_PATHS=ON
  -DCMAKE_INSTALL_PREFIX=/usr
  -DCMAKE_BUILD_TYPE=Release
  -DENABLE_TESTING=OFF
  -DBUILD_TESTING=OFF
  -DKDE_SKIP_TEST_SETTINGS=ON
)
apppart.plugin = 'cmake'
apppart.source = "http://download.kde.org/stable/applications/#{source_version}/src/#{source_name}-#{source_version}.tar.xz"
config.parts[source_name] = apppart

File.write('snapcraft.yaml', YAML.dump(config, indentation: 4))

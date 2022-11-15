# macOS
CLEAN.include("dmg/td-agent.icns")
CLEAN.include("dmg/td-agent.rsrc")
CLEAN.include("dmg/resources/pkg/Distribution.xml")
CLEAN.include("dmg/resources/pkg/scripts/postinstall")
CLEAN.include("dmg/resources/dmg/td-agent.osascript")
CLOBBER.include("dmg/*.pkg")
CLOBBER.include("dmg/*.dmg")
CLOBBER.include("dmg/td-agent.iconset")
CLOBBER.include("dmg/dmg")

class CompressDMG
  include Rake::DSL

  def initialize(version:, window_bounds:, pkg_position:, logger:)
    @version = version
    if RUBY_PLATFORM.include?("x86_64")
      @arch = "x86_64"
    elsif RUBY_PLATFORM.include?("arm64")
      @arch = "arm64"
    else
      fail "Unknown architecture: #{RUBY_PLATFORM}"
    end
    @window_bounds = window_bounds
    @pkg_position = pkg_position
    @dmg_temp_name = "rw.#{PACKAGE_NAME}-#{@version}-#{@arch}.dmg"
    @dmg_name = "#{PACKAGE_NAME}-#{@version}-#{@arch}.dmg"
    @pkg_name = "#{PACKAGE_NAME}-#{@version}.pkg"
    @volume_name = "#{PACKAGE_NAME}"
    @device = nil
    @osascript_path = File.join("resources", "dmg", "#{PACKAGE_NAME}.osascript")
    @logger = logger || Logger.new(STDOUT, level: Logger::Severity::INFO)
  end

  def clean_dmgs
    rm_f(@dmg_name)
    rm_f(@dmg_temp_name)
  end

  def clean_disks
    disks, error, status = Open3.capture3("mount | grep \"/Volumes/#{@volume_name}\" | awk '{print $1}'")
    unless status.success?
      fail "Failed to search mounted disks (stdout: #{disks}, stderr: #{error})"
    end
    disks.split("\n").each do |disk|
      disk.chomp!

      sh("hdiutil", "detach", disk)
    end
  end

  def create_rw_dmg
    sh("hdiutil",
       "create", "-ov",
       "-srcfolder", "dmg",
       "-format", "UDRW",
       "-volname", @volume_name,
       @dmg_temp_name)
  end

  def get_attached_rw_dmg
    device, error, status = Open3.capture3("hdiutil attach -readwrite -noverify -noautoopen #{@dmg_temp_name} | egrep '^/dev/' | sed 1q | awk '{print $1}'")
    @device = device.strip
    unless status.success?
      fail "Failed to attach disk image. (stdout: #{device}, stderr: #{error})"
    end
    sleep 5
  end

  def create_osascript
    apple_script = <<EOL
set found_disk to do shell script "ls /Volumes/ | grep '#{@volume_name}*'"

if found_disk is {} then
  set errormsg to "Disk " & found_disk & " not found"
  error errormsg
end if

tell application "Finder"
  reopen
  activate
  set selection to {}
  set target of Finder window 1 to found_disk
  set current view of Finder window 1 to icon view
  set toolbar visible of Finder window 1 to false
  set statusbar visible of Finder window 1 to false
  set the bounds of Finder window 1 to {#{@window_bounds}}
  tell disk found_disk
     set theViewOptions to the icon view options of container window
     set background picture of theViewOptions to file ".background:background.png"
     set arrangement of theViewOptions to not arranged
     set icon size of theViewOptions to 72
     set position of item "#{@pkg_name}" of container window to {#{@pkg_position}}
     delay 5
  end tell
end tell
EOL
    @logger.info("Generate #{@osascript_path}")
    File.open(@osascript_path, 'w', 0644) do |f|
      f.write(apple_script)
    end
  end

  def set_volume_icon
    icon = File.join("resources", "dmg", "icon.png")
    mkdir_p("#{PACKAGE_NAME}.iconset")

    sh("sips", "-z", "16", "16", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_16x16.png")
    sh("sips", "-z", "32", "32", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_16x16@2x.png")
    sh("sips", "-z", "32", "32", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_32x32.png")
    sh("sips", "-z", "64", "64", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_32x32@2x.png")
    sh("sips", "-z", "128", "128", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_128x128.png")
    sh("sips", "-z", "256", "256", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_128x128@2x.png")
    sh("sips", "-z", "256", "256", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_256x256.png")
    sh("sips", "-z", "512", "512", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_256x256@2x.png")
    sh("sips", "-z", "512", "512", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_512x512.png")
    sh("sips", "-z", "1024", "1024", "#{icon}", "--out", "#{PACKAGE_NAME}.iconset/icon_512x512@2x.png")
    sh("iconutil", "-c", "icns", "#{PACKAGE_NAME}.iconset")

    cp("#{PACKAGE_NAME}.icns", "/Volumes/#{@volume_name}/.VolumeIcon.icns")

    sh("SetFile", "-c", "icnC", "/Volumes/#{@volume_name}/.VolumeIcon.icns")
    sh("SetFile", "-a", "C", "/Volumes/#{@volume_name}")
  end

  def prettify_dmg
    bg_folder = "/Volumes/#{@volume_name}/.background"
    mkdir_p(bg_folder)
    cp(File.join("resources", "dmg", "background.png"), bg_folder)

    sh("osascript", @osascript_path)
  end

  def compress_dmg
    sh("chmod", "-Rf", "go-w", "/Volumes/#{@volume_name}")
    sh("sync")
    sh("sync")
    sh("hdiutil", "detach", @device)
    sh("hdiutil",
       "convert", @dmg_temp_name,
       "-format", "UDZO",
       "-imagekey", "zlib-level=9",
       "-o", @dmg_name)
  end

  def set_dmg_icon
    sh("sips", "-i", File.join("resources", "dmg", "icon.png"))
    sh("DeRez -only icns #{File.join('resources', 'dmg', 'icon.png')} > #{PACKAGE_NAME}.rsrc")
    sh("Rez", "-append", "#{PACKAGE_NAME}.rsrc", "-o", @dmg_name)
    sh("SetFile", "-a", "C", @dmg_name)
  end

  def verify_dmg
    sh("hdiutil", "verify", @dmg_name)
  end

  def remove_rw_dmg
    rm_f(@dmg_temp_name)
  end

  def run
    clean_disks
    clean_dmgs
    create_rw_dmg
    get_attached_rw_dmg
    sleep 5
    set_volume_icon
    create_osascript
    prettify_dmg
    compress_dmg
    set_dmg_icon
    verify_dmg
    remove_rw_dmg
  end
end

class MacOSPackageTask
  include Rake::DSL

  PKG_OUTPUT_DIR = ENV["TD_AGENT_PKG_OUTPUT_PATH"] || "."

  def initialize(logger:)
    @package = PACKAGE_NAME
    @version = PACKAGE_VERSION
    @staging_dir = STAGING_DIR
    @logger = logger || Logger.new(STDOUT, level: Logger::Severity::INFO)
  end

  def define
    namespace :dmg do
      desc "Build macOS package"
      task :selfbuild => [:"build:dmg_config", :"build:all"] do
        run_pkgbuild
      end
    end
  end

  def run_pkgbuild
    output_dir = PKG_OUTPUT_DIR
    ensure_directory(output_dir)

    cd("dmg") do
      # Build flat pkg installer
      sh("pkgbuild",
         "--root", STAGING_DIR,
         "--component-plist", File.join("resources", "pkg", "#{PACKAGE_NAME}.plist"),
         "--identifier", "com.treasuredata.tdagent",
         "--version", @version,
         "--scripts", File.join("resources", "pkg", "scripts"),
         "--install-location", "/",
         File.join(output_dir, "#{PACKAGE_NAME}.pkg"))

      # Build distributable pkg installer
      sh("productbuild",
         "--distribution", File.join("resources", "pkg", "Distribution.xml"),
         "--package-path", File.join(output_dir, "#{PACKAGE_NAME}.pkg"),
         "--resources", File.join("resources", "pkg", "assets"),
         File.join(output_dir, "#{PACKAGE_NAME}-#{@version}.pkg"))

      mkdir_p("dmg")
      cp(File.join(output_dir, "#{PACKAGE_NAME}-#{@version}.pkg"), "dmg")
      window_bounds = "100, 100, 750, 600"
      pkg_position = "535, 50"
      dmg = CompressDMG.new(version: @version, window_bounds: window_bounds, pkg_position: pkg_position, logger: @logger)
      dmg.run
    end
  end
end

# Windows
CLEAN.include("msi/env.bat")
CLEAN.include("msi/parameters.wxi")
CLEAN.include("msi/project-files.wxs")
CLEAN.include("msi/*.wixobj")
CLEAN.include("msi/*.wixpdb")
CLOBBER.include("msi/*.msi")

class WindowsPackageTask
  include Rake::DSL

  MSI_OUTPUT_DIR = ENV["TD_AGENT_MSI_OUTPUT_PATH"] || "."

  def initialize
    @package = PACKAGE_NAME
    @version = PACKAGE_VERSION
    @staging_dir = STAGING_DIR
  end

  def define
    namespace :msi do
      desc "Build MSI package (alias for msi:dockerbuild)"
      task :build do
        Rake::Task["msi:dockerbuild"].invoke
      end

      desc "Build MSI package without using Docker"
      task :selfbuild => [:"build:msi_config", :"build:all"] do
        run_build
      end

      desc "Build MSI package by Docker"
      task :dockerbuild => ["#{PACKAGE_NAME}-#{PACKAGE_VERSION}.tar.gz"] do
        run_docker("windows", arch)
      end
    end
  end

  private

  def run_build
    output_dir = MSI_OUTPUT_DIR.gsub(File::ALT_SEPARATOR, File::SEPARATOR)
    ensure_directory(output_dir)

    cd("msi") do
      # Pick up package contents
      sh(heat_path,
         "dir", @staging_dir,
         "-nologo", # Skip heat logo
         "-srd",    # Suppress harvesting the root directory as an element
         "-sreg",   # Suppress registry harvesting
         "-gg",                          # Generate guides
         "-cg", "ProjectDir",            # Component Group Name
         "-dr", "PROJECTLOCATION",       # Root directory reference
         "-var", "var.ProjectSourceDir", # Substitue File/@Source="SourceDir"
         "-t",   "exclude-files.xslt",   # XSLT for exclude files
         "-out", 'project-files.wxs')

      # Build
      sh(candle_path,
         "-nologo",                            # Skip candle logo
         "-dProjectSourceDir=#{@staging_dir}", # Define a parameter
         "-arch", "#{arch}",
         "project-files.wxs",
         "source.wxs")

      # Link
      sh(light_path,
         "-nologo",                        # Skip light logo
         "-ext", "WixUIExtension",         # Extension assembly
         "-ext", "WixUtilExtension",       # Enable QuietExec
         "-cultures:en-us",                # Localization
         "-loc", "localization-en-us.wxl", # Localization file
         "project-files.wixobj",
         "source.wixobj",
         "-out", File.join(output_dir, "#{@package}-#{@version}-#{arch}.msi"))
    end
  end

  def write_env
    env_bat = "msi/env.bat"
    File.open(env_bat, "w") do |file|
      file.puts(<<-ENV)
SET PACKAGE=#{@package}
SET VERSION=#{@version}
SET ARCH=#{arch}
      ENV
    end
  end

  # TODO: Unify with PackageTask
  def run_docker(os, architecture=nil)
    top_dir = File.expand_path('../.')
    id = os
    id = "#{id}-#{architecture}" if architecture
    docker_tag = "#{@package}-#{id}"
    build_command_line = [
      "docker",
      "build",
      "--tag", docker_tag,
    ]
    run_command_line = [
      "docker",
      "run",
      "--rm",
      "--tty",
      "--volume", "#{top_dir}:c:/fluent-package-builder:rw",
    ]
    docker_context = "msi"
    build_command_line << docker_context
    run_command_line.concat([docker_tag, "c:\\fluent-package-builder\\#{PACKAGE_NAME}\\msi\\build.bat"])

    write_env

    sh(*build_command_line)
    sh(*run_command_line)
  end

  def windows_path(*pieces)
    path = File.join(*pieces)
    if File::ALT_SEPARATOR
      path.gsub(File::SEPARATOR, File::ALT_SEPARATOR)
    else
      path
    end
  end

  def wix_dir
    dir = ENV["WIX"]
    fail "Can't find WiX commands path" if dir.nil? || dir.empty?
    dir
  end

  def wix_bin_dir
    windows_path(wix_dir, "bin")
  end

  def heat_path
    windows_path(wix_bin_dir, "heat")
  end

  def candle_path
    windows_path(wix_bin_dir, "candle")
  end

  def light_path
    windows_path(wix_bin_dir, "light")
  end

  def arch
    if RUBY_PLATFORM =~ /x64/
      "x64"
    elsif RUBY_PLATFORM =~ /i386/
      "x86"
    else
      fail "Unknown platform: #{RUBY_PLATFORM}"
    end
  end
end

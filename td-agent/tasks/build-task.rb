class BuildTask
  include Rake::DSL

  def initialize(task:, logger:)
    @download_task = task
    @logger = logger || Logger.new(STDOUT, level: Logger::Severity::INFO)
  end

  def make_wix_version_number(version)
    return version unless version.include?("~")
    revision = ""
    case version
    when /~rc(\d+)/
      revision = $1.to_i * 10000 + Time.now.hour
    when /~beta(\d+)/
      revision = $1.to_i * 1000 + Time.now.hour
    when /~alpha(\d+)/
      revision = $1.to_i * 100 + Time.now.hour
    else
      fail "Invalid version: #{version}"
    end
    if revision > 65534
      fail "revision must be an integer, from 0 to 65534: <#{revision}>"
    end
    "%s.%s" % [
      version.split("~", 2)[0].delete(".").to_i.pred.to_s.chars.join("."),
      revision
    ]
  end

  def define
    namespace :build do
      desc "Install jemalloc"
      task :jemalloc => [:"download:jemalloc"] do
        build_jemalloc
      end

      desc "Install OpenSSL"
      task :openssl => [:"download:openssl"] do
        if macos?
          build_openssl
          create_certs
        end
      end

      desc "Install Ruby"
      task :ruby => [:jemalloc, :openssl, :"download:ruby"] do
        build_ruby_from_source
      end

      desc "Install Ruby for Windows"
      task :rubyinstaller => [:"download:ruby", :"download:mingw_openssl"] do
        extract_ruby_installer
        apply_ruby_installer_patches
        replace_openssl_in_ruby_installer
        setup_windows_build_env
        find_and_put_dynamiclibs
      end

      desc "Install ruby gems"
      task :ruby_gems => [:"download:ruby_gems", :fluentd] do
        gem_install("bundler", BUNDLER_VERSION)

        gem_home = ENV["GEM_HOME"]
        ENV["GEM_HOME"] = gem_staging_dir
        ENV["INSTALL_GEM_FROM_LOCAL_REPO"] = "yes"
        sh(bundle_command, "_#{BUNDLER_VERSION}_", "install")
        # Ensure to install binstubs under /opt/td-agent/bin
        sh(gem_command, "pristine", "--only-executables", "--all", "--bindir", staging_bindir)
        ENV["GEM_HOME"] = gem_home

        # for fat gems which depend on nonexistent libraries
        # mainly for nokogiri 1.11 or later on CentOS 6
        rebuild_gems
      end

      desc "Install fluentd"
      task :fluentd => [:"download:fluentd", windows? ? :rubyinstaller : :ruby] do
        cd(DOWNLOADS_DIR) do
          archive_path = @download_task.file_fluentd_archive
          fluentd_dir = archive_path.sub(/\.tar\.gz$/, '')
          tar_options = ["--no-same-owner"]
          tar_options << "--force-local" if windows?
          sh(*tar_command, "xvf", archive_path, *tar_options) unless File.exists?(fluentd_dir)
          cd("fluentd-#{FLUENTD_REVISION}") do
            sh("rake", "build")
            setup_local_gem_repo
            install_gemfiles
          end
        end
      end

      desc "Install all gems"
      task :gems => [:ruby_gems]

      desc "Collect licenses of bundled softwares"
      task :licenses => [:gems] do
        install_jemalloc_license
        install_ruby_license
        install_td_agent_license
        collect_gem_licenses
      end

      desc "Install all components"
      task :all => [:licenses] do
        remove_needless_files
      end

      debian_pkg_scripts = ["preinst", "postinst", "postrm"]
      debian_pkg_scripts.each do |script|
        CLEAN.include(File.join("..", "debian", script))
      end

      desc "Create debian package script files from template"
      task :deb_scripts do
        # Note: "debian" directory in this directory isn't used dilectly, it's
        # copied to the top directory of fluent-package-builder in Docker container.
        # Since this task is executed in the container, package scripts should
        # be generated to the "debian" directory under the top directory
        # instead of this directory's one.
        debian_pkg_scripts.each do |script|
          src = template_path('package-scripts', PACKAGE_NAME, "deb", script)
          next unless File.exist?(src)
          dest = File.join("..", "debian", File.basename(script))
          render_template(dest, src, template_params, { mode: 0755 })
        end
      end

      desc "Create td-agent configuration files from template"
      task :td_agent_config do
        configs = [
          "etc/#{PACKAGE_NAME}/#{PACKAGE_NAME}.conf"
        ]
        configs.concat([
          "etc/logrotate.d/#{PACKAGE_NAME}",
          "opt/#{PACKAGE_NAME}/share/#{PACKAGE_NAME}-ruby.conf",
          "opt/#{PACKAGE_NAME}/share/#{PACKAGE_NAME}.conf.tmpl"
        ]) unless windows? || macos?
        configs.each do |config|
          src = template_path(config)
          if config == "etc/#{PACKAGE_NAME}/#{PACKAGE_NAME}.conf"
            src = template_path("opt/#{PACKAGE_NAME}/share/#{PACKAGE_NAME}.conf.tmpl")
          end
          dest = File.join(STAGING_DIR, config)
          render_template(dest, src, template_params)
        end
      end

      desc "Create systemd-tmpfiles configuration files from template"
      task :systemd_tmpfiles_config do
        configs = [
          "usr/lib/tmpfiles.d/#{PACKAGE_NAME}.conf",
        ]
        configs.each do |config|
          src = template_path(config)
          dest = File.join(STAGING_DIR, config)
          render_template(dest, src, template_params)
        end
      end

      desc "Create bin script files from template"
      task :bin_scripts do
        scripts = [
          "usr/bin/td",
          "usr/sbin/#{PACKAGE_NAME}",
          "usr/sbin/#{PACKAGE_NAME}-gem",
        ]
        scripts.each do |script|
          src = template_path("#{script}.erb")
          dest = if macos?
                   File.join(STAGING_DIR, File.join("opt", PACKAGE_NAME, script))
                 else
                   File.join(STAGING_DIR, script)
                 end
          render_template(dest, src, template_params, { mode: 0755 })
        end
      end

      desc "Create launchctl configuration files from template"
      task :launchctl_config do
        configs = [
          "#{PACKAGE_NAME}.plist",
        ]
        configs.each do |config|
          src = template_path("#{config}.erb")
          dest = File.join(STAGING_DIR, File.join("Library", "LaunchDaemons", config))
          render_template(dest, src, template_params)
        end
      end

      desc "Install additional .bat files for Windows"
      task :win_batch_files do
        ensure_directory(staging_bindir)
        cp("msi/assets/#{PACKAGE_NAME}-prompt.bat", td_agent_staging_dir)
        cp("msi/assets/#{PACKAGE_NAME}-post-install.bat", staging_bindir)
        cp("msi/assets/#{PACKAGE_NAME}.bat", staging_bindir)
        cp("msi/assets/#{PACKAGE_NAME}-gem.bat", staging_bindir)
        cp("msi/assets/#{PACKAGE_NAME}-version.rb", staging_bindir)
      end

      desc "Create systemd unit file for Red Hat like systems"
      task :rpm_systemd do
        dest =  File.join(STAGING_DIR, 'usr', 'lib', 'systemd', 'system', PACKAGE_NAME + ".service")
        params = {pkg_type: "rpm"}
        render_systemd_unit_file(dest, template_params(params))
        render_systemd_environment_file(template_params(params))
      end

      desc "Create sysv init file for Red Hat like systems"
      task :rpm_sysvinit do
        dest =  File.join(STAGING_DIR, 'etc', 'init.d', PACKAGE_NAME)
        params = {pkg_type: "rpm"}
        render_sysv_init_file(dest, template_params(params))
      end

      desc "Create systemd unit file for Debian like systems"
      task :deb_systemd do
        dest = File.join(STAGING_DIR, 'lib', 'systemd', 'system', PACKAGE_NAME + ".service")
        params = {pkg_type: "deb"}
        render_systemd_unit_file(dest, template_params(params))
        render_systemd_environment_file(template_params(params))
      end

      desc "Create config files for WiX Toolset"
      task :wix_config do
        src  = File.join('msi', 'parameters.wxi.erb')
        dest = File.join('msi', 'parameters.wxi')
        params = {wix_package_version: make_wix_version_number(PACKAGE_VERSION)}
        render_template(dest, src, template_params(params))
      end

      desc "Create config file for macOS Installer"
      task :pkgbuild_config do
        src  = File.join('dmg', 'resources', 'pkg', 'Distribution.xml.erb')
        dest = File.join('dmg', 'resources', 'pkg', 'Distribution.xml')
        params = {pkg_version: PACKAGE_VERSION}
        render_template(dest, src, template_params(params))
      end

      desc "Create pkg scripts for macOS Installer"
      task :pkgbuild_scripts do
        src  = File.join('dmg', 'resources', 'pkg', 'postinstall.erb')
        dest = File.join('dmg', 'resources', 'pkg', 'scripts', 'postinstall')
        params = {pkg_version: PACKAGE_VERSION}
        render_template(dest, src, template_params, { mode: 0755 })
      end

      desc "Create configuration files for Red Hat like systems with systemd"
      task :rpm_config => [:td_agent_config, :systemd_tmpfiles_config, :bin_scripts, :rpm_systemd]

      desc "Create configuration files for Red Hat like systems without systemd"
      task :rpm_old_config => [:td_agent_config, :bin_scripts, :rpm_sysvinit]

      desc "Create configuration files for Debian like systems"
      task :deb_config => [:td_agent_config, :systemd_tmpfiles_config, :bin_scripts, :deb_systemd, :deb_scripts]

      desc "Create configuration files for Windows"
      task :msi_config => [:td_agent_config, :wix_config, :win_batch_files]

      desc "Create configuration files for macOS"
      task :dmg_config => [:td_agent_config, :pkgbuild_scripts, :pkgbuild_config, :bin_scripts, :launchctl_config]
    end
  end

  private

  def render_systemd_unit_file(dest_path, config)
    template_file_path = template_path('etc', 'systemd', "#{PACKAGE_NAME}.service.erb")
    render_template(dest_path, template_file_path, config)
  end

  def render_systemd_environment_file(config)
    dest_path =
      if config[:pkg_type] == 'deb'
        File.join(STAGING_DIR, 'etc', 'default', PACKAGE_NAME)
      else
        File.join(STAGING_DIR, 'etc', 'sysconfig', PACKAGE_NAME)
      end
    template_file_path = template_path('etc', 'systemd', "#{PACKAGE_NAME}.erb")
    render_template(dest_path, template_file_path, config)
  end

  def render_sysv_init_file(dest_path, config)
    template_file_path = template_path('etc', 'init.d', "#{PACKAGE_NAME}.erb")
    render_template(dest_path, template_file_path, config, {mode: 0755})
  end

  def apply_ruby_patches
    return if BUNDLED_RUBY_PATCHES.nil?
    BUNDLED_RUBY_PATCHES.each do |patch|
      patch_name, version_condition = patch
      dependency = Gem::Dependency.new('', version_condition)
      if dependency.match?('', bundled_ruby_version)
        patch_path = File.join(__dir__, "..", "patches", patch_name)
        sh("patch", "-p1", "--input=#{patch_path}")
      end
    end
  end

  def build_jemalloc
    tarball = @download_task.file_jemalloc_source
    source_dir = tarball.sub(/\.tar\.bz2$/, '')

    sh(*tar_command, "xvf", tarball, "-C", DOWNLOADS_DIR)

    configure_opts = [
      "--prefix=#{install_prefix}",
    ]

    if JEMALLOC_VERSION.split('.')[0].to_i >= 4
      if ENV["TD_AGENT_STAGING_PATH"] and
        (ENV["TD_AGENT_STAGING_PATH"].end_with?("el8.aarch64") or
         ENV["TD_AGENT_STAGING_PATH"].end_with?("el7.aarch64"))
        # NOTE: There is a case that PAGE_SIZE detection on
        # CentOS 7 CentOS 8 with aarch64 AWS ARM instance.
        # So, explicitly set PAGE_SIZE by with-lg-page 16 (2^16 = 65536)
        configure_opts.concat(["--with-lg-page=16"])
      end
      if ENV["TD_AGENT_STAGING_PATH"] and
        ENV["TD_AGENT_STAGING_PATH"].end_with?("el8.ppc64le")
        # NOTE: There is a case that PAGE_SIZE detection on
        # CentOS 8 with ppc64le.
        # So, explicitly set PAGE_SIZE by with-lg-page 16 (2^16 = 65536)
        configure_opts.concat(["--with-lg-page=16"])
      end
    end

    cd(source_dir) do
      sh("./configure", *configure_opts)
      sh("make", "install", "-j#{Etc.nprocessors}", "DESTDIR=#{STAGING_DIR}")
    end
  end

  def openssldir
    File.join(staging_etcdir, "openssl")
  end

  def create_certs
    keychains = [
      "/System/Library/Keychains/SystemRootCertificates.keychain"
    ]

    cert_list, error, status = Open3.capture3("security find-certificate -a -p #{keychains.join(' ')}")
    unless status.success?
      fail "Failed to retrive certificates. (stdout: #{cert_list}, stderr: #{error})"
    end
    certs = cert_list.scan(
      /-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m
    )

    valid_certificates = certs.select do |cert|
      IO.popen("#{staging_bindir}/openssl x509 -inform pem -checkend 0 -noout > /dev/null", "w") do |ossl_io|
        ossl_io.write(cert)
        ossl_io.close_write
      end

      $?.success?
    end

    mkdir_p(openssldir)
    # Install cert.pem into install_prefix/etc/openssl and staging/opt/td-agent/etc/openssl/cert.pem.
    [File.join(openssldir, "cert.pem"), File.join(install_prefix, "etc", "openssl", "cert.pem")].each do |path|
      File.open(path, 'w', 0644) do |f|
        f.write(valid_certificates.join("\n") << "\n")
      end
    end
  end

  def build_openssl
    tarball = @download_task.file_openssl_source
    source_dir = tarball.sub(/\.tar\.gz$/, '')

    sh(*tar_command, "xvf", tarball, "-C", DOWNLOADS_DIR)

    configure_opts = [
      "--prefix=#{install_prefix}",
      "--openssldir=#{File.join("etc", "openssl")}",
      "no-tests",
      "no-unit-test",
      "no-comp",
      "no-idea",
      "no-mdc2",
      "no-rc5",
      "no-ssl2",
      "no-ssl3",
      "no-ssl3-method",
      "no-zlib",
      "shared",
    ]
    if RUBY_PLATFORM.include?("x86_64")
      arch_opts = ["darwin64-x86_64-cc"]
    elsif RUBY_PLATFORM.include?("arm64")
      arch_opts = ["darwin64-arm64-cc"]
    else
      fail "Unknown architecture: #{RUBY_PLATFORM}"
    end

    cd(source_dir) do
      # Currently, macOS only.
      sh("perl", "./Configure", *(configure_opts + arch_opts))
      sh("make", "depend")
      sh("make")
      # For building rdkafka gem. The built openssl library for built Ruby cannot use without install.
      sh("make", "install")
      sh("make", "install", "DESTDIR=#{STAGING_DIR}")
    end
  end

  def build_ruby_from_source
    tarball = if use_ruby3?
                @download_task.file_ruby3_source
              else
                @download_task.file_ruby_source
              end
    ruby_source_dir = tarball.sub(/\.tar\.gz$/, '')

    sh(*tar_command, "xvf", tarball, "-C", DOWNLOADS_DIR)

    configure_opts = [
      "--prefix=#{install_prefix}",
      "--enable-shared",
      "--disable-install-doc",
      "--with-compress-debug-sections=no", # https://bugs.ruby-lang.org/issues/12934
    ]
    if macos?
      configure_opts.push("--without-gmp")
      configure_opts.push("--without-gdbm")
      configure_opts.push("--without-tk")
      configure_opts.push("-C")
      configure_opts.push("--with-openssl-dir=#{File.join(STAGING_DIR, install_prefix)}")
    end
    cd(ruby_source_dir) do
      apply_ruby_patches
      sh("./configure", *configure_opts)
      sh("make", "install", "-j#{Etc.nprocessors}", "DESTDIR=#{STAGING_DIR}")

      # For building gems. The built ruby & gem command cannot use without install.
      sh("make", "install")
    end
  end

  def extract_ruby_installer
    ensure_directory(td_agent_staging_dir) do
      path = File.expand_path(@download_task.file_ruby_installer_x64)
      src_dir = File.basename(path).sub(/\.7z$/, '')
      sh("7z",
         "x",    # Extract files with full paths
         "-y",   # Assume yes on all queries
         path)
      cp_r(Dir.glob(File.join(src_dir, "*")), ".")
      rm_rf(src_dir)
    end
  end

  def apply_ruby_installer_patches
    return if BUNDLED_RUBY_INSTALLER_PATCHES.nil?

    ruby_version = BUNDLED_RUBY_INSTALLER_X64_VERSION.sub(/-\d+$/, '')
    feature_version = ruby_version.sub(/\d+$/, '0')
    ruby_lib_dir = File.join(td_agent_staging_dir, "lib", "ruby", feature_version)

    BUNDLED_RUBY_INSTALLER_PATCHES.each do |patch|
      patch_name, version_condition = patch
      dependency = Gem::Dependency.new('', version_condition)
      if dependency.match?('', ruby_version)
        patch_path = File.join(__dir__, "..", "patches", patch_name)
        cd(ruby_lib_dir) do
          sh("ridk", "exec", "patch", "-p2", "--input=#{patch_path}")
        end
      end
    end
  end

  # Fix memory leak in OpenSSL: https://github.com/fluent/fluent-package-builder/issues/374
  def replace_openssl_in_ruby_installer
    tarball = @download_task.file_mingw_openssl
    sh(*tar_command, "xvf", tarball, "-C", DOWNLOADS_DIR, "--force-local")
    source_dir = File.join(DOWNLOADS_DIR, "mingw64", "bin")
    ensure_directory(td_agent_staging_dir) do
      dest_dir = File.join(".", "bin", "ruby_builtin_dlls")
      cp(File.join(source_dir, "libcrypto-1_1-x64.dll"), dest_dir)
      cp(File.join(source_dir, "libssl-1_1-x64.dll"), dest_dir)
    end
    rm_rf(source_dir)
  end

  def find_and_put_dynamiclibs
    begin
      require 'ruby_installer/runtime'

      # These dlls are required to put in staging_bindir to run C++ based extension
      # included gem such as winevt_c. We didn't find how to link them statically yet.
      dlls = [
        "libstdc++-6",
      ]
      dlls.each do |dll|
        mingw_bin_path = RubyInstaller::Runtime.msys2_installation.mingw_bin_path
        windows_path = "#{mingw_bin_path}/#{dll}.dll"
        if File.exist?(windows_path)
          copy windows_path, staging_bindir
        else
          raise "Cannot find required DLL needed for dynamic linking: #{windows_path}"
        end
      end
    rescue LoadError
      raise "Cannot load RubyInstaller::Runtime class"
    end
  end

  def setup_windows_build_env
    sh("#{td_agent_staging_dir}/bin/ridk", "install", "3")
  end

  def install_prefix
    "/opt/#{PACKAGE_NAME}"
  end

  def td_agent_staging_dir
    # The staging directory on windows doesn't have install_prefix,
    # it's added by the installer.
    if windows?
      STAGING_DIR
    else
      File.join(STAGING_DIR, install_prefix)
    end
  end

  def staging_bindir
    File.join(td_agent_staging_dir, "bin")
  end

  def staging_etcdir
    File.join(td_agent_staging_dir, "etc")
  end

  def staging_sharedir
    File.join(td_agent_staging_dir, "share")
  end

  def gem_command
    if windows?
      File.join(staging_bindir, "gem")
    else
      # On GNU/Linux we don't use gem command in staging path, use the one
      # installed in the proper path instead since Ruby doesn't support
      # running without install (although there are some solutions like rbenv).
      "#{install_prefix}/bin/gem"
    end
  end

  def bundle_command
    File.join(staging_bindir, "bundle")
  end

  def gem_dir_version
    if windows?
      ruby_version = BUNDLED_RUBY_INSTALLER_X64_VERSION
    else
      ruby_version = bundled_ruby_version
    end
    rb_major, rb_minor, rb_teeny = ruby_version.split("-", 2).first.split(".", 3)
    "#{rb_major}.#{rb_minor}.0" # gem path's teeny version is always 0
  end

  def licenses_staging_dir
    File.join(td_agent_staging_dir, "LICENSES")
  end

  def gem_staging_dir
    gemdir = `#{gem_command} env gemdir`.strip
    fail "Failed to get default installation directory for gems!" unless $?.success?

    if windows?
      expected    = File.join(td_agent_staging_dir, gem_dir_suffix)
      staging_dir = expected
    else
      expected    = File.join(install_prefix,       gem_dir_suffix)
      staging_dir = File.join(td_agent_staging_dir, gem_dir_suffix)
    end
    fail "Unsupposed gemdir: #{gemdir} (expected: #{expected})" unless gemdir == expected

    staging_dir
  end

  def gem_install(gem_path, version = nil, platform: nil)
    ensure_directory(staging_bindir)
    ensure_directory(gem_staging_dir)

    gem_home = ENV["GEM_HOME"]
    ENV["GEM_HOME"] = gem_staging_dir

    gem_installation_command = [
      gem_command, "install",
      "--no-document",
      "--bindir", staging_bindir,
      gem_path
    ]
    if version
      gem_installation_command << "--version"
      gem_installation_command << version
    end
    if platform
      gem_installation_command << "--platform"
      gem_installation_command << platform
    end
    if macos? && gem_path.include?("rdkafka")
      ENV["CPPFLAGS"] = "-I#{File.join(STAGING_DIR, install_prefix, 'include')}"
      ENV["LDFLAGS"] = "-L#{File.join(STAGING_DIR, install_prefix, 'lib')}"
    end
    # digest-crc gem causes rake executable conflict due to rake runtime dependency
    # and bundled rake gem on Ruby Installer.
    if windows? && gem_path.include?("rake")
      gem_installation_command.push("--force")
    end
    @logger.info("install: <#{gem_path}>")
    sh(*gem_installation_command)

    ENV["GEM_HOME"] = gem_home
  end

  def gem_uninstall(gem, version = nil)
    ensure_directory(staging_bindir)
    ensure_directory(gem_staging_dir)

    gem_home = ENV["GEM_HOME"]
    ENV["GEM_HOME"] = gem_staging_dir

    gem_uninstallation_command = [
      gem_command, "uninstall",
      "--bindir", staging_bindir,
      "--silent",
      gem
    ]
    if version
      gem_uninstallation_command << "--version"
      gem_uninstallation_command << version
    else
      gem_uninstallation_command << "--all"
    end
    @logger.info("uninstall: <#{gem}>")
    sh(*gem_uninstallation_command)

    ENV["GEM_HOME"] = gem_home
  end

  def rebuild_gems
    return unless ENV["REBUILD_GEMS"]

    require 'bundler'
    ENV["REBUILD_GEMS"].split((/\s+/)).each do |gem_name|
      d = Bundler::Definition.build('Gemfile', 'Gemfile.lock', false)
      version = d.locked_deps[gem_name].requirement.requirements[0][1].version
      gem_uninstall(gem_name)
      gem_install(gem_name, version, platform: "ruby")
    end
  end

  def install_jemalloc_license
    return if windows?
    ensure_directory(licenses_staging_dir) do
      tarball = @download_task.file_jemalloc_source
      source_dir = File.basename(tarball.sub(/\.tar\.bz2$/, ''))
      license_file = File.join(source_dir, "COPYING")
      tar_options = []
      tar_options << "--force-local" if windows?
      sh(*tar_command, "xf", tarball, license_file, *tar_options)
      mv(license_file, "LICENSE-jemalloc.txt")
      rm_rf(source_dir)
    end
  end

  def install_ruby_license
    ensure_directory(licenses_staging_dir) do
      if windows?
        src  = File.join(td_agent_staging_dir, "LICENSE.txt")
        mv(src, "LICENSE-RubyInstaller.txt")
      end
      tarball = @download_task.file_ruby_source
      ruby_source_dir = File.basename(tarball.sub(/\.tar\.gz$/, ''))
      license_file = File.join(ruby_source_dir, "COPYING")
      tar_options = []
      tar_options << "--force-local" if windows?
      sh(*tar_command, "xf", tarball, license_file, *tar_options)
      mv(license_file, "LICENSE-Ruby.txt")
      rm_rf(ruby_source_dir)
    end
  end

  def install_td_agent_license
    ensure_directory(licenses_staging_dir)
    src = File.join(__dir__, "..", "..", "LICENSE")
    dest = File.join(licenses_staging_dir, "LICENSE-#{PACKAGE_NAME}.txt")
    cp(src, dest)
  end

  def install_gemfiles
    ensure_directory(staging_sharedir) do
      ["Gemfile", "Gemfile.lock", "config.rb"].each do |file|
        source_dir = File.join(__dir__, "..", "..")
        src = File.join(source_dir, "#{PACKAGE_NAME}/#{file}")
        dest = File.join(staging_sharedir, file)
        cp(src, dest)
      end
    end
  end

  def setup_local_gem_repo
    local_repo_dir = FLUENTD_LOCAL_GEM_REPO.sub("file://", "")
    local_gems_dir = File.join(local_repo_dir, "gems")
    FileUtils.mkdir_p(local_gems_dir)
    Find.find("pkg") do |entry|
      next unless entry.end_with?(".gem")
      FileUtils.cp(entry, local_gems_dir)
    end
    cd(local_repo_dir) do
      sh("gem", "generate_index")
    end
  end

  def collect_gem_licenses
    @logger.info("Collecting licenses of gems...")

    env_restore = ENV["GEM_PATH"]
    ENV["GEM_PATH"] = gem_staging_dir
    command = "#{gem_command} list -d"
    output, error, status = Open3.capture3(command)
    unless status.success?
      fail "Failed to get gem list: <#{command}> (stdout: #{output}, stderr: #{error})"
    end
    gems_descriptions = output
    gems_descriptions.gsub!(STAGING_DIR, "") unless windows?
    ENV["GEM_PATH"] = env_restore

    ensure_directory(licenses_staging_dir) do
      File.open("LICENSES-gems.txt", 'w', 0644) do |f|
        f.write(gems_descriptions)
      end
    end
  end

  def remove_files(pattern, recursive=false)
    files = Dir.glob(pattern)
    return if files.empty?
    if recursive
      rm_rf(files)
    else
      rm_f(files)
    end
  end

  def remove_needless_files
    remove_files("#{td_agent_staging_dir}/bin/jeprof", true) # jemalloc 4 or later
    remove_files("#{td_agent_staging_dir}/bin/pprof", true) # jemalloc 3
    remove_files("#{td_agent_staging_dir}/share/doc", true) # Contains only jemalloc.html
    remove_files("#{td_agent_staging_dir}/share/ri", true)
    cd("#{gem_staging_dir}/cache") do
      remove_files("*.gem")
      remove_files("bundler", true)
    end
    Dir.glob("#{gem_staging_dir}/gems/*").each do |gem_dir|
      cd(gem_dir) do
        rm_rf(["test", "tests", "spec"])
        remove_files("**/gem.build_complete")
        remove_files("ext/**/a.out")
        remove_files("ext/**/*.{o,la,a}")
        remove_files("ext/**/.libs", true)
        remove_files("ext/**/tmp", true)
        remove_files("ports", true) if gem_dir.start_with?("#{gem_staging_dir}/gems/cmetrics-")
      end
    end
    Dir.glob("#{td_agent_staging_dir}/lib/lib*.a").each do |static_library|
      unless static_library.end_with?(".dll.a")
        rm_f(static_library)
      end
    end
    Dir.glob("#{td_agent_staging_dir}/**/.git").each do |git_dir|
      remove_files(git_dir, true)
    end
  end
end

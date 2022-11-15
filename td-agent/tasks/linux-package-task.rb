require_relative '../../lib/package-task'

# Debian
CLEAN.include("apt/tmp")
CLEAN.include("apt/build.sh")
CLEAN.include("apt/env.sh")
CLEAN.include("debian/tmp")
CLOBBER.include("apt/repositories")

# Red Hat
CLEAN.include("yum/tmp")
CLEAN.include("yum/build.sh")
CLEAN.include("yum/env.sh")
CLOBBER.include("yum/repositories")

class LinuxPackageTask < PackageTask
  def initialize(download_task)
    @download_task = download_task
    super(PACKAGE_NAME, PACKAGE_VERSION, detect_release_time)
    @archive_tar_name = "#{@package}-#{@version}.tar"
    @archive_name = "#{@archive_tar_name}.gz"
    CLEAN.include(@archive_name)
  end

  private

  def define_archive_task
    repo_files = `git ls-files --full-name`.split("\n").collect do |path|
      File.join("..", path)
    end

    debian_copyright_file = File.join("#{PACKAGE_NAME}", "debian", "copyright")
    file debian_copyright_file do
      build_copyright_file
    end

    debian_include_binaries_file = File.join("#{PACKAGE_NAME}", "debian", "source", "include-binaries")
    file debian_include_binaries_file do
      build_include_binaries_file
    end

    # TODO: Probably debian related files should be built in the build container
    file @archive_name => [*repo_files, *@download_task.files, debian_copyright_file, debian_include_binaries_file] do
      build_archive
    end
  end

  def build_copyright_file
    # Note: maintain debian/copyright manually is inappropriate way because
    # many gem is bundled with td-agent package.
    # We use gem specification GEMFILE to solve this issue.
    src = File.join("templates", "package-scripts", "#{PACKAGE_NAME}", "deb", "copyright")
    dest = File.join("debian", "copyright")
    licenses = []
    @download_task.files_ruby_gems.each do |gem_file|
      command = "gem specification #{gem_file}"
      output, error, status = Open3.capture3(command)
      unless status.success?
        fail "Failed to get gem specification: <#{gem_file}> (stdout: #{output}, stderr: #{error})"
      end
      spec = YAML.safe_load(output,
                            permitted_classes: [
                              Time,
                              Symbol,
                              Gem::Specification,
                              Gem::Version,
                              Gem::Dependency,
                              Gem::Requirement])
      relative_path = gem_file.sub(/#{Dir.pwd}\//, "")
      unless spec.licenses.empty?
        spdx_compatible_license = spec.licenses.first.sub(/Apache 2\.0/, "Apache-2.0")
                                    .sub(/Apache License Version 2\.0/, "Apache-2.0")
                                    .sub(/BSD 2-Clause/, "BSD-2-Clause")
        license = <<-EOS
Files: #{relative_path}
Copyright: #{spec.authors.join(",")}
License: #{spdx_compatible_license}
EOS
        licenses << license
      else
        # Note: remove this conditions when gem.licenses in gemspec was fixed in upstream
        case spec.name
        when "cool.io", "async-pool", "ltsv"
          license = "MIT"

        when "td", "webhdfs", "td-logger", "fluent-config-regexp-type"
          license = "Apache-2.0"
        end
        licenses <<= <<-EOS
Files: #{relative_path}
Copyright: #{spec.authors.join(",")}
License: #{license}
EOS
      end
    end
    params = {
      bundled_gem_licenses: licenses.join("\n"),
      bundled_ruby_version: BUNDLED_RUBY_VERSION
    }
    render_template(dest, src, template_params(params))
  end

  def build_include_binaries_file
    # Note: maintain debian/source/include-binaries manually is inappropriate way
    # because many gem files are bundled with td-agent package.
    # We use gem specification GEMFILE to solve this issue.
    paths = []
    command = "bundle config set --local cache_path #{DOWNLOADS_DIR}"
    output, error, status = Open3.capture3(command)
    unless status.success?
      fail "Failed to set cache_path: <#{command}> (stdout: #{output}, stderr: #{error})"
    end
    # Note: bundle package try to require sudo when path is not set
    command = "bundle config set --local path vendor"
    output, error, status = Open3.capture3(command)
    unless status.success?
      fail "Failed to set dummy path: <#{command}> (stdout: #{output}, stderr: #{error})"
    end
    Dir.chdir(gemfile_dir) do
      command = "bundle package --no-install"
      output, error, status = Open3.capture3(command)
      unless status.success?
        fail "Failed to download gem files: <#{command}> (stdout: #{output}, stderr: #{error})"
      end
    end
    Dir.glob("#{DOWNLOADS_DIR}/*.gem") do |path|
      paths << path.sub(Dir.pwd, "#{PACKAGE_NAME}")
    end
    ensure_directory("debian/source") do
      File.open("include-binaries", "w+") do |file|
        file.puts(paths.sort.uniq.join("\n"))
      end
    end
  end

  def build_archive
    cd("..") do
      sh("git", "archive", "HEAD",
         "--prefix", "#{@archive_base_name}/",
         "--output", @full_archive_name)
      tar_options = []
      tar_options << "--force-local" if windows?
      sh(*tar_command, "xvf", @full_archive_name, *tar_options)
      @download_task.files.each do |path|
        src_path = Pathname(path)
        dest_path = Pathname(DOWNLOADS_DIR)
        relative_path = src_path.relative_path_from(dest_path)
        dest_downloads_dir = "#{@archive_base_name}/#{PACKAGE_NAME}/downloads"
        dest_dir = "#{dest_downloads_dir}/#{File.dirname(relative_path)}"
        ensure_directory(dest_dir)
        # TODO: When a tarball is create on a host OS that is different from a target,
        # mismatched fat gems are included unexpectedly. To avoid it, remove gems from
        # the archive and let the build container to download them.
        # Although we should remove dependency to gems, they are still required to
        # build debian/copyright. Probably it should be built in the build container.
        cp_r(path, dest_dir) unless path.end_with?(".gem")
      end
      cp_r("#{PACKAGE_NAME}/debian/copyright", "#{@archive_base_name}/#{PACKAGE_NAME}/debian/copyright")
      tar_options = []
      tar_options << "--force-local" if windows?
      sh(*tar_command, "cvfz", @full_archive_name, @archive_base_name, *tar_options)
      rm_rf(@archive_base_name)
    end
  end

  def apt_targets_default
    [
      "debian-buster",
      "debian-bullseye",
      "ubuntu-bionic",
      "ubuntu-focal",
      "ubuntu-jammy",
    ]
  end

  def yum_targets_default
    [
      "centos-7",
      "rockylinux-8",
      "almalinux-9",
      "amazonlinux-2",
    ]
  end

  private
  def detect_release_time
    release_time_env = ENV["TD_AGENT_RELEASE_TIME"]
    if release_time_env
      Time.parse(release_time_env).utc
    else
      Time.now.utc
    end
  end
end

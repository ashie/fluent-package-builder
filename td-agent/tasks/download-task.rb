class DownloadTask
  include Rake::DSL

  attr_reader :file_jemalloc_source
  attr_reader :file_ruby_source, :file_ruby3_source, :file_ruby_installer_x64
  attr_reader :file_fluentd_archive
  attr_reader :files_ruby_gems
  attr_reader :file_openssl_source, :file_mingw_openssl

  def initialize(logger:)
    @logger = logger || Logger.new(STDOUT, level: Logger::Severity::INFO)
  end

  def files
    [
      @file_jemalloc_source,
      @file_openssl_source,
      @file_mingw_openssl,
      @file_ruby_source,
      @file_ruby3_source,
      @file_ruby_installer_x64,
      @file_fluentd_archive,
      *@files_ruby_gems
    ]
  end

  def define
    define_jemalloc_file
    define_ruby_files
    define_fluentd_archive
    define_gem_files
    define_openssl_file
    define_mingw_openssl_file

    namespace :download do
      desc "Download jemalloc source"
      task :jemalloc => [@file_jemalloc_source]

      desc "Download Ruby source"
      task :ruby => [@file_ruby_source, @file_ruby3_source, @file_ruby_installer_x64]

      desc "Clone fluentd repository and create a tarball"
      task :fluentd => @file_fluentd_archive

      desc "Download ruby gems"
      task :ruby_gems => @files_ruby_gems

      desc "Download openssl source"
      task :openssl => @file_openssl_source

      desc "Download MinGW's openssl package"
      task :mingw_openssl => @file_mingw_openssl
    end
  end

  private

  def download_file(url, filename, sha256sum = nil)
    tmp_filename = "#{filename}.part"

    ensure_directory(DOWNLOADS_DIR) do
      @logger.info("Downloading #{filename}...")
      URI.open(url) do |in_file|
        File.open(tmp_filename, "wb") do |out_file|
          out_file.write(in_file.read)
        end
      end

      unless sha256sum.nil?
        digest = Digest::SHA256.file(tmp_filename)
        if digest != sha256sum
          fail "
          sha256sum of #{filename} did not matched!!!
            expected: #{sha256sum}
            actual:   #{digest}
          "
        end
      end

      mv(tmp_filename, filename)
    end
  end

  def define_jemalloc_file
    version = JEMALLOC_VERSION
    filename = "jemalloc-#{version}.tar.bz2"
    url_base = "https://github.com/jemalloc/jemalloc/releases/download/"
    @file_jemalloc_source = File.join(DOWNLOADS_DIR, filename)
    file @file_jemalloc_source do
      url = "#{url_base}/#{version}/#{filename}"
      download_file(url, filename)
    end
  end

  def define_openssl_file
    version = OPENSSL_VERSION
    filename = "openssl-#{version}.tar.gz"
    url_base = "https://www.openssl.org/source/"
    @file_openssl_source = File.join(DOWNLOADS_DIR, filename)
    file @file_openssl_source do
      url = "#{url_base}/#{filename}"
      download_file(url, filename)
    end
  end

  def define_ruby_files
    define_ruby_source_file
    define_ruby_installer_file
  end

  def define_ruby_source_file
    [[BUNDLED_RUBY_VERSION, BUNDLED_RUBY_SOURCE_SHA256SUM],
     [BUNDLED_RUBY3_VERSION, BUNDLED_RUBY3_SOURCE_SHA256SUM]].each do |version, sha256sum|
      filename = "ruby-#{version}.tar.gz"
      feature_version = version.match(/^(\d+\.\d+)/)[0]
      url_base = "https://cache.ruby-lang.org/pub/ruby/"
      url = "#{url_base}#{feature_version}/#{filename}"

      if version.start_with?("3")
        @file_ruby3_source = File.join(DOWNLOADS_DIR, filename)
        file @file_ruby3_source do
          download_file(url, filename, sha256sum)
        end
      else
        @file_ruby_source = File.join(DOWNLOADS_DIR, filename)
        file @file_ruby_source do
          download_file(url, filename, sha256sum)
        end
      end
    end
  end

  def define_ruby_installer_file
    version = BUNDLED_RUBY_INSTALLER_X64_VERSION
    sha256sum = BUNDLED_RUBY_INSTALLER_X64_SHA256SUM
    filename = "rubyinstaller-#{version}-x64.7z"
    url_base = "https://github.com/oneclick/rubyinstaller2/releases/download/"
    url = "#{url_base}RubyInstaller-#{version}/#{filename}"

    @file_ruby_installer_x64 = File.join(DOWNLOADS_DIR, filename)

    file @file_ruby_installer_x64 do
      download_file(url, filename, sha256sum)
    end
  end

  def define_mingw_openssl_file
    version = MINGW_OPENSSL_VERSION
    sha256sum = MINGW_OPENSSL_SHA256SUM
    filename = "mingw-w64-x86_64-openssl-#{version}-any.pkg.tar.zst"
    url_base = "https://mirror.msys2.org/mingw/mingw64/"
    url = "#{url_base}#{filename}"

    @file_mingw_openssl = File.join(DOWNLOADS_DIR, filename)

    file @file_mingw_openssl do
      download_file(url, filename, sha256sum)
    end
  end

  def define_fluentd_archive
    @file_fluentd_archive = File.join(DOWNLOADS_DIR, "fluentd-#{FLUENTD_REVISION}.tar.gz")
    file @file_fluentd_archive do
      ensure_directory(DOWNLOADS_DIR) do
        dirname = "fluentd-#{FLUENTD_REVISION}"
        rm_rf("fluentd") if File.exists?("fluentd")
        rm_rf(dirname) if File.exists?(dirname)
        sh("git", "clone", "https://github.com/fluent/fluentd.git")
        cd("fluentd") do
          sh("git", "checkout", FLUENTD_REVISION)
        end
        mv("fluentd", dirname)
        sh(*tar_command, "cvfz", "#{dirname}.tar.gz", dirname)
      end
    end
  end

  def define_gem_files
    paths = []
    Dir.glob("#{DOWNLOADS_DIR}/*.gem") do |path|
      paths << path
    end

    instance_variable_set("@files_ruby_gems", paths)
  end
end

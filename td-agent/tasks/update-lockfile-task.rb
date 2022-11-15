class UpdateLockfileTask
  include Rake::DSL

  def define
    namespace :lockfile do
      desc "Update lockfile"
      task :update do
        cd gemfile_dir do
          command = "bundle package --no-install --cache-path=#{DOWNLOADS_DIR}"
          output, error, status = Open3.capture3(command)
          unless status.success?
            fail "Failed to update Gemfile.lock: <#{command}> (stdout: #{output}, stderr: #{error})"
          end
        end
      end
    end
  end
end

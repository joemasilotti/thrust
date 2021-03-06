module Thrust
  module IOS
    class XCodeTools
      ProvisioningProfileNotFound = Class.new(StandardError)
      ProvisioningProfileNotEmbedded = Class.new(StandardError)

      def initialize(thrust_executor, out, build_configuration, build_directory, options = {})
        @thrust_executor = thrust_executor
        @out = out
        @git = Thrust::Git.new(@out, @thrust_executor)
        @build_configuration = build_configuration
        @build_directory = build_directory
        @project_name = options[:project_name]
        @workspace_name = options[:workspace_name]
        raise "project_name OR workspace_name required" unless @project_name.nil? ^ @workspace_name.nil?
      end

      def cleanly_create_ipa(target, app_name, signing_identity, provision_search_query = nil)
        clean_build
        kill_simulator
        build_scheme_or_target(target, 'iphoneos')
        ipa_name = create_ipa(app_name, signing_identity, provision_search_query)
        verify_provision(app_name, provision_search_query)

        return ipa_name
      end

      def build_configuration_directory
        "#{@build_directory}/#{@build_configuration}-iphoneos"
      end

      def clean_build
        @out.puts 'Cleaning...'
        FileUtils.rm_rf(@build_directory)
      end

      def build_scheme_or_target(scheme_or_target, build_sdk, architecture=nil)
        @out.puts "Building..."
        run_xcode('build', build_sdk, scheme_or_target, architecture)
      end

      def test(scheme, build_configuration, runtime_sdk, build_dir)
        destination = "OS=#{runtime_sdk},name=iPhone Retina (3.5-inch)"

        cmd = [
          "xcodebuild",
          "test",
          "-scheme #{scheme}",
          "-configuration #{build_configuration}",
          "-destination '#{destination}'",
          "ARCHS=i386",
          "SYMROOT='#{build_dir}'"
        ].join(' ')

        @thrust_executor.check_command_for_failure(cmd)
      end

      def kill_simulator
        @out.puts('Killing simulator...')
        @thrust_executor.system %q[killall -m -KILL "gdb"]
        @thrust_executor.system %q[killall -m -KILL "otest"]
        @thrust_executor.system %q[killall -m -KILL "iPhone Simulator"]
      end

      private

      def provision_path(provision_search_query)
        provision_search_path = File.expand_path("~/Library/MobileDevice/Provisioning Profiles/")
        command = %Q(grep -rl "#{provision_search_query}" "#{provision_search_path}")
        paths = `#{command}`.split("\n")
        paths.first or raise(ProvisioningProfileNotFound, "\nCouldn't find provisioning profiles matching #{provision_search_query}.\n\nThe command used was:\n\n#{command}")
      end

      def create_ipa(app_name, signing_identity, provision_search_query)
        @out.puts 'Packaging...'
        ipa_filename = "#{build_configuration_directory}/#{app_name}.ipa"
        cmd = [
          "xcrun",
          "-sdk iphoneos",
          "-v PackageApplication",
          "'#{build_configuration_directory}/#{app_name}.app'",
          "-o '#{ipa_filename}'",
          "--sign '#{signing_identity}'",
          "--embed '#{provision_path(provision_search_query)}'"
        ].join(' ')
        @thrust_executor.system_or_exit(cmd)
        ipa_filename
      end

      def verify_provision(app_name, provision_search_query)
        @out.puts 'Verifying provisioning profile...'
        embedded_filename = "#{build_configuration_directory}/#{app_name}.app/embedded.mobileprovision"
        correct_provision_filename = provision_path(provision_search_query)

        if !FileUtils.cmp(embedded_filename, correct_provision_filename)
          raise(ProvisioningProfileNotEmbedded, "Wrong mobile provision embedded by xcrun. Check your xcode provisioning profile settings.")
        end
      end

      def run_xcode(build_command, sdk = nil, scheme_or_target = nil, architecture = nil)
        architecture_flag = architecture ? "-arch #{architecture}" : nil
        target_flag = @workspace_name ? "-scheme \"#{scheme_or_target}\"" : "-target \"#{scheme_or_target}\""
        sdk_flag = sdk ? "-sdk #{sdk}" : nil
        configuration_build_dir = File.join(@build_directory, "#{@build_configuration}-#{sdk}").inspect
        configuration_build_dir_option = sdk != 'macosx' ? "CONFIGURATION_BUILD_DIR=#{configuration_build_dir}" : nil

        command = [
          'set -o pipefail &&',
          'xcodebuild',
          project_or_workspace_flag,
          architecture_flag,
          target_flag,
          "-configuration #{@build_configuration}",
          sdk_flag,
          "#{build_command}",
          "SYMROOT=#{@build_directory.inspect}",
          configuration_build_dir_option,
          '2>&1',
          "| grep -v 'backing file'"
        ].compact.join(' ')
        output_file = output_file("#{@build_configuration}-#{build_command}")
        begin
          @thrust_executor.system_or_exit(command, output_file)
        rescue Thrust::Executor::CommandFailed => e
          @out.write File.read(output_file)
          raise e
        end
      end

      def output_file(target)
        output_dir = if ENV['IS_CI_BOX']
                       ENV['CC_BUILD_ARTIFACTS']
                     else
                       File.exists?(@build_directory) ? @build_directory : FileUtils.mkdir_p(@build_directory)
                     end

        File.join(output_dir, "#{target}.output").tap { |file| @out.puts "Output: #{file}" }
      end

      def project_or_workspace_flag
        @workspace_name ? "-workspace #{@workspace_name}.xcworkspace" : "-project #{@project_name}.xcodeproj"
      end
    end
  end
end

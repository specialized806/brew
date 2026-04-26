# typed: strict
# frozen_string_literal: true

require "cask/utils"
require "fileutils"
require "system_command"
require "uri"

module Cask
  module Utils
    module Trash
      extend SystemCommand::Mixin

      sig {
        params(paths: Pathname, command: T.nilable(T.class_of(SystemCommand)))
          .returns([T::Array[String], T::Array[String]])
      }
      def self.trash(*paths, command: nil)
        swift_trash(*paths, command:)
      end

      sig {
        params(paths: Pathname, command: T.nilable(T.class_of(SystemCommand)))
          .returns([T::Array[String], T::Array[String]])
      }
      def self.swift_trash(*paths, command: nil)
        return [[], []] if paths.empty?

        stdout = system_command(HOMEBREW_LIBRARY_PATH/"cask/utils/trash.swift",
                                args:         paths,
                                print_stderr: Homebrew::EnvConfig.developer?).stdout

        trashed, _, untrashable = stdout.partition("\n")
        trashed = trashed.split(":")
        untrashable = untrashable.split(":")

        trashed_with_permissions, untrashable = untrashable.partition do |path|
          Utils.gain_permissions(Pathname(path), ["-R"], SystemCommand) do
            system_command! HOMEBREW_LIBRARY_PATH/"cask/utils/trash.swift",
                            args:         [path],
                            print_stderr: Homebrew::EnvConfig.developer?
          end

          true
        rescue
          false
        end

        [trashed + trashed_with_permissions, untrashable]
      end

      sig { params(paths: Pathname).returns([T::Array[String], T::Array[String]]) }
      def self.freedesktop_trash(*paths)
        return [[], []] if paths.empty?

        files_path = home_trash_path/"files"
        info_path = home_trash_path/"info"

        files_path.mkpath
        info_path.mkpath

        trashed, untrashable = paths.partition do |path|
          trash_path(path, files_path:, info_path:)
          true
        rescue
          false
        end

        [trashed.map(&:to_s), untrashable.map(&:to_s)]
      end

      sig { returns(Pathname) }
      def self.home_trash_path
        Pathname.new(ENV["XDG_DATA_HOME"].presence || "#{Dir.home}/.local/share")/"Trash"
      end
      private_class_method :home_trash_path

      sig { params(path: Pathname, files_path: Pathname, info_path: Pathname).void }
      def self.trash_path(path, files_path:, info_path:)
        basename = path.basename.to_s
        deletion_date = Time.now.strftime("%Y-%m-%dT%H:%M:%S")
        suffix = 0

        Kernel.loop do
          candidate = suffix.zero? ? basename : "#{basename}.#{suffix}"
          target_path = files_path/candidate
          target_info_path = info_path/"#{candidate}.trashinfo"

          if target_path.exist? || target_path.symlink?
            suffix += 1
            next
          end

          begin
            File.open(target_info_path, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
              file.write <<~EOS
                [Trash Info]
                Path=#{URI::DEFAULT_PARSER.escape(path.to_s)}
                DeletionDate=#{deletion_date}
              EOS
            end
          rescue Errno::EEXIST
            suffix += 1
            next
          end

          begin
            FileUtils.mv(path, target_path)
          rescue
            target_info_path.delete if target_info_path.exist?
            Kernel.raise
          end

          return
        end
      end
      private_class_method :swift_trash, :freedesktop_trash, :trash_path
    end
  end
end

require "extend/os/cask/utils/trash"

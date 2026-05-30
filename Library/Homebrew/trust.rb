# typed: strict
# frozen_string_literal: true

require "env_config"
require "json"
require "tap"
require "utils"

module Homebrew
  class UntrustedTapError < RuntimeError; end

  module Trust
    SETTING_KEYS = T.let({
      tap:     :trustedtaps,
      formula: :trustedformulae,
      cask:    :trustedcasks,
      command: :trustedcommands,
    }.freeze, T::Hash[Symbol, Symbol])
    private_constant :SETTING_KEYS

    TRUST_FILE = T.let((HOMEBREW_PREFIX/"var/homebrew/trust.json").freeze, Pathname)
    private_constant :TRUST_FILE

    sig { returns(T::Boolean) }
    def self.enabled?
      Homebrew::EnvConfig.require_tap_trust?
    end

    sig { params(type: Symbol, name: String).returns(T::Boolean) }
    def self.trust!(type, name)
      key = setting_key(type)
      entries = trusted_entries(type)
      name = normalise_name(name)
      return false if entries.include?(name)

      store = trust_store
      store[key] = (entries + [name]).sort
      write_trust_store(store)
      true
    end

    sig { params(type: Symbol).void }
    def self.clear!(type)
      store = trust_store
      store.delete(setting_key(type))
      write_trust_store(store)
    end

    sig { params(type: Symbol, name: String).returns(T::Boolean) }
    def self.trusted?(type, name)
      trusted_entries(type).include?(normalise_name(name))
    end

    sig { params(tap: T.untyped).returns(T::Boolean) }
    def self.trusted_tap?(tap)
      tap.official? || trusted?(:tap, tap.name)
    end

    sig { params(name: String, path: Pathname).void }
    def self.require_trusted_formula!(name, path)
      return unless (tap = tap_from_path(path))
      return if trusted_tap?(tap)

      full_name = "#{tap.name}/#{::Utils.name_from_full_name(name)}"
      return if trusted?(:formula, full_name)
      return unless enabled?

      raise_untrusted!(:formula, full_name, tap)
    end

    sig { params(token: String, path: Pathname).void }
    def self.require_trusted_cask!(token, path)
      return unless (tap = tap_from_path(path))
      return if trusted_tap?(tap)

      full_name = "#{tap.name}/#{::Utils.name_from_full_name(token)}"
      return if trusted?(:cask, full_name)
      return unless enabled?

      raise_untrusted!(:cask, full_name, tap)
    end

    sig { params(path: Pathname, command: T.nilable(String)).void }
    def self.require_trusted_command!(path, command = nil)
      return unless (tap = tap_from_path(path))
      return if trusted_tap?(tap)

      full_name = "#{tap.name}/#{command || path.basename(path.extname).to_s.delete_prefix("brew-")}"
      return if trusted?(:command, full_name)
      return unless enabled?

      raise_untrusted!(:command, full_name, tap)
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.trusted_formula_file?(path)
      trusted_file?(:formula, path)
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.trusted_cask_file?(path)
      trusted_file?(:cask, path)
    end

    sig { params(type: Symbol).returns(String) }
    def self.setting_key(type)
      SETTING_KEYS.fetch(type).to_s
    end

    sig { params(type: Symbol).returns(T::Array[String]) }
    def self.trusted_entries(type)
      trust_store.fetch(setting_key(type), [])
    end

    sig { params(name: String).returns(String) }
    def self.normalise_name(name)
      name.downcase
    end

    sig { returns(T::Hash[String, T::Array[String]]) }
    def self.trust_store
      return {} unless TRUST_FILE.exist?

      parsed_store = JSON.parse(TRUST_FILE.read)
      return {} unless parsed_store.is_a?(Hash)

      parsed_store.transform_values { |entries| Array(entries).map { |entry| normalise_name(entry.to_s) } }
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
    private_class_method :trust_store

    sig { params(store: T::Hash[String, T::Array[String]]).void }
    def self.write_trust_store(store)
      if store.empty?
        TRUST_FILE.unlink if TRUST_FILE.exist?
        return
      end

      TRUST_FILE.dirname.mkpath
      TRUST_FILE.atomic_write("#{JSON.pretty_generate(store)}\n")
    end
    private_class_method :write_trust_store

    sig { params(path: Pathname).returns(T.untyped) }
    def self.tap_from_path(path)
      Tap.from_path(path)
    end
    private_class_method :tap_from_path

    sig { params(type: Symbol, path: Pathname).returns(T::Boolean) }
    def self.trusted_file?(type, path)
      return true unless (tap = tap_from_path(path))
      return true if trusted_tap?(tap)
      return true if trusted?(type, "#{tap.name}/#{path.basename(path.extname)}")

      !enabled?
    end
    private_class_method :trusted_file?

    sig { params(type: Symbol, name: String, tap: T.untyped).void }
    def self.raise_untrusted!(type, name, tap)
      raise UntrustedTapError, "Refusing to load #{type} #{name} from untrusted tap #{tap.name}.\n" \
                               "Run `brew trust --#{type} #{name}` or `brew trust #{tap.name}` to trust it."
    end
    private_class_method :raise_untrusted!
  end
end

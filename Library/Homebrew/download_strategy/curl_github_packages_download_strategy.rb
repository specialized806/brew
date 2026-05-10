# typed: strict
# frozen_string_literal: true

# Strategy for downloading a file from an GitHub Packages URL.
#
# @api public
class CurlGitHubPackagesDownloadStrategy < CurlDownloadStrategy
  sig { params(resolved_basename: String).returns(T.nilable(String)) }
  attr_writer :resolved_basename

  sig { params(url: String, name: String, version: T.nilable(T.any(String, Version)), meta: T.untyped).void }
  def initialize(url, name, version, **meta)
    meta[:headers] ||= []
    # GitHub Packages authorization header.
    # HOMEBREW_GITHUB_PACKAGES_AUTH set in brew.sh
    # If using a private GHCR mirror with no Authentication set or HOMEBREW_GITHUB_PACKAGES_AUTH is empty
    # then do not add the header. In all other cases add it.
    if HOMEBREW_GITHUB_PACKAGES_AUTH.presence && (
       !Homebrew::EnvConfig.artifact_domain.presence ||
       Homebrew::EnvConfig.docker_registry_basic_auth_token.presence ||
       Homebrew::EnvConfig.docker_registry_token.presence
     )
      meta[:headers] << "Authorization: #{HOMEBREW_GITHUB_PACKAGES_AUTH}"
    end
    super
  end

  private

  sig { override.params(url: String, timeout: T.nilable(T.any(Float, Integer))).returns(URLMetadata) }
  def resolve_url_basename_time_file_size(url, timeout: nil)
    return super if @resolved_basename.blank?

    [url, @resolved_basename, nil, nil, nil, false]
  end
end

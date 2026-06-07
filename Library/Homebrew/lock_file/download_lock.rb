# typed: strict
# frozen_string_literal: true

# A lock file for a download.
class DownloadLock < LockFile
  sig { params(download_path: Pathname).void }
  def initialize(download_path)
    super(:download, download_path)
  end
end

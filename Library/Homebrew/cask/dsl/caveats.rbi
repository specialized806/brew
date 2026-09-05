# typed: strict

class Cask::DSL::Caveats
  sig { returns(Symbol) }
  def kext; end

  sig { returns(Symbol) }
  def requires_rosetta; end
end

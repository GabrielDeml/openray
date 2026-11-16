# The Homebrew cask of OpenRay. It is kept in GabrielDeml/openray as Casks/openray.rb
# (docs/DESIGN.md §6.5 there). For every release, the release job copies it to the tap,
# GabrielDeml/homebrew-openray, and writes the version and the SHA-256 of the release's zip
# into the copy (Scripts/update-cask.sh). The original says :no_check, because no zip exists
# for it to name the hash of. Change the cask in GabrielDeml/openray and not in the tap,
# where the next release would overwrite the change.
cask "openray" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/GabrielDeml/openray/releases/download/v#{version}/OpenRay-#{version}.zip"
  name "OpenRay"
  desc "Keyboard launcher"
  homepage "https://github.com/GabrielDeml/openray"

  # The feed that the app itself updates from. Its entries carry two versions, and the cask's
  # is the short one: the strategy's default answer would be "0.1.0,123".
  livecheck do
    url "https://gabrieldeml.github.io/openray/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "OpenRay.app"

  # Sparkle keeps its downloads in a folder of its own inside the app's cache folder.
  zap trash: [
    "~/Library/Application Support/io.github.gabrieldeml.openray",
    "~/Library/Caches/io.github.gabrieldeml.openray",
    "~/Library/Preferences/io.github.gabrieldeml.openray.plist",
  ]
end

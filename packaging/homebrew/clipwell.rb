# Template for a Homebrew tap (a repo named homebrew-clipwell, file Casks/clipwell.rb).
# After each release, set `version` and the sha256 from Clipwell-<version>.zip.sha256.
cask "clipwell" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_RELEASE_ZIP"

  url "https://github.com/naveenrenji/Clipwell/releases/download/v#{version}/Clipwell-#{version}.zip"
  name "Clipwell"
  desc "Private clipboard history with search inside screenshots"
  homepage "https://github.com/naveenrenji/Clipwell"

  depends_on macos: ">= :sonoma"

  app "Clipwell.app"

  zap trash: [
    "~/Library/Application Support/Clipwell",
    "~/Library/Preferences/io.github.naveenrenji.Clipwell.plist",
  ]
end

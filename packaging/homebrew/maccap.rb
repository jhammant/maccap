# Homebrew cask for MacCap. Copy into a tap (Casks/maccap.rb) after each
# release, with the version and the sha256 that release.sh prints.
cask "maccap" do
  version "0.1.0"
  sha256 "d46c791c9b9d200356bbf1e7ee5b8baf10c8c58942f863e3b005b92d5bbe6f46"

  url "https://github.com/jhammant/maccap/releases/download/v#{version}/MacCap-#{version}.dmg"
  name "MacCap"
  desc "Records calls on your Mac with on-device live notes and next steps"
  homepage "https://github.com/jhammant/maccap"

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64
  depends_on formula: "ffmpeg"

  app "MacCap.app"

  zap trash: "~/.maccap"

  caveats <<~EOS
    Only record people who have said yes. MacCap doesn't join the call, so
    nobody else gets a notice from it: ask everyone before you record.
    Recording a call without consent is against the law in many places.
  EOS
end

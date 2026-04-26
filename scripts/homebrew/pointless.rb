cask "pointless" do
  version "1.0.0"
  sha256 "FILL_IN_AFTER_RELEASE"

  url "https://github.com/AR-1106/Pointless/releases/download/v#{version}/Pointless-#{version}.dmg",
      verified: "github.com/AR-1106/Pointless/"

  name "Pointless"
  desc "Cursor without the click — touchless trackpad via webcam"
  homepage "https://ar-1106.github.io/Pointless/"

  # Pointless requires macOS 26 Tahoe (arm64 only)
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  livecheck do
    url :url
    strategy :github_latest
  end

  app "Pointless.app"

  zap trash: [
    "~/Library/Application Support/Pointless",
    "~/Library/Caches/com.arjunr.Pointless",
    "~/Library/Caches/com.arjunr.Pointless.ShipIt",
    "~/Library/HTTPStorages/com.arjunr.Pointless",
    "~/Library/Logs/Pointless",
    "~/Library/Preferences/com.arjunr.Pointless.plist",
    "~/Library/Saved Application State/com.arjunr.Pointless.savedState",
  ]
end

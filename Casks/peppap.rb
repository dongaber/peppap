cask "peppap" do
  version "0.4.1"
  sha256 "b810626b6e77d87bc3f73c4f6ca38335155c63a96839f64b1a40fa66dc713aab"

  url "https://github.com/dongaber/peppap/releases/download/v#{version}/Peppap-#{version}.zip"
  name "Peppap"
  desc "Claude Code session status in the MacBook notch"
  homepage "https://github.com/dongaber/peppap"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Peppap.app"

  # The app is not notarized; drop the quarantine flag so it opens without a Gatekeeper prompt.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Peppap.app"]
  end

  uninstall quit: "com.peppap.notch"

  zap trash: [
    "~/Library/Application Support/Peppap",
    "~/Library/Preferences/com.peppap.notch.plist",
  ]

  caveats <<~EOS
    Before uninstalling, disconnect the Claude Code hooks from the Peppap menu (✦),
    otherwise Claude Code will keep calling the removed hook script.
  EOS
end

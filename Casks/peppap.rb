cask "peppap" do
  version "0.5.0"
  sha256 "ef67a85cccc3dd0f6d9cd8bbdb56e1f829dd48145993da4b697d12607da9705c"

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

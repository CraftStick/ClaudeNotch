# The Homebrew cask, for the tap at github.com/CraftStick/homebrew-tap (Casks/claude-notch.rb):
# brew install craftstick/tap/claude-notch. Each release: the version and build, and the disk image's
# sha256 (shasum -a 256 build/ClaudeNotch-<version>-<build>.dmg).
cask "claude-notch" do
  version "0.2.2,30"
  sha256 "db113208cd13bca8b092af67b029131ee92e2237c16dfb08a7cd5a2621c8e6bf"

  url "https://github.com/CraftStick/ClaudeNotch/releases/download/v#{version.csv.first}/ClaudeNotch-#{version.csv.first}-#{version.csv.second}.dmg"
  name "Claude Notch"
  desc "Claude Code in the MacBook notch, with Clawd living in it"
  homepage "https://github.com/CraftStick/ClaudeNotch"

  livecheck do
    url :url
    regex(/ClaudeNotch[._-]v?(\d+(?:\.\d+)+)[._-](\d+)\.dmg/i)
    strategy :github_latest do |json, regex|
      json["assets"]&.map do |asset|
        match = asset["name"]&.match(regex)
        next if match.blank?

        "#{match[1]},#{match[2]}"
      end
    end
  end

  depends_on macos: :sonoma

  app "ClaudeNotch.app"

  uninstall quit: "local.claudenotch"

  zap trash: [
    "~/Library/Application Support/ClaudeNotch",
    "~/Library/Caches/local.claudenotch",
    "~/Library/HTTPStorages/local.claudenotch",
    "~/Library/Preferences/local.claudenotch.plist",
  ]

  caveats <<~EOS
    Apple hasn't notarized Claude Notch, so the first time macOS won't open it:
    click Done, then System Settings → Privacy & Security → Open Anyway.

    To remove its Claude Code hooks too, move the app to the Trash yourself
    and click Remove All before running `brew uninstall`.
  EOS
end

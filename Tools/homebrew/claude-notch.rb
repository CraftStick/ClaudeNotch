# The Homebrew cask, for the tap at github.com/CraftStick/homebrew-tap (Casks/claude-notch.rb):
# brew install craftstick/tap/claude-notch. Each release: the version and build, and the disk image's
# sha256 (shasum -a 256 build/ClaudeNotch-<version>-<build>.dmg).
cask "claude-notch" do
  version "0.2.0,28"
  sha256 "82f230aa45f0bbd4026fe7e9025dda4a10faf91b28bead84b9ca1bc1237536d4"

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

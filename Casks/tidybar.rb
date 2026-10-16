cask "tidybar" do
  version "0.1.0"
  sha256 :no_check # 将在正式发布 Release 后填入真实的 sha256 校验和

  url "https://github.com/Oneideals/tidybar/releases/download/v#{version}/TidyBar-v#{version}.dmg"
  name "TidyBar"
  desc "Minimalist & intelligent macOS menu bar manager"
  homepage "https://github.com/Oneideals/tidybar"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :sonoma"

  app "TidyBar.app"

  zap trash: [
    "~/Library/Application Support/TidyBar",
    "~/Library/Preferences/com.oneideals.tidybar.plist",
    "~/Library/Preferences/local.tidybar.app.plist",
  ]
end

# Homebrew formula. After pushing this repo to GitHub as shrsijan/macfan, users can
# install with:
#
#   brew install --HEAD shrsijan/macfan/macfan
#
# (that resolves to a tap repo named homebrew-macfan containing this file).
# For a versioned release, add `url` and `sha256` from `make release`.
class Macfan < Formula
  desc "Live fan speed and temperature in the terminal, with arrow-key fan control"
  homepage "https://github.com/shrsijan/macfan"
  head "https://github.com/shrsijan/macfan.git", branch: "main"
  license "MIT"

  depends_on :macos
  depends_on xcode: ["14.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/macfan"
  end

  def caveats
    <<~EOS
      Changing fan speed needs root:
        sudo macfan
      Hand control back to macOS at any time:
        sudo macfan default
    EOS
  end

  test do
    assert_match "macfan", shell_output("#{bin}/macfan version")
  end
end

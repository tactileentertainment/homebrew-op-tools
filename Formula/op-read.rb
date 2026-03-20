class OpRead < Formula
  desc "1Password secret reader with Connect server failover"
  homepage "https://github.com/tactileentertainment/homebrew-op-read"
  url "https://github.com/tactileentertainment/homebrew-op-read.git",
      tag: "v1.3.0"
  license "MIT"

  def install
    bin.install "scripts/op-read.sh" => "op-read"
  end

  def caveats
    <<~EOS
      op-read requires the 1Password CLI (op). Install it with:
        brew install --cask 1password-cli

      Required env vars (at least one set):
        OP_CONNECT_HOST + OP_CONNECT_TOKEN   (Connect server)
        OP_SERVICE_ACCOUNT_TOKEN             (service account fallback)
    EOS
  end

  test do
    assert_match "No credentials configured",
      shell_output("#{bin}/op-read op://test/test/test 2>&1", 1)
  end
end

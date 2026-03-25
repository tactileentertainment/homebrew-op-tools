class OpTactile < Formula
  desc "1Password CLI wrappers with Connect server failover"
  homepage "https://github.com/tactileentertainment/homebrew-op-tools"
  url "https://github.com/tactileentertainment/homebrew-op-tools.git",
      tag: "v1.5.0"
  license "MIT"

  def install
    libexec.install "scripts/_op-tactile-common.sh"

    %w[op-read op-inject op-item-create op-item-delete op-item-edit].each do |cmd|
      bin.install "scripts/#{cmd}.sh" => cmd
      inreplace bin/cmd, '${SCRIPT_DIR}/../libexec/_op-tactile-common.sh',
                         "#{libexec}/_op-tactile-common.sh"
    end
  end

  def caveats
    <<~EOS
      op-tactile requires the 1Password CLI (op). Install it with:
        brew install --cask 1password-cli

      Installed commands:
        op-read          Read secrets (op read / op item get)
        op-inject        Inject secrets into templates (op inject)
        op-item-create   Create items (op item create)
        op-item-delete   Delete items (op item delete)
        op-item-edit     Edit items (op item edit)

      Required env vars (at least one set):
        OP_CONNECT_HOST + OP_CONNECT_TOKEN   (Connect server)
        OP_SERVICE_ACCOUNT_TOKEN             (service account fallback)
    EOS
  end

  test do
    %w[op-read op-inject op-item-create op-item-delete op-item-edit].each do |cmd|
      assert_match "help", shell_output("#{bin}/#{cmd} --help 2>&1", 0)
    end

    assert_match "No credentials configured",
      shell_output("#{bin}/op-read op://test/test/test 2>&1", 1)
  end
end

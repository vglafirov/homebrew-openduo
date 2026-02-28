class Openduo < Formula
  desc "GitLab-hardened wrapper for OpenCode"
  homepage "https://gitlab.com/vglafirov/openduo"
  # URL and SHA256 are updated automatically by script/release.sh
  url "https://gitlab.com/vglafirov/openduo/-/archive/v1.2.15/openduo-v1.2.15.tar.gz"
  sha256 "60cafbe54d30cbb31a426770f2548ada9415de1790881db9109f4aae3f3ccbcb"
  license "MIT"

  depends_on "node"

  def install
    # Install opencode-ai from npm into libexec
    system "npm", "install", "--prefix", libexec, "opencode-ai@#{opencode_version}"

    # Install the restricted models catalog
    (libexec/"models").mkpath
    cp "models/models.json", libexec/"models/models.json"

    # Install the generate-models script
    (libexec/"script").mkpath
    cp "script/generate-models.ts", libexec/"script/generate-models.ts"

    # Create the wrapper script that points to our libexec layout
    (bin/"openduo").write <<~BASH
      #!/usr/bin/env bash
      # openduo — GitLab-hardened OpenCode wrapper (installed via Homebrew)
      #
      # Security hardening applied:
      #   1. Session sharing disabled (OPENCODE_DISABLE_SHARE + config)
      #   2. Models restricted to GitLab-approved providers (OPENCODE_MODELS_PATH)
      #   3. Small model forced to gitlab/duo-chat-haiku-4-5 (config)
      #   4. Model fetching from models.dev disabled (OPENCODE_DISABLE_MODELS_FETCH)
      #   5. Only the "gitlab" provider is enabled (enabled_providers)

      set -euo pipefail

      ROOT_DIR="#{libexec}"

      # --- Security: Disable sharing completely ---
      export OPENCODE_DISABLE_SHARE=true

      # --- Security: Restrict models to approved catalog ---
      export OPENCODE_MODELS_PATH="${ROOT_DIR}/models/models.json"

      # --- Security: Don't fetch models from models.dev ---
      export OPENCODE_DISABLE_MODELS_FETCH=true

      # --- Security: Disable auto-update (managed by brew upgrade) ---
      export OPENCODE_DISABLE_AUTOUPDATE=true

      # --- Security: Inject hardened config ---
      SECURITY_CONFIG='{"share":"disabled","small_model":"gitlab/duo-chat-haiku-4-5","enabled_providers":["gitlab"],"autoupdate":false}'

      if [ -n "${OPENCODE_CONFIG_CONTENT:-}" ]; then
        MERGED="$(node -e "
          const user = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT);
          const security = ${SECURITY_CONFIG};
          console.log(JSON.stringify({ ...user, ...security }));
        ")" 2>/dev/null || MERGED="${SECURITY_CONFIG}"
        export OPENCODE_CONFIG_CONTENT="${MERGED}"
      else
        export OPENCODE_CONFIG_CONTENT="${SECURITY_CONFIG}"
      fi

      # --- Resolve opencode binary ---
      OPENCODE_BIN="${ROOT_DIR}/node_modules/.bin/opencode"

      if [ ! -x "$OPENCODE_BIN" ]; then
        echo "error: opencode binary not found at ${OPENCODE_BIN}" >&2
        echo "Try reinstalling: brew reinstall openduo" >&2
        exit 1
      fi

      exec "$OPENCODE_BIN" "$@"
    BASH

    (bin/"openduo").chmod 0755
  end

  def opencode_version
    # Read the pinned version from package.json
    require "json"
    pkg = JSON.parse(File.read(buildpath/"package.json"))
    pkg["dependencies"]["opencode-ai"]
  end

  test do
    # Verify security env vars are set in the wrapper
    wrapper = File.read(bin/"openduo")
    assert_match "OPENCODE_DISABLE_SHARE=true", wrapper
    assert_match "OPENCODE_DISABLE_MODELS_FETCH=true", wrapper
    assert_match "OPENCODE_DISABLE_AUTOUPDATE=true", wrapper
    assert_match '"share":"disabled"', wrapper
    assert_match '"enabled_providers":["gitlab"]', wrapper
    assert_match '"small_model":"gitlab/duo-chat-haiku-4-5"', wrapper

    # Verify models.json exists and contains only gitlab
    models = JSON.parse(File.read(libexec/"models/models.json"))
    assert_equal ["gitlab"], models.keys
  end
end

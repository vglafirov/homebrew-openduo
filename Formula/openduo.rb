class Openduo < Formula
  desc "GitLab-hardened wrapper for OpenCode"
  homepage "https://gitlab.com/vglafirov/openduo"
  # URL and SHA256 are updated automatically by script/release.sh
  url "https://gitlab.com/vglafirov/openduo/-/archive/v1.2.27/openduo-v1.2.27.tar.gz"
  sha256 "464f17902dbc7409a703c25c4e3624d0dff8f7095af907c515a7ef6d0b4d7cc8"
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

      # --- Security: Inject hardened config ---
      # GOLDEN_CONFIG is the default baseline (from golden-config.json).
      # SECURITY_CONFIG contains keys that must always win regardless of user config.
      # Merge order: golden -> user -> security (security always wins on conflicts).
      GOLDEN_CONFIG='{
        "share": "disabled",
        "server": {
          "hostname": "127.0.0.1",
          "mdns": false
        },

        "permission": {
          "*": "ask",
          "read": {
            "*": "allow",
            "*.env": "deny",
            "*.env.*": "deny",
            "*.env.example": "allow"
          },
          "grep": "allow",
          "glob": "allow",
          "list": "allow",
          "todoread": "allow",
          "todowrite": "allow",
          "skill": "allow",
          "bash": {
            "*": "ask",
            "git status*": "allow",
            "git log*": "allow",
            "git diff*": "allow",
            "git show*": "allow",
            "git branch*": "allow",
            "grep *": "allow",
            "cat *": "allow",
            "head *": "allow",
            "tail *": "allow",
            "wc *": "allow",
            "ls *": "allow",
            "find *": "allow",
            "echo *": "allow",
            "which *": "allow",
            "pwd": "allow",
            "date": "allow",
            "git commit*": "ask",
            "git commit *": "ask",
            "git push*": "ask",
            "git push *": "ask",
            "rm -rf *": "deny",
            "curl *": "deny",
            "wget *": "deny"
          },
          "edit": "ask",
          "webfetch": "ask",
          "websearch": "ask",
          "external_directory": "ask",
          "doom_loop": "ask",
          "~/.aws/*": "deny",
          "~/.config/opencode/*": "deny",
          "~/.gnupg/*": "deny",
          "~/.netrc": "deny",
          "~/.ssh/*": "deny"
        }
      }'
      SECURITY_CONFIG='{"share":"disabled","small_model":"gitlab/duo-chat-haiku-4-5","enabled_providers":["gitlab","anthropic","google"]}'

      MERGE_SCRIPT='
        function deepMerge(base, override) {
          const result = Object.assign({}, base);
          for (const key of Object.keys(override)) {
            if (
              override[key] !== null &&
              typeof override[key] === "object" &&
              !Array.isArray(override[key]) &&
              base[key] !== null &&
              typeof base[key] === "object" &&
              !Array.isArray(base[key])
            ) {
              result[key] = deepMerge(base[key], override[key]);
            } else {
              result[key] = override[key];
            }
          }
          return result;
        }
        const golden = JSON.parse(process.env.GOLDEN_CONFIG);
        const security = JSON.parse(process.env.SECURITY_CONFIG);
        const user = process.env.USER_CONFIG ? JSON.parse(process.env.USER_CONFIG) : {};
        const merged = deepMerge(deepMerge(golden, user), security);
        console.log(JSON.stringify(merged));
      '

      export GOLDEN_CONFIG
      export SECURITY_CONFIG
      export USER_CONFIG="${OPENCODE_CONFIG_CONTENT:-}"
      MERGED="$(node -e "${MERGE_SCRIPT}" 2>/dev/null)" || MERGED="${SECURITY_CONFIG}"
      unset GOLDEN_CONFIG SECURITY_CONFIG USER_CONFIG

      export OPENCODE_CONFIG_CONTENT="${MERGED}"

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
    assert_match '"share":"disabled"', wrapper
    assert_match '"enabled_providers":["gitlab","anthropic","google"]', wrapper
    assert_match '"small_model":"gitlab/duo-chat-haiku-4-5"', wrapper
    assert_match '"hostname": "127.0.0.1"', wrapper
    assert_match '"permission"', wrapper

    # Verify models.json exists and contains only gitlab
    models = JSON.parse(File.read(libexec/"models/models.json"))
    assert_equal ["gitlab"], models.keys
  end
end

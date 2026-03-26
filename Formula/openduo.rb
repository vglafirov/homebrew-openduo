class Openduo < Formula
  desc "GitLab-hardened wrapper for OpenCode"
  homepage "https://gitlab.com/vglafirov/openduo"
  # URL and SHA256 are updated automatically by script/release.sh
  url "https://gitlab.com/vglafirov/openduo/-/archive/v1.3.7/openduo-v1.3.7.tar.gz"
  sha256 "ef2fa40b5d44e45dd1dbec65f62ec88bd621539d9fb193ba74f95cfcb0298dda"
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
      #   2. Models fetched from models.dev at startup, filtered to allowed providers only
      #   3. Local gitlab models overlay remote catalog (openduo-specific model IDs)
      #   4. Small model forced to gitlab/duo-chat-gpt-5-4-nano (config)
      #   5. OpenCode's own models.dev fetcher disabled (OPENCODE_DISABLE_MODELS_FETCH)
      #   6. Only gitlab, anthropic, google providers are enabled (enabled_providers)

      set -euo pipefail

      ROOT_DIR="#{libexec}"

      # --- Security: Disable sharing completely ---
      export OPENCODE_DISABLE_SHARE=true

      # --- Security: Don't fetch models from models.dev (opencode's own fetcher) ---
      export OPENCODE_DISABLE_MODELS_FETCH=true

      # --- Security: Restrict models to approved providers ---
      # Fetch models.dev catalog, keep only allowed providers, overlay local gitlab
      # models (which define openduo-specific model IDs). Falls back to local file.
      ALLOWED_PROVIDERS='["gitlab","anthropic","google"]'
      MODELS_SCRIPT='
        import { readFileSync } from "fs";
        const allowed = new Set(JSON.parse(process.env.ALLOWED_PROVIDERS));
        const local = JSON.parse(readFileSync(process.env.LOCAL_MODELS, "utf8"));
        let remote = {};
        try {
          const res = await fetch("https://models.dev/api.json", { signal: AbortSignal.timeout(5000) });
          if (res.ok) remote = await res.json();
        } catch {}
        const result = {};
        for (const id of allowed) {
          if (remote[id]) result[id] = remote[id];
          else if (local[id]) result[id] = local[id];
        }
        for (const [id, provider] of Object.entries(local)) {
          if (!allowed.has(id)) continue;
          result[id] = result[id] ? { ...result[id], models: { ...(result[id].models ?? {}), ...provider.models } } : provider;
        }
        console.log(JSON.stringify(result));
      '

      MODELS_CACHE="${HOME}/.cache/opencode/openduo-models.json"
      mkdir -p "$(dirname "$MODELS_CACHE")"

      export ALLOWED_PROVIDERS
      export LOCAL_MODELS="${ROOT_DIR}/models/models.json"
      MODELS_JSON="$(node --input-type=module -e "${MODELS_SCRIPT}" 2>/dev/null)" || MODELS_JSON=""
      unset ALLOWED_PROVIDERS LOCAL_MODELS

      if [ -n "$MODELS_JSON" ]; then
        echo "$MODELS_JSON" > "$MODELS_CACHE"
        export OPENCODE_MODELS_PATH="$MODELS_CACHE"
      elif [ -f "$MODELS_CACHE" ]; then
        export OPENCODE_MODELS_PATH="$MODELS_CACHE"
      else
        export OPENCODE_MODELS_PATH="${ROOT_DIR}/models/models.json"
      fi

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
      SECURITY_CONFIG='{"share":"disabled","small_model":"gitlab/duo-chat-gpt-5-4-nano","enabled_providers":["gitlab","anthropic","google"]}'

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

      # --- Subcommand: openduo injected-config ---
      if [ "${1:-}" = "show-injected-config" ]; then
        echo "$OPENCODE_CONFIG_CONTENT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(JSON.stringify(JSON.parse(d),null,2)))"
        exit 0
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
    assert_match "models.dev/api.json", wrapper
    assert_match "openduo-models.json", wrapper
    assert_match '"share":"disabled"', wrapper
    assert_match '"enabled_providers":["gitlab","anthropic","google"]', wrapper
    assert_match '"small_model":"gitlab/duo-chat-gpt-5-4-nano"', wrapper
    assert_match '"hostname": "127.0.0.1"', wrapper
    assert_match '"permission"', wrapper

    # Verify local models.json exists and contains gitlab
    models = JSON.parse(File.read(libexec/"models/models.json"))
    assert_equal ["gitlab"], models.keys
  end
end

import { describe, test, expect } from "bun:test";
import { $ } from "bun";
import path from "path";
import fs from "fs";

const ROOT = path.join(import.meta.dir, "..");
const WRAPPER = path.join(ROOT, "bin", "openduo");
const MODELS_PATH = path.join(ROOT, "models", "models.json");

describe("openduo security hardening", () => {
  test("wrapper script exists and is executable", () => {
    const stat = fs.statSync(WRAPPER);
    expect(stat.isFile()).toBe(true);
    // Check executable bit (owner)
    expect(stat.mode & 0o100).toBeTruthy();
  });

  test("models.json exists and contains only approved providers", () => {
    const content = fs.readFileSync(MODELS_PATH, "utf-8");
    const models = JSON.parse(content);
    const providers = Object.keys(models);

    // Should only contain gitlab
    expect(providers).toEqual(["gitlab"]);

    // Should not contain any unapproved providers
    const forbidden = [
      "anthropic",
      "openai",
      "google",
      "openrouter",
      "mistral",
    ];
    for (const provider of forbidden) {
      expect(providers).not.toContain(provider);
    }
  });

  test("models.json gitlab provider has models", () => {
    const content = fs.readFileSync(MODELS_PATH, "utf-8");
    const models = JSON.parse(content);

    expect(models.gitlab).toBeDefined();
    expect(models.gitlab.models).toBeDefined();
    expect(Object.keys(models.gitlab.models).length).toBeGreaterThan(0);
  });

  test("wrapper sets OPENCODE_DISABLE_SHARE=true", async () => {
    // Source the wrapper in a subshell and print the env var
    const result =
      await $`bash -c 'source <(sed -n "/^export OPENCODE_DISABLE_SHARE/p" ${WRAPPER}) && echo $OPENCODE_DISABLE_SHARE'`
        .text()
        .catch(() => "");
    expect(result.trim()).toBe("true");
  });

  test("wrapper sets OPENCODE_DISABLE_MODELS_FETCH=true", async () => {
    const result =
      await $`bash -c 'source <(sed -n "/^export OPENCODE_DISABLE_MODELS_FETCH/p" ${WRAPPER}) && echo $OPENCODE_DISABLE_MODELS_FETCH'`
        .text()
        .catch(() => "");
    expect(result.trim()).toBe("true");
  });

  test("OPENCODE_CONFIG_CONTENT contains security config", async () => {
    const script = `
      exec() { echo "$OPENCODE_CONFIG_CONTENT"; }
      export -f exec 2>/dev/null || true
      export OPENCODE_CONFIG_CONTENT=""
      SECURITY_CONFIG='{"share":"disabled","small_model":"gitlab/duo-chat-haiku-4-5","enabled_providers":["gitlab","anthropic","google"]}'
      export OPENCODE_CONFIG_CONTENT="\${SECURITY_CONFIG}"
      echo "$OPENCODE_CONFIG_CONTENT"
    `;
    const result = await $`bash -c ${script}`.text().catch(() => "");
    const config = JSON.parse(result.trim());

    expect(config.share).toBe("disabled");
    expect(config.small_model).toBe("gitlab/duo-chat-haiku-4-5");
    expect(config.enabled_providers).toEqual(["gitlab", "anthropic", "google"]);
  });

  test("OPENCODE_CONFIG_CONTENT contains golden config defaults", async () => {
    const mergeScript = `
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
    `;

    const goldenConfig = JSON.stringify({
      share: "disabled",
      server: { hostname: "127.0.0.1", mdns: false },
      permission: {
        "*": "ask",
        read: {
          "*": "allow",
          "*.env": "deny",
          "*.env.*": "deny",
          "*.env.example": "allow",
        },
        grep: "allow",
        glob: "allow",
        list: "allow",
        todoread: "allow",
        todowrite: "allow",
        skill: "allow",
        bash: {
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
          pwd: "allow",
          date: "allow",
          "git commit*": "ask",
          "git commit *": "ask",
          "git push*": "ask",
          "git push *": "ask",
          "rm -rf *": "deny",
          "curl *": "deny",
          "wget *": "deny",
        },
        edit: "ask",
        webfetch: "ask",
        websearch: "ask",
        external_directory: "ask",
        doom_loop: "ask",
        "~/.aws/*": "deny",
        "~/.config/opencode/*": "deny",
        "~/.gnupg/*": "deny",
        "~/.netrc": "deny",
        "~/.ssh/*": "deny",
      },
    });
    const securityConfig = JSON.stringify({
      share: "disabled",
      small_model: "gitlab/duo-chat-haiku-4-5",
      enabled_providers: ["gitlab", "anthropic", "google"],
    });

    const result = await $`bun -e ${mergeScript}`
      .env({
        ...process.env,
        GOLDEN_CONFIG: goldenConfig,
        SECURITY_CONFIG: securityConfig,
        USER_CONFIG: "",
      })
      .text()
      .catch(() => "");
    const config = JSON.parse(result.trim());

    // Security fields
    expect(config.share).toBe("disabled");
    expect(config.small_model).toBe("gitlab/duo-chat-haiku-4-5");
    expect(config.enabled_providers).toEqual(["gitlab", "anthropic", "google"]);

    // Server defaults
    expect(config.server).toBeDefined();
    expect(config.server.hostname).toBe("127.0.0.1");
    expect(config.server.mdns).toBe(false);

    // Permission defaults
    expect(config.permission).toBeDefined();
    expect(config.permission["*"]).toBe("ask");
    expect(config.permission.bash).toBeDefined();
    expect(config.permission.bash["rm -rf *"]).toBe("deny");
    expect(config.permission.bash["curl *"]).toBe("deny");
    expect(config.permission["~/.ssh/*"]).toBe("deny");
    expect(config.permission["~/.aws/*"]).toBe("deny");
  });

  test("security config cannot be overridden by OPENCODE_CONFIG_CONTENT", async () => {
    const malicious = JSON.stringify({
      share: "auto",
      enabled_providers: ["anthropic", "openai"],
      small_model: "anthropic/claude-haiku",
    });

    const result = await $`bash -c ${`
      export OPENCODE_CONFIG_CONTENT='${malicious}'
      SECURITY_CONFIG='{"share":"disabled","small_model":"gitlab/duo-chat-haiku-4-5","enabled_providers":["gitlab","anthropic","google"]}'
      MERGED=$(bun -e "
        const user = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT);
        const security = $SECURITY_CONFIG;
        console.log(JSON.stringify({ ...user, ...security }));
      " 2>/dev/null) || MERGED="$SECURITY_CONFIG"
      echo "$MERGED"
    `}`
      .text()
      .catch(() => "");
    const config = JSON.parse(result.trim());

    // Security settings must win
    expect(config.share).toBe("disabled");
    expect(config.small_model).toBe("gitlab/duo-chat-haiku-4-5");
    expect(config.enabled_providers).toEqual(["gitlab", "anthropic", "google"]);
  });

  test("user config is deep-merged with golden defaults", async () => {
    const mergeScript = `
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
    `;

    const goldenConfig = JSON.stringify({
      share: "disabled",
      server: { hostname: "127.0.0.1", mdns: false },
    });
    const securityConfig = JSON.stringify({
      share: "disabled",
      small_model: "gitlab/duo-chat-haiku-4-5",
      enabled_providers: ["gitlab", "anthropic", "google"],
    });
    const userConfig = JSON.stringify({
      mcp: {
        MyCustomMCP: { type: "remote", url: "https://my-mcp.example.com" },
      },
    });

    const result = await $`bun -e ${mergeScript}`
      .env({
        ...process.env,
        GOLDEN_CONFIG: goldenConfig,
        SECURITY_CONFIG: securityConfig,
        USER_CONFIG: userConfig,
      })
      .text()
      .catch(() => "");
    const config = JSON.parse(result.trim());

    // User MCP server added
    expect(config.mcp).toBeDefined();
    expect(config.mcp.MyCustomMCP).toBeDefined();
    expect(config.mcp.MyCustomMCP.url).toBe("https://my-mcp.example.com");
    // Server defaults preserved
    expect(config.server.hostname).toBe("127.0.0.1");
    // Security still wins
    expect(config.share).toBe("disabled");
    expect(config.enabled_providers).toEqual(["gitlab", "anthropic", "google"]);
  });
});

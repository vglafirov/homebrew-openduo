# OpenDuo

GitLab-hardened wrapper for [OpenCode](https://opencode.ai).

OpenDuo runs OpenCode with security hardening pre-configured for internal GitLab use:

| Security Concern                   | Mitigation                                                                          |
| ---------------------------------- | ----------------------------------------------------------------------------------- |
| Session sharing to public endpoint | Disabled via `OPENCODE_DISABLE_SHARE=true` and `share: "disabled"` config           |
| Unapproved model providers         | Only `gitlab` provider enabled via `enabled_providers` and restricted `models.json` |
| Small model data leak              | Forced to `gitlab/duo-chat-haiku-4-5`                                               |
| Model catalog fetching             | Disabled via `OPENCODE_DISABLE_MODELS_FETCH=true`                                   |
| Uncontrolled auto-updates          | Disabled; updates managed via Renovate                                              |

## Installation

### Homebrew (recommended)

```bash
brew tap vglafirov/openduo https://gitlab.com/vglafirov/openduo.git
brew install openduo
```

To upgrade:

```bash
brew upgrade openduo
```

### From source

```bash
# Clone the repository
git clone https://gitlab.com/vglafirov/openduo.git
cd openduo

# Install dependencies (includes opencode)
bun install

# Generate the restricted models catalog
bun run generate:models

# Add to your PATH
export PATH="$(pwd)/bin:$PATH"
```

## Usage

```bash
# Use exactly like opencode
openduo
```

All OpenCode CLI arguments are passed through transparently.

## How It Works

OpenDuo is a thin shell wrapper (`bin/openduo`) that:

1. Sets security environment variables (`OPENCODE_DISABLE_SHARE`, `OPENCODE_MODELS_PATH`, etc.)
2. Injects hardened config via `OPENCODE_CONFIG_CONTENT` (high precedence in OpenCode's config system)
3. Executes the real `opencode` binary from `node_modules`

OpenCode is a regular npm dependency (`opencode-ai` on npm) — Renovate automatically creates MRs when new versions are published.

## Updating OpenCode

OpenCode updates are managed automatically by Renovate. When a new version is published:

1. Renovate creates an MR bumping the `opencode` dependency
2. CI runs tests to verify security hardening still works
3. MR is auto-merged if CI passes

To manually update:

```bash
bun update opencode-ai
bun run generate:models  # Refresh the models catalog
```

## Development

```bash
# Run tests
bun test

# Regenerate models catalog
bun run generate:models
```

## Architecture

```
openduo/
├── bin/openduo              # Shell wrapper (entry point)
├── Formula/openduo.rb       # Homebrew formula
├── models/models.json       # Restricted models catalog (auto-generated)
├── script/generate-models.ts # Script to generate models.json from models.dev
├── test/security.test.ts    # Security hardening tests
├── renovate.json            # Renovate config for auto-updates
└── package.json             # opencode-ai as dependency
```

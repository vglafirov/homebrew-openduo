#!/usr/bin/env bun
/**
 * generate-models.ts
 *
 * Fetches the full models catalog from models.dev and filters it down
 * to only GitLab-approved providers. The output is written to models/models.json
 * and is used at runtime by the openduo wrapper via OPENCODE_MODELS_PATH.
 *
 * Usage:
 *   bun run script/generate-models.ts
 *
 * Environment:
 *   MODELS_DEV_URL  — Override the models.dev API URL (default: https://models.dev)
 */

import path from "path";

const MODELS_URL = process.env.MODELS_DEV_URL ?? "https://models.dev";
const APPROVED_PROVIDERS = ["gitlab"];
const OUTPUT_PATH = path.join(import.meta.dir, "..", "models", "models.json");

async function main() {
  console.log(`Fetching models catalog from ${MODELS_URL}/api.json ...`);

  const response = await fetch(`${MODELS_URL}/api.json`);
  if (!response.ok) {
    throw new Error(
      `Failed to fetch models catalog: ${response.status} ${response.statusText}`,
    );
  }

  const allProviders = (await response.json()) as Record<string, unknown>;
  const filtered: Record<string, unknown> = {};

  for (const providerId of APPROVED_PROVIDERS) {
    if (allProviders[providerId]) {
      filtered[providerId] = allProviders[providerId];
      const models = (allProviders[providerId] as any)?.models;
      const modelCount = models ? Object.keys(models).length : 0;
      console.log(`  ✓ ${providerId}: ${modelCount} models`);
    } else {
      console.warn(`  ⚠ Provider '${providerId}' not found in catalog`);
    }
  }

  const skipped = Object.keys(allProviders).filter(
    (id) => !APPROVED_PROVIDERS.includes(id),
  );
  console.log(`  ✗ Skipped ${skipped.length} providers: ${skipped.join(", ")}`);

  await Bun.write(OUTPUT_PATH, JSON.stringify(filtered, null, 2));
  console.log(`\nWritten to ${OUTPUT_PATH}`);
}

main().catch((err) => {
  console.error("Failed to generate models:", err);
  process.exit(1);
});

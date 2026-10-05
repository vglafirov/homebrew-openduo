#!/usr/bin/env bun
/**
 * check-models-drift.ts
 *
 * openduo polls https://models.dev for its model catalog; opencode itself
 * polls https://models.opencode.ai. They are separate feeds -- opencode.ai is
 * a mirror that lags -- so they can disagree about which models exist and how
 * a provider is wired up.
 *
 * That matters more than it looks. bin/openduo takes provider-level fields
 * straight from the remote catalog, and only overlays the local file's
 * "models" map on top. So "npm" (which package opencode loads) and "env"
 * (which secret it reads) come off the network at every startup, unpinned and
 * unverified -- unlike opencode-ai itself, which is pinned and hash-checked in
 * bun.lock.
 *
 * This script watches for that drift. It changes nothing at runtime; it is
 * observability, not a fix.
 *
 * Runs from the scheduled pipeline only. Two ~5MB fetches on every merge
 * request would put a network dependency in front of every merge and every
 * release, which is the sort of fragility that stalled releases for three
 * weeks in !102/!104.
 *
 * Usage:
 *   bun run script/check-models-drift.ts
 *
 * Environment (testing only -- accepts a path or a URL):
 *   OPENDUO_FEED_PRIMARY    default https://models.dev
 *   OPENDUO_FEED_SECONDARY  default https://models.opencode.ai
 */

import path from "path";

const ROOT = path.join(import.meta.dir, "..");
const WRAPPER = path.join(ROOT, "bin", "openduo");
const LOCAL_MODELS = path.join(ROOT, "models", "models.json");

// openduo's own feed: whatever this says is what users actually get.
const PRIMARY = process.env.OPENDUO_FEED_PRIMARY ?? "https://models.dev";
// What opencode would have used had openduo not replaced the catalog.
const SECONDARY = process.env.OPENDUO_FEED_SECONDARY ?? "https://models.opencode.ai";

const FETCH_TIMEOUT_MS = 30_000;

/**
 * Provider-level fields that decide how a provider is wired up rather than
 * what it costs. "npm" selects the package opencode loads and "env" selects
 * the secret it reads, so a change to either is a trust event, not a price
 * update.
 */
const TRUST_FIELDS = ["id", "npm", "env", "api"] as const;

type Provider = Record<string, unknown> & { models?: Record<string, unknown> };
type Catalog = Record<string, Provider>;

const errors: string[] = [];
const warnings: string[] = [];

/** Sort keys recursively so serialisation order never registers as a difference. */
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value as Record<string, unknown>)
        .sort()
        .map((k) => [k, canonical((value as Record<string, unknown>)[k])]),
    );
  }
  return value;
}

const same = (a: unknown, b: unknown) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));

/**
 * The allowlist lives in bin/openduo. Reading it here keeps this script from
 * becoming a fourth place that has to be kept in step -- Formula/openduo.rb
 * already drifted from the wrapper twice before !105 added a parity guard.
 */
async function allowedProviders(): Promise<string[]> {
  const contents = await Bun.file(WRAPPER).text();
  const match = contents.match(/ALLOWED_PROVIDERS='([\s\S]*?)'/m);
  if (!match) throw new Error(`ALLOWED_PROVIDERS not found in ${WRAPPER}`);
  return JSON.parse(match[1]) as string[];
}

/** A source is a URL or, for tests, a path to a local api.json. */
async function loadCatalog(source: string, label: string): Promise<Catalog | undefined> {
  try {
    if (!/^https?:\/\//.test(source)) return (await Bun.file(source).json()) as Catalog;
    const res = await fetch(`${source}/api.json`, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
    return (await res.json()) as Catalog;
  } catch (err) {
    // Transient network trouble must not raise a false alarm: a check that
    // cries wolf gets muted, and then it is worth nothing when it matters.
    warnings.push(`could not load ${label} (${source}): ${err instanceof Error ? err.message : String(err)}`);
    return undefined;
  }
}

/**
 * The committed catalog is the only copy of these fields that goes through
 * review. Compare the live feed against it so an upstream edit to npm or env
 * is visible rather than silently adopted at the next startup.
 */
function checkTrustBaseline(primary: Catalog, local: Catalog) {
  for (const [id, baseline] of Object.entries(local)) {
    const live = primary[id];
    if (!live) {
      errors.push(`${id}: in committed models/models.json but missing from ${PRIMARY}`);
      continue;
    }
    for (const field of TRUST_FIELDS) {
      if (baseline[field] === undefined && live[field] === undefined) continue;
      if (!same(baseline[field], live[field])) {
        errors.push(
          `${id}.${field}: committed baseline ${JSON.stringify(baseline[field])} ` +
            `but ${PRIMARY} now serves ${JSON.stringify(live[field])}`,
        );
      }
    }
  }
}

function checkFeedParity(primary: Catalog, secondary: Catalog, providers: string[]) {
  for (const id of providers) {
    const a = primary[id];
    const b = secondary[id];

    if (!a && !b) {
      errors.push(`${id}: allowed by bin/openduo but absent from both feeds`);
      continue;
    }
    if (!a) {
      errors.push(`${id}: missing from ${PRIMARY} but present in ${SECONDARY}`);
      continue;
    }
    if (!b) {
      warnings.push(`${id}: present in ${PRIMARY} but not yet in ${SECONDARY}`);
      continue;
    }

    for (const field of TRUST_FIELDS) {
      if (!same(a[field], b[field])) {
        errors.push(
          `${id}.${field}: ${PRIMARY} serves ${JSON.stringify(a[field])} ` +
            `but ${SECONDARY} serves ${JSON.stringify(b[field])}`,
        );
      }
    }

    const inPrimary = Object.keys(a.models ?? {}).sort();
    const inSecondary = Object.keys(b.models ?? {}).sort();

    // Only one direction is a problem. openduo reads the primary feed, so a
    // model the primary lacks is a model openduo users cannot reach even
    // though plain opencode offers it.
    const missingFromPrimary = inSecondary.filter((m) => !inPrimary.includes(m));
    if (missingFromPrimary.length) {
      errors.push(`${id}: in ${SECONDARY} but missing from ${PRIMARY}: ${missingFromPrimary.join(", ")}`);
    }

    // The reverse is the mirror lagging, which is routine and harmless here.
    const missingFromSecondary = inPrimary.filter((m) => !inSecondary.includes(m));
    if (missingFromSecondary.length) {
      warnings.push(`${id}: ahead of ${SECONDARY} by: ${missingFromSecondary.join(", ")}`);
    }

    if (!missingFromPrimary.length && !missingFromSecondary.length && !same(a, b)) {
      warnings.push(`${id}: same models, but metadata differs (costs, limits or descriptions)`);
    }
  }
}

async function main() {
  const providers = await allowedProviders();
  console.log(`Allowed providers (from bin/openduo): ${providers.join(", ")}`);
  console.log(`  primary   (openduo): ${PRIMARY}`);
  console.log(`  secondary (opencode): ${SECONDARY}\n`);

  const [primary, secondary, local] = await Promise.all([
    loadCatalog(PRIMARY, "primary feed"),
    loadCatalog(SECONDARY, "secondary feed"),
    Bun.file(LOCAL_MODELS)
      .json()
      .catch(() => undefined) as Promise<Catalog | undefined>,
  ]);

  if (primary && local) checkTrustBaseline(primary, local);
  else if (!local) warnings.push(`could not read ${LOCAL_MODELS}; skipped trust baseline check`);

  if (primary && secondary) checkFeedParity(primary, secondary, providers);
  else warnings.push("skipped feed comparison: at least one feed was unavailable");

  for (const w of warnings) console.log(`  warning: ${w}`);
  for (const e of errors) console.log(`  ERROR:   ${e}`);

  console.log(`\n${errors.length} error(s), ${warnings.length} warning(s)`);

  if (errors.length) {
    console.log(
      "\nThe feeds disagree in a way that changes what openduo users get, or a\n" +
        "provider's wiring changed upstream. Investigate before the next release.",
    );
    process.exit(1);
  }
  console.log("No meaningful drift.");
}

main().catch((err) => {
  console.error("check-models-drift failed:", err);
  process.exit(1);
});

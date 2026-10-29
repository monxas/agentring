import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const saved = { ...process.env };
afterEach(() => {
  process.env = { ...saved };
});

function baseEnv() {
  process.env.AGENTRING_PUBLIC_URL = "https://relay.test";
  process.env.AGENTRING_DATA_DIR = ":memory:";
  delete process.env.LIVEKIT_API_KEY;
  delete process.env.LIVEKIT_API_SECRET;
  delete process.env.LIVEKIT_API_SECRET_FILE;
  delete process.env.LIVEKIT_URL;
  delete process.env.LIVEKIT_API_URL;
}

describe("LiveKit config", () => {
  it("reads the secret from a file and defaults the URLs to the relay's host", () => {
    baseEnv();
    const dir = mkdtempSync(join(tmpdir(), "agentring-"));
    writeFileSync(join(dir, "secret"), "s".repeat(40) + "\n");
    process.env.LIVEKIT_API_KEY = "lk_test";
    process.env.LIVEKIT_API_SECRET_FILE = join(dir, "secret");
    const lk = loadConfig().livekit!;
    expect(lk.apiSecret).toBe("s".repeat(40));
    expect(lk.publicUrl).toBe("wss://relay.test");
    expect(lk.apiUrl).toBe("https://relay.test");
  });

  it("rejects weak or half-configured secrets and leaves calls off without LiveKit", () => {
    baseEnv();
    expect(loadConfig().livekit).toBeUndefined();
    process.env.LIVEKIT_API_KEY = "lk_test";
    expect(() => loadConfig()).toThrow(/LIVEKIT_API_SECRET/);
    process.env.LIVEKIT_API_SECRET = "short";
    expect(() => loadConfig()).toThrow(/at least 32/);
  });
});

describe("APNs config", () => {
  it("requires all Apple configuration values together", () => {
    baseEnv();
    for (const name of ["APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_ID"]) delete process.env[name];
    expect(loadConfig().apns).toBeUndefined();
    process.env.APNS_KEY_FILE = "/secrets/AuthKey.p8";
    expect(() => loadConfig()).toThrow(/APNS_KEY_ID/);
    process.env.APNS_KEY_ID = "KEY123";
    process.env.APNS_TEAM_ID = "TEAM123";
    process.env.APNS_BUNDLE_ID = "dev.example.agentring";
    expect(loadConfig().apns).toEqual({ keyFile: "/secrets/AuthKey.p8", keyId: "KEY123", teamId: "TEAM123", bundleId: "dev.example.agentring" });
  });
});

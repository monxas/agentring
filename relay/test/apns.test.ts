import { createServer, type IncomingHttpHeaders } from "node:http2";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { afterEach, expect, it, vi } from "vitest";
import { jwtVerify } from "jose";
import { ApnsProvider } from "../src/push/apns.js";
import { connect } from "node:http2";
vi.mock("node:http2", async (original) => {
  const actual = await original<typeof import("node:http2")>();
  return { ...actual, connect: vi.fn(actual.connect) };
});
const cleanup: Array<() => Promise<void> | void> = [];
afterEach(async () => { vi.restoreAllMocks(); for (const f of cleanup.splice(0)) await f(); });

async function harness(status = 200, reason = "") {
  const server = createServer(); server.listen(0, "127.0.0.1"); await once(server, "listening");
  cleanup.push(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address() as { port: number };
  const { connect: realConnect } = await vi.importActual<typeof import("node:http2")>("node:http2");
  vi.mocked(connect).mockImplementation(() => realConnect(`http://127.0.0.1:${address.port}`));
  let headers: IncomingHttpHeaders = {}, body = "";
  server.on("stream", (stream, h) => {
    headers = h; stream.setEncoding("utf8"); stream.on("data", (s: string) => { body += s; });
    stream.on("end", () => { stream.respond({ ":status": status }); stream.end(reason ? JSON.stringify({ reason }) : ""); });
  });
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const dir = mkdtempSync(join(tmpdir(), "agentring-apns-")); cleanup.push(() => rmSync(dir, { recursive: true }));
  const keyFile = join(dir, "key.p8"); writeFileSync(keyFile, privateKey.export({ type: "pkcs8", format: "pem" }));
  const provider = new ApnsProvider({ keyFile, keyId: "KEY123", teamId: "TEAM123", bundleId: "dev.agentring.ios" });
  return { provider, publicKey, received: () => ({ headers, body: JSON.parse(body) }) };
}
const opts = { ttlSeconds: 30, highPriority: true };
const payload = (event: object) => ({ v: "1", relay_id: "relay", event: JSON.stringify(event), sig: "signed" });

it("sends a signed ES256 provider token, VoIP topic, immediate expiry and sandbox endpoint", async () => {
  const h = await harness();
  const result = await h.provider.send({ deviceId: "d", token: "a".repeat(64), channel: "voip", environment: "sandbox" }, payload({ type: "call.invite", direction: "agent_to_user" }), opts);
  expect(result.ok).toBe(true);
  expect(vi.mocked(connect).mock.calls[0]![0]).toBe("https://api.sandbox.push.apple.com");
  const { headers, body } = h.received();
  expect(headers["apns-topic"]).toBe("dev.agentring.ios.voip");
  expect(headers["apns-push-type"]).toBe("voip"); expect(headers["apns-expiration"]).toBe("0");
  expect(body.aps).toEqual({}); expect(body.sig).toBe("signed");
  const verified = await jwtVerify(String(headers.authorization).replace("bearer ", ""), h.publicKey, { issuer: "TEAM123" });
  expect(verified.protectedHeader.kid).toBe("KEY123");
});

it("uses alert topic and production endpoint, keeping Unicode messages within APNs size limits", async () => {
  const h = await harness();
  await h.provider.send({ deviceId: "d", token: "b".repeat(64), channel: "alert", environment: "production" }, payload({ type: "msg.new", from: "agent", text: "😀".repeat(500) }), opts);
  const { headers, body } = h.received();
  expect(vi.mocked(connect).mock.calls[0]![0]).toBe("https://api.push.apple.com");
  expect(headers["apns-topic"]).toBe("dev.agentring.ios"); expect(headers["apns-push-type"]).toBe("alert");
  expect(Array.from(body.aps.alert.body)).toHaveLength(120);
});

it.each([[410, "Unregistered", true], [400, "BadDeviceToken", true], [403, "InvalidProviderToken", false], [400, "DeviceTokenNotForTopic", false]])(
  "APNs %s %s clears only invalid registrations", async (status, reason, unregistered) => {
    const h = await harness(status, reason);
    expect(await h.provider.send({ deviceId: "d", token: "a".repeat(64), channel: "voip" }, payload({ type: "call.invite", direction: "agent_to_user" }), opts))
      .toMatchObject({ ok: false, unregistered });
  });

it("never emits a VoIP push for a cancellation", async () => {
  const h = await harness();
  expect(await h.provider.send({ deviceId: "d", token: "a".repeat(64), channel: "voip" }, payload({ type: "call.end" }), opts)).toMatchObject({ ok: false, unregistered: false });
  expect(connect).not.toHaveBeenCalled();
});

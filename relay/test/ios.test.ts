import { afterEach, expect, it } from "vitest";
import { buildApp, type BuiltApp } from "../src/app.js";
import { AGENT, FakeLiveKit, FakePush, pairDevice, testConfig } from "./helpers.js";

const apps: BuiltApp[] = [];
afterEach(async () => { for (const b of apps.splice(0)) await b.app.close(); });
async function setup() {
  const fcm = new FakePush(), apns = new FakePush();
  const b = await buildApp(testConfig(), { logger: false, pushProvider: fcm, apnsProvider: apns, livekit: new FakeLiveKit() });
  apps.push(b);
  const t = (await b.app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: AGENT })).json();
  const paired = await b.app.inject({ method: "POST", url: "/v1/pair", payload: {
    pairing_token: t.pairing_token, device_name: "iPhone", platform: "ios" } });
  expect(paired.statusCode).toBe(201);
  const ios = paired.json();
  expect(ios.push_config).toBeNull();
  const headers = { authorization: `Bearer ${ios.device_jwt}` };
  const tokens = { alert_token: "a".repeat(64), voip_token: "b".repeat(64), environment: "sandbox" };
  const registered = await b.app.inject({ method: "POST", url: "/v1/device/apns", headers, payload: tokens });
  expect(registered.statusCode).toBe(204);
  return { ...b, fcm, apns, ios, headers, tokens };
}
const flush = () => new Promise((resolve) => setImmediate(resolve));

it("pairs iOS and routes messages to APNs alert, Android to FCM", async () => {
  const b = await setup();
  await pairDevice(b);
  const devices = (await b.app.inject({ url: "/v1/devices", headers: AGENT })).json().devices;
  expect(devices[0]).toMatchObject({ platform: "ios", has_push_token: true });
  await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "Hello iOS" } });
  await flush();
  expect(b.apns.sent).toHaveLength(1); expect(b.fcm.sent).toHaveLength(1);
  expect(b.apns.sent[0]!.target).toMatchObject({ token: b.tokens.alert_token, channel: "alert", environment: "sandbox" });
});

it("uses VoIP only for invites; call updates stay on the socket", async () => {
  const b = await setup();
  const response = await b.app.inject({ method: "POST", url: "/v1/calls", headers: AGENT, payload: { reason: "Decision" } });
  const id = response.json().call.call_id;
  await flush();
  expect(b.apns.sent[0]!.target).toMatchObject({ token: b.tokens.voip_token, channel: "voip" });
  await b.app.inject({ method: "POST", url: `/v1/calls/${id}/accept`, headers: b.headers });
  await b.app.inject({ method: "POST", url: `/v1/calls/${id}/end`, headers: b.headers });
  await flush();
  expect(b.apns.sent).toHaveLength(1);
});

it("enforces targeted-call privacy for iOS", async () => {
  const b = await setup(); const android = await pairDevice(b);
  await b.app.inject({ method: "POST", url: "/v1/calls", headers: AGENT, payload: { reason: "Private", device_ids: [android.device_id] } });
  await flush(); expect(b.apns.sent).toHaveLength(0); expect(b.fcm.sent).toHaveLength(1);
});

it("checks authentication, platform, token format and environment", async () => {
  const b = await setup(); const android = await pairDevice(b);
  const send = (headers: Record<string, string>, payload: object) => b.app.inject({ method: "POST", url: "/v1/device/apns", headers, payload });
  expect((await send({}, b.tokens)).statusCode).toBe(401);
  expect((await send(AGENT, b.tokens)).statusCode).toBe(403);
  expect((await send(android.headers, b.tokens)).statusCode).toBe(403);
  expect((await send(b.headers, { ...b.tokens, environment: "other" })).statusCode).toBe(400);
  expect((await send(b.headers, { ...b.tokens, voip_token: "bad" })).statusCode).toBe(400);
  expect((await send(b.headers, { ...b.tokens, alert_token: null, voip_token: null })).statusCode).toBe(204);
});

it("clears only the expired APNs token and preserves a replacement on an in-flight failure", async () => {
  const b = await setup(); b.apns.next = { ok: false, unregistered: true, error: "Unregistered" };
  await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "Hello" } });
  await flush();
  const row = b.ctx.db.prepare("SELECT * FROM devices WHERE device_id = ?").get(b.ios.device_id)!;
  expect(row.apns_alert_token).toBeNull(); expect(row.apns_voip_token).toBe(b.tokens.voip_token);
  b.apns.send = async () => {
    b.ctx.db.prepare("UPDATE devices SET apns_alert_token = ? WHERE device_id = ?").run("c".repeat(64), b.ios.device_id);
    return { ok: false, unregistered: true, error: "Unregistered" };
  };
  b.ctx.db.prepare("UPDATE devices SET apns_alert_token = ? WHERE device_id = ?").run(b.tokens.alert_token, b.ios.device_id);
  await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "Again" } });
  await flush();
  expect(b.ctx.db.prepare("SELECT apns_alert_token FROM devices WHERE device_id = ?").get(b.ios.device_id)!.apns_alert_token).toBe("c".repeat(64));
});

it("revocation removes both tokens and invalidates device credentials", async () => {
  const b = await setup();
  await b.app.inject({ method: "DELETE", url: `/v1/devices/${b.ios.device_id}`, headers: AGENT });
  const row = b.ctx.db.prepare("SELECT * FROM devices WHERE device_id = ?").get(b.ios.device_id)!;
  expect(row.apns_voip_token).toBeNull(); expect(row.apns_alert_token).toBeNull();
  expect((await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: b.headers, payload: b.tokens })).statusCode).toBe(401);
});

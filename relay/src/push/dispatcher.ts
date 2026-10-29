import { createHmac } from "node:crypto";
import type { FastifyBaseLogger } from "fastify";
import type { Db } from "../db/database.js";
import type { Event } from "../protocol.js";
import type { PushPayload, PushProvider } from "./push-provider.js";

/** FCM data payloads are capped at 4096 bytes; leave room for the other keys. */
const MAX_EVENT_BYTES = 3000;
const MESSAGE_TTL_S = 28 * 24 * 3600;
/** Call state changes only matter while a phone may still be ringing or on the call. */
const CALL_UPDATE_TTL_S = 30;
/** "Someone is on the call, you can join": long enough for a phone that was offline; the app re-checks the call. */
const CALL_JOINABLE_TTL_S = 3600;

/** Just enough of a call for push routing; `device_ids` = the phones a targeted call rings. */
export type CallLookup = (callId: string) => { direction: string; device_ids?: string[] } | undefined;

export function signEvent(pushSecret: string, eventJson: string): string {
  return createHmac("sha256", Buffer.from(pushSecret, "base64url")).update(eventJson, "utf8").digest("base64url");
}

export function buildPayload(relayId: string, pushSecret: string, event: Event): PushPayload {
  let json = JSON.stringify(event);
  if (event.type === "msg.new") {
    let text = event.text;
    while (Buffer.byteLength(json) > MAX_EVENT_BYTES && text.length > 0) {
      const overflow = Buffer.byteLength(json) - MAX_EVENT_BYTES;
      // Cut by code points so we never split a surrogate pair.
      const chars = Array.from(text);
      text = chars.slice(0, Math.max(0, chars.length - Math.max(overflow, 16))).join("");
      json = JSON.stringify({ ...event, text, truncated: true });
    }
  }
  return { v: "1", relay_id: relayId, event: json, sig: signEvent(pushSecret, json) };
}

interface PushRule {
  ttlSeconds: number;
  highPriority: boolean;
}

/** Which events wake the phone. Everything else is delivered over the WebSocket only. */
function ruleFor(event: Event, getCall: CallLookup): PushRule | undefined {
  switch (event.type) {
    case "msg.new":
      return event.from === "agent" ? { ttlSeconds: MESSAGE_TTL_S, highPriority: true } : undefined;
    case "call.invite":
      // Never deliver an invite after it expired: TTL = time left to ring.
      return event.direction === "agent_to_user"
        ? { ttlSeconds: Math.max(1, Math.ceil((event.expires_at - Date.now()) / 1000)), highPriority: true }
        : undefined;
    case "call.accept":
      // Lets the other phones offer "join the call" (also those whose ring ended or
      // that never got the invite). Normal priority: it doesn't need to wake a phone
      // in Doze, and a high-priority push that shows nothing (the phones still
      // ringing) gets the app's later pushes deprioritized.
      return event.by === "user" && getCall(event.call_id)?.direction === "agent_to_user"
        ? { ttlSeconds: CALL_JOINABLE_TTL_S, highPriority: false }
        : undefined;
    // call.decline is not pushed: in a group call one phone declining doesn't affect the others.
    case "call.end":
    case "call.missed":
      // Stops the ringing on every device (or tears down the call screen).
      return getCall(event.call_id)?.direction === "agent_to_user"
        ? { ttlSeconds: CALL_UPDATE_TTL_S, highPriority: true }
        : undefined;
    default:
      return undefined;
  }
}

export class PushDispatcher {
  constructor(
    private readonly db: Db,
    private readonly provider: PushProvider | undefined,
    private readonly relayId: string,
    private readonly log: FastifyBaseLogger,
    private readonly getCall: CallLookup = () => undefined,
    private readonly apns?: PushProvider,
  ) {}

  handle(event: Event): void {
    if (!this.provider && !this.apns) return;
    const rule = ruleFor(event, this.getCall);
    if (!rule) return;
    const devices = this.db
      .prepare("SELECT * FROM devices WHERE revoked_at IS NULL")
      .all() as Array<{ device_id: string; platform: string; push_secret: string; fcm_token: string | null; apns_alert_token: string | null; apns_voip_token: string | null; apns_environment: "sandbox" | "production" }>;
    // A targeted call's pushes only go to the phones it targets.
    const targets = event.type.startsWith("call.") ? this.getCall((event as { call_id: string }).call_id)?.device_ids : undefined;
    for (const d of devices) {
      if (targets && !targets.includes(d.device_id)) continue;
      // The phone that joined already knows.
      if (event.type === "call.accept" && event.device_id === d.device_id) continue;
      // Apple permits VoIP pushes only for new incoming calls. Call state travels over WS.
      const ios = d.platform === "ios";
      if (ios && event.type !== "call.invite" && event.type !== "msg.new") continue;
      const column = ios ? (event.type === "call.invite" ? "apns_voip_token" : "apns_alert_token") : "fcm_token";
      const token = d[column];
      const provider = ios ? this.apns : this.provider;
      if (!token || !provider) continue;
      const payload = buildPayload(this.relayId, d.push_secret, event);
      void provider
        .send({ deviceId: d.device_id, token, environment: d.apns_environment, channel: event.type === "call.invite" ? "voip" : "alert" }, payload, rule)
        .then((res) => {
          if (res.ok) {
            this.log.debug({ device: d.device_id, event: event.type }, "push sent");
            return;
          }
          this.log.warn({ device: d.device_id, event: event.type, error: res.error }, "push failed");
          if (res.unregistered) {
            this.db
              .prepare(`UPDATE devices SET ${column} = NULL WHERE device_id = ? AND ${column} = ?`)
              .run(d.device_id, token);
          }
        })
        .catch((e: unknown) => this.log.error({ err: e, device: d.device_id }, "push error"));
    }
  }
}

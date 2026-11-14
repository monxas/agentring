import { readFileSync } from "node:fs";
import { connect, constants } from "node:http2";
import { importPKCS8, SignJWT } from "jose";
import type { Config } from "../config.js";
import type { PushOptions, PushPayload, PushProvider, PushResult, PushTarget } from "./push-provider.js";

/** APNs HTTP/2 with token authentication; no Firebase or extra runtime dependency. */
export class ApnsProvider implements PushProvider {
  readonly name = "apns";
  private key: ReturnType<typeof importPKCS8>;
  private cached?: { token: string; issued: number };

  constructor(private readonly cfg: NonNullable<Config["apns"]>) {
    this.key = importPKCS8(readFileSync(cfg.keyFile, "utf8"), "ES256");
  }

  async prepare(): Promise<void> { await this.key; }

  private async authorization(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (this.cached && now - this.cached.issued < 3000) return this.cached.token;
    const token = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: this.cfg.keyId })
      .setIssuer(this.cfg.teamId).setIssuedAt(now).sign(await this.key);
    this.cached = { token, issued: now };
    return token;
  }

  async send(target: PushTarget, payload: PushPayload, _opts: PushOptions): Promise<PushResult> {
    const event = JSON.parse(payload.event!) as { type: string; text?: string; from?: string; direction?: string };
    const voip = target.channel === "voip";
    if (voip ? event.type !== "call.invite" || event.direction !== "agent_to_user" : event.type !== "msg.new" || event.from !== "agent")
      return { ok: false, unregistered: false, error: "Unsupported APNs event" };
    const authorization = await this.authorization();
    const body = JSON.stringify({
      aps: voip ? {} : { alert: { title: "agentring", body: Array.from(event.text ?? "New message").slice(0, 120).join("") }, sound: "default" },
      ...payload,
    });
    if (Buffer.byteLength(body) > (voip ? 5120 : 4096))
      return { ok: false, unregistered: false, error: "APNs payload too large" };
    return new Promise((resolve) => {
      const session = connect(target.environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com");
      let done = false;
      const finish = (result: PushResult) => {
        if (done) return;
        done = true;
        clearTimeout(timeout);
        session.destroy();
        resolve(result);
      };
      const timeout = setTimeout(() => finish({ ok: false, unregistered: false, error: "APNs timeout" }), 10_000);
      session.on("error", (e) => finish({ ok: false, unregistered: false, error: e.message }));
      const request = session.request({
        [constants.HTTP2_HEADER_METHOD]: "POST",
        [constants.HTTP2_HEADER_PATH]: `/3/device/${target.token}`,
        authorization: `bearer ${authorization}`,
        "content-type": "application/json",
        "apns-topic": this.cfg.bundleId + (voip ? ".voip" : ""),
        "apns-push-type": voip ? "voip" : "alert",
        "apns-priority": "10",
        // Never queue an incoming call to ring after it has expired.
        "apns-expiration": "0",
      });
      let status = 0;
      let response = "";
      request.setEncoding("utf8");
      request.on("response", (h) => { status = Number(h[":status"]); });
      request.on("data", (chunk: string) => { response += chunk; });
      request.on("error", (e) => finish({ ok: false, unregistered: false, error: e.message }));
      request.on("end", () => {
        if (status === 200) return finish({ ok: true });
        let reason = response;
        try { reason = (JSON.parse(response) as { reason: string }).reason; } catch { /* retain response */ }
        finish({ ok: false, unregistered: ["Unregistered", "BadDeviceToken"].includes(reason), error: `APNs ${status}: ${reason}` });
      });
      request.end(body);
    });
  }
}

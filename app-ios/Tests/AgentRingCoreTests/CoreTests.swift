import XCTest
@testable import AgentRingCore

final class CoreTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testSharedPushVectorAndTampering() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/examples/push/signature-vector.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = fixture["data"] as! [String: String], secret = fixture["push_secret"] as! String
        let event = try PushVerifier.verify(payload, relayID: payload["relay_id"]!, secret: secret)
        XCTAssertEqual(event.type, "msg.new"); XCTAssertEqual(event.seq, 45)
        var tampered = payload; tampered["event"]! += " "
        XCTAssertThrowsError(try PushVerifier.verify(tampered, relayID: payload["relay_id"]!, secret: secret))
        XCTAssertThrowsError(try PushVerifier.verify(payload, relayID: "another-relay", secret: secret))
        XCTAssertThrowsError(try PushVerifier.verify(payload, relayID: payload["relay_id"]!, secret: "invalid"))
    }
    func testURLPolicyAndCredentialBoundaries() throws {
        for url in ["http://localhost:8080", "https://user:pass@example.com", "https://example.com?key=x", "https://example.com/path", "https://example.com#x", "file:///tmp/test"] {
            XCTAssertThrowsError(try RelayURL.validate(url), url)
        }
        let api = try RelayAPI(url: "https://relay.example.com:8443", jwt: "test")
        XCTAssertEqual(try api.request("/v1/status").value(forHTTPHeaderField: "Authorization"), "Bearer test")
        XCTAssertThrowsError(try api.request("https://evil.example/v1/status"))
        XCTAssertThrowsError(try api.request("https://relay.example.com/v1/status"))
    }
    func testPairingVersionAndCallFixtures() throws {
        let qr = #"{"v":1,"relay_url":"https://relay.example.com","pairing_token":"pt_token"}"#
        XCTAssertEqual(try PairingQR.parse(qr).v, 1)
        XCTAssertThrowsError(try PairingQR.parse(qr.replacingOccurrences(of: "\"v\":1", with: "\"v\":2")))
        for name in ["call.invite", "call.invite.targeted", "call.accept", "call.end", "call.missed", "msg.new", "ws.hello"] {
            let data = try Data(contentsOf: root.appendingPathComponent("protocol/examples/events/\(name).json"))
            _ = try JSONDecoder().decode(RelayEvent.self, from: data)
        }
    }
}

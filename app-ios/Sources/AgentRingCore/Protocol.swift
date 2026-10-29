import Foundation
import CryptoKit

public enum RelayError: LocalizedError {
    case invalidURL, invalidQR, invalidPush, http(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use an HTTPS relay URL without credentials, query or fragment."
        case .invalidQR: return "Invalid agentring pairing QR (version 1 required)."
        case .invalidPush: return "Invalid push signature or relay."
        case let .http(code, message): return "Relay \(code): \(message)"
        }
    }
}

public struct PairingQR: Decodable {
    public let v: Int
    public let relay_url: String
    public let pairing_token: String
    public static func parse(_ text: String) throws -> PairingQR {
        let qr = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard qr.v == 1, qr.pairing_token.hasPrefix("pt_") else { throw RelayError.invalidQR }
        _ = try RelayURL.validate(qr.relay_url)
        return qr
    }
}

public enum RelayURL {
    public static func validate(_ value: String) throws -> URL {
        guard let c = URLComponents(string: value), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", let url = c.url else { throw RelayError.invalidURL }
        return url
    }
}

public struct Credentials: Codable {
    public let relayURL: String
    public let device_id: String
    public let device_jwt: String
    public let push_secret: String
    public let relay_id: String
    public let agent_name: String
    public init(relayURL: String, pair: PairResponse) {
        self.relayURL = relayURL; device_id = pair.device_id; device_jwt = pair.device_jwt
        push_secret = pair.push_secret; relay_id = pair.relay_id; agent_name = pair.agent_name
    }
}
public struct PairResponse: Decodable {
    public let device_id: String
    public let device_jwt: String
    public let push_secret: String
    public let relay_id: String
    public let agent_name: String
}
public struct Message: Decodable, Identifiable {
    public var id: String { msg_id }
    public let msg_id: String
    public let from: String
    public let text: String
    public let created_at: Double
    public let read_at: Double?
}
public struct MessagePage: Decodable {
    public let messages: [Message]
    public let has_more: Bool
}
public struct RelayCall: Decodable {
    public let call_id: String
    public let direction: String
    public let state: String
    public let reason: String?
    public let agent_name: String
}
public struct JoinInfo: Decodable {
    public let livekit_url: String
    public let livekit_token: String
}
public struct CallWithJoin: Decodable {
    public let call: RelayCall
    public let join: JoinInfo
}
public struct RelayStatus: Decodable {
    public let agent_online: Bool
    public let active_call: RelayCall?
    public let push_provider: String
}
public struct RelayEvent: Decodable {
    public let type: String
    public let seq: Int?
    public let call_id: String?
    public let direction: String?
    public let agent_name: String?
    public let expires_at: Double?
    public let device_id: String?
    public let by: String?
    public let online: Bool?
}

public enum PushVerifier {
    public static func decodeBase64URL(_ s: String) -> Data? {
        let base = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
    public static func verify(_ data: [String: String], relayID: String, secret: String) throws -> RelayEvent {
        guard data["v"] == "1", data["relay_id"] == relayID, let json = data["event"],
              let signature = data["sig"].flatMap(decodeBase64URL), let key = decodeBase64URL(secret), key.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(json.utf8), using: SymmetricKey(data: key))
        else { throw RelayError.invalidPush }
        return try JSONDecoder().decode(RelayEvent.self, from: Data(json.utf8))
    }
}

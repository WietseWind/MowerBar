import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case http(Int)
    case api(code: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No credentials. Open Settings and paste your client ID and secret."
        case .http(let status):
            return "Server returned HTTP \(status)."
        case .api(let code, let message):
            return message.isEmpty ? "Mammotion API error \(code)." : message
        case .malformedResponse:
            return "Could not read the server's response."
        }
    }
}

/// Thin client over the Mammotion Open API.
///
/// Authentication is `client_credentials` only — the token endpoint accepts no
/// `authorization_code` grant, so there is no browser redirect step. The
/// credentials themselves *are* the account identity, minted on the developer
/// portal. Tokens are long-lived (~15 days) and refreshed via `refresh_token`.
actor MammotionAPI {
    private var config: AppConfig
    private var token: StoredToken?
    private let session: URLSession

    init(config: AppConfig) {
        self.config = config
        self.token = Store.loadToken()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func update(config newValue: AppConfig) {
        // Changing credentials invalidates any cached token.
        if newValue.clientId != config.clientId || newValue.clientSecret != config.clientSecret {
            token = nil
            Store.saveToken(nil)
        }
        config = newValue
    }

    var tokenExpiry: Date? { token?.expiresAt }

    // MARK: - Endpoints

    func listDevices() async throws -> [DeviceInfo] {
        try await get("/v1/mowers", as: [DeviceInfo].self)
    }

    func detail(_ deviceId: String) async throws -> DeviceDetail {
        try await get("/v1/mower/\(encoded(deviceId))", as: DeviceDetail.self)
    }

    func tasks(_ deviceId: String) async throws -> [WorkTask] {
        try await get("/v1/mower/\(encoded(deviceId))/plan", as: [WorkTask].self)
    }

    @discardableResult
    func send(_ action: MowerAction, to deviceId: String, taskName: String? = nil) async throws -> String {
        var body: [String: Any] = ["deviceId": deviceId, "action": action.rawValue]
        if let taskName, !taskName.isEmpty { body["params"] = ["taskName": taskName] }

        var request = URLRequest(url: try url(for: "/v1/mower/action"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // A successful action can come back with no `data` payload at all.
        let result = try decodeOptional(await authorizedData(request), as: WorkActionResult.self)
        if let result, result.commandResult == false {
            throw APIError.api(code: -1, message: result.resultMessage ?? "The mower rejected the command.")
        }
        return result?.resultMessage ?? "Command sent."
    }

    private struct WorkActionResult: Decodable {
        let commandResult: Bool?
        let resultMessage: String?
    }

    // MARK: - Authentication

    /// Forces a fresh `client_credentials` exchange. Used by the Settings sheet
    /// so "Sign In" gives immediate, unambiguous feedback.
    @discardableResult
    func signIn() async throws -> Date {
        let fresh = try await requestToken(refreshing: nil)
        store(fresh)
        return fresh.expiresAt
    }

    func signOut() {
        token = nil
        Store.saveToken(nil)
    }

    private func accessToken() async throws -> String {
        guard config.isConfigured else { throw APIError.notConfigured }
        if let token, token.isFresh { return token.accessToken }

        if let refresh = token?.refreshToken, !refresh.isEmpty,
           let renewed = try? await requestToken(refreshing: refresh) {
            store(renewed)
            return renewed.accessToken
        }
        let fresh = try await requestToken(refreshing: nil)
        store(fresh)
        return fresh.accessToken
    }

    private func store(_ value: StoredToken) {
        token = value
        Store.saveToken(value)
    }

    private struct AccessTokenVo: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    private func requestToken(refreshing refreshToken: String?) async throws -> StoredToken {
        guard config.isConfigured else { throw APIError.notConfigured }

        var fields = [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "grant_type": refreshToken == nil ? "client_credentials" : "refresh_token"
        ]
        if let refreshToken { fields["refresh_token"] = refreshToken }

        var request = URLRequest(url: try url(config.authBaseURL, "/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(fields)

        let vo = try decode(await perform(request), as: AccessTokenVo.self)
        // The API reports ~15 days; shave a minute so we never race the expiry.
        let lifetime = TimeInterval(vo.expires_in ?? 3600)
        return StoredToken(accessToken: vo.access_token,
                           refreshToken: vo.refresh_token,
                           expiresAt: Date().addingTimeInterval(max(60, lifetime - 60)))
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "GET"
        return try decode(await authorizedData(request), as: type)
    }

    /// Attaches the bearer token, and on a 401 re-authenticates once and retries.
    private func authorizedData(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue(config.acceptLanguage, forHTTPHeaderField: "Accept-Language")

        do {
            return try await perform(request)
        } catch APIError.http(401) {
            signOut()
            var retry = request
            retry.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            return try await perform(retry)
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }
        // Non-2xx still carries a useful `msg`, so only 401 short-circuits here.
        guard http.statusCode != 401 else { throw APIError.http(401) }
        guard (200..<300).contains(http.statusCode) || !data.isEmpty else {
            throw APIError.http(http.statusCode)
        }
        return data
    }

    /// Unwraps `{ code, msg, data }`, turning a non-zero `code` into a readable error.
    /// Checked before decoding `data` so a shape mismatch never masks the real message.
    private func checked(_ data: Data) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(BareEnvelope.self, from: data) else {
            throw APIError.malformedResponse
        }
        guard envelope.code == 0 else {
            throw APIError.api(code: envelope.code, message: envelope.msg ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        guard let value = try decodeOptional(data, as: type) else { throw APIError.malformedResponse }
        return value
    }

    private func decodeOptional<T: Decodable>(_ data: Data, as type: T.Type) throws -> T? {
        let body = try checked(data)
        return (try? JSONDecoder().decode(APIResponse<T>.self, from: body))?.data
    }

    private struct BareEnvelope: Decodable {
        let code: Int
        let msg: String?
    }

    // MARK: - URL helpers

    private func url(for path: String) throws -> URL {
        try url(config.apiBaseURL, path)
    }

    private func url(_ base: String, _ path: String) throws -> URL {
        guard let url = URL(string: base.hasSuffix("/") ? String(base.dropLast()) + path : base + path) else {
            throw APIError.malformedResponse
        }
        return url
    }

    private func encoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

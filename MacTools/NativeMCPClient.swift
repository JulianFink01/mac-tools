import Foundation
import Network
import Security
import CryptoKit

/// Direct HTTP MCP and OAuth; no Codex process, model, prompt or inference is involved.
@MainActor final class NativeMCPClient {
    enum Failure: LocalizedError {
        case loginRequired, invalid(String)
        var errorDescription: String? { switch self { case .loginRequired: return "Anmeldung erforderlich"; case .invalid(let text): return text } }
    }
    struct Credential: Codable {
        var clientID: String, redirectURI: String, accessToken: String, refreshToken: String?
        var expiresAt: Date, tokenEndpoint: String, resource: String
    }
    let endpoint: URL
    private let session: URLSession
    private let loadSecret: () -> Data?
    private let saveSecret: (Data) throws -> Void
    private var sessionID: String?
    private var initialized = false
    private var sequence = 0
    private var receiver: OAuthLoopbackReceiver?
    init(endpoint: URL, session: URLSession? = nil, loadSecret: (() -> Data?)? = nil, saveSecret: ((Data) throws -> Void)? = nil) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 18
        configuration.httpMaximumConnectionsPerHost = 2; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration, delegate: NativeMCPRedirectPolicy(), delegateQueue: nil)
        let account = endpoint.absoluteString
        self.loadSecret = loadSecret ?? { Self.readKeychain(account) }
        self.saveSecret = saveSecret ?? { try Self.writeKeychain($0, account: account) }
    }
    func cancel() { receiver?.cancel(); receiver = nil; initialized = false; sessionID = nil }
    private var credential: Credential? { loadSecret().flatMap { try? JSONDecoder().decode(Credential.self, from: $0) } }
    private func store(_ credential: Credential) throws { try saveSecret(JSONEncoder().encode(credential)) }
    private func accessToken() async throws -> String {
        guard var value = credential else { throw Failure.loginRequired }
        if value.expiresAt > Date().addingTimeInterval(30) { return value.accessToken }
        guard let refresh = value.refreshToken, let url = URL(string: value.tokenEndpoint), url.scheme == "https" else { throw Failure.loginRequired }
        let response = try await tokenRequest(url, fields: ["grant_type":"refresh_token", "refresh_token":refresh, "client_id":value.clientID, "resource":value.resource])
        guard let token = response["access_token"] as? String else { throw Failure.loginRequired }
        value.accessToken = token; value.refreshToken = response["refresh_token"] as? String ?? refresh
        value.expiresAt = Date().addingTimeInterval(response["expires_in"] as? Double ?? 3600)
        try store(value); initialized = false; return token
    }
    func call(_ tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        let token = try await accessToken()
        do {
        if !initialized {
            _ = try await rpc("initialize", params: ["protocolVersion":"2025-03-26", "capabilities":[:], "clientInfo":["name":"MacTools", "version":"0.2.3"]], token: token)
            _ = try await rpc("notifications/initialized", params: [:], token: token, notification: true)
            initialized = true
        }
        return try await rpc("tools/call", params: ["name":tool, "arguments":arguments], token: token)
        } catch { initialized = false; sessionID = nil; throw error }
    }
    private func rpc(_ method: String, params: [String: Any], token: String?, notification: Bool = false) async throws -> [String: Any] {
        sequence += 1
        var body: [String:Any] = ["jsonrpc":"2.0", "method":method, "params":params]
        if !notification { body["id"] = sequence }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalid("MCP liefert keine HTTP-Antwort.") }
        if [401,403].contains(http.statusCode) { throw Failure.loginRequired }
        guard (200..<300).contains(http.statusCode) else { throw Failure.invalid("MCP-Abfrage fehlgeschlagen (HTTP \(http.statusCode)).") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        if notification { return [:] }
        let value = try Self.message(data, expectedID: sequence)
        if let error = value["error"] as? [String:Any] { throw Failure.invalid("MCP: " + (error["message"] as? String ?? "Abfrage fehlgeschlagen")) }
        guard let result = value["result"] as? [String:Any] else { throw Failure.invalid("MCP-Antwort ist unvollständig.") }
        return result
    }
    static func message(_ data: Data, expectedID: Int) throws -> [String:Any] {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String:Any] { return json }
        let source = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for event in source.components(separatedBy: "\n\n") {
            let text = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any], json["id"] as? Int == expectedID { return json }
        }
        throw Failure.invalid("MCP liefert keine passende JSON-Antwort.")
    }
    private func metadata(_ url: URL) async throws -> [String:Any] {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw Failure.invalid("Ungültige OAuth-Metadatenadresse.") }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let value = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw Failure.invalid("OAuth-Metadaten nicht erreichbar.") }
        return value
    }
    private func discover() async throws -> (resource: String, server: [String:Any]) {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1, "method":"initialize", "params":["protocolVersion":"2025-03-26", "capabilities":[:], "clientInfo":["name":"MacTools", "version":"0.2.3"]]])
        let (_, response) = try await session.data(for: request)
        guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate"), let range = header.range(of: #"resource_metadata="[^"]+""#, options: .regularExpression), let resourceURL = URL(string: String(header[range]).dropFirst(19).dropLast().description) else { throw Failure.invalid("Der Dienst liefert keine OAuth-Discovery-Adresse.") }
        let resource = try await metadata(resourceURL)
        guard let resourceName = resource["resource"] as? String, resourceName == endpoint.absoluteString,
              let issuerText = (resource["authorization_servers"] as? [String])?.first, let issuer = URL(string: issuerText), issuer.scheme == "https", let host = issuer.host else { throw Failure.invalid("OAuth-Ressource passt nicht zum MCP-Server.") }
        var origin = URLComponents(); origin.scheme = "https"; origin.host = host; origin.port = issuer.port
        origin.path = "/.well-known/oauth-authorization-server" + issuer.path
        let server: [String:Any]
        do { server = try await metadata(origin.url!) } catch { server = try await metadata(issuer.appendingPathComponent(".well-known/oauth-authorization-server")) }
        guard server["issuer"] as? String == issuerText else { throw Failure.invalid("OAuth-Aussteller stimmt nicht überein.") }
        return (resourceName, server)
    }
    /// Minimal RFC 7591 registration works with strict providers too; PKCE handles the public client.
    func signIn(onURL: @escaping (URL) -> Void) async throws {
        let discovery = try await discover(), server = discovery.server
        func endpoint(_ key: String) throws -> URL { guard let text = server[key] as? String, let url = URL(string:text), url.scheme == "https", url.user == nil, url.password == nil else { throw Failure.invalid("OAuth-Endpunkt fehlt oder ist unsicher.") }; return url }
        let authorization = try endpoint("authorization_endpoint"), token = try endpoint("token_endpoint"), registration = try endpoint("registration_endpoint")
        let state = try Self.random(), verifier = try Self.random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let previous = credential
        let preferredPort = previous.flatMap { URLComponents(string:$0.redirectURI)?.port }.flatMap(UInt16.init(exactly:))
        var callback = OAuthLoopbackReceiver(state: state)
        var port: UInt16
        do { port = try await callback.start(port: preferredPort) } catch { callback = OAuthLoopbackReceiver(state: state); port = try await callback.start(port:nil) }
        receiver = callback; defer { callback.cancel(); receiver = nil }
        let redirect = "http://127.0.0.1:\(port)/callback"
        let clientID: String
        if let previous, previous.redirectURI == redirect { clientID = previous.clientID }
        else {
            var request = URLRequest(url:registration); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name":"MacTools · private Health", "redirect_uris":[redirect], "token_endpoint_auth_method":"none", "grant_types":["authorization_code","refresh_token"], "response_types":["code"]])
            let (data,response) = try await session.data(for:request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let result = try JSONSerialization.jsonObject(with:data) as? [String:Any], let id = result["client_id"] as? String else { throw Failure.invalid("Der Dienst hat die OAuth-Registrierung abgelehnt.") }; clientID = id
        }
        var url = URLComponents(url:authorization,resolvingAgainstBaseURL:false)!
        url.queryItems = ["response_type":"code", "client_id":clientID, "redirect_uri":redirect, "state":state, "code_challenge":challenge, "code_challenge_method":"S256", "resource":discovery.resource].map { URLQueryItem(name:$0.key,value:$0.value) }
        if let scopes = server["scopes_supported"] as? [String], !scopes.isEmpty { url.queryItems?.append(URLQueryItem(name:"scope",value:scopes.joined(separator:" "))) }
        guard let login = url.url else { throw Failure.invalid("Anmeldeseite ungültig.") }; onURL(login)
        let answer = try await callback.wait()
        if let issuer = answer["iss"], issuer != server["issuer"] as? String { throw Failure.invalid("OAuth-Antwort stammt von einem anderen Aussteller.") }
        if server["authorization_response_iss_parameter_supported"] as? Bool == true, answer["iss"] == nil { throw Failure.invalid("OAuth-Aussteller fehlt in der Antwort.") }
        guard let code = answer["code"] else { throw Failure.invalid("Anmeldung wurde abgelehnt.") }
        let result = try await tokenRequest(token, fields:["grant_type":"authorization_code", "client_id":clientID, "redirect_uri":redirect, "code":code, "code_verifier":verifier, "resource":discovery.resource])
        guard let access = result["access_token"] as? String else { throw Failure.invalid("OAuth liefert kein Zugriffstoken.") }
        try store(Credential(clientID:clientID, redirectURI:redirect, accessToken:access, refreshToken:result["refresh_token"] as? String, expiresAt:Date().addingTimeInterval(result["expires_in"] as? Double ?? 3600), tokenEndpoint:token.absoluteString, resource:discovery.resource))
        initialized = false; sessionID = nil
    }
    private func tokenRequest(_ url: URL, fields: [String:String]) async throws -> [String:Any] {
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        var body = URLComponents(); body.queryItems = fields.map { URLQueryItem(name:$0.key,value:$0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of:"+",with:"%2B").utf8)
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let value = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw Failure.loginRequired }; return value
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw Failure.invalid("Sicherer Zufallswert konnte nicht erzeugt werden.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    private static func readKeychain(_ account: String) -> Data? {
        var item: CFTypeRef?
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.julianfink.MacTools.PrivateMCP", kSecAttrAccount as String:account, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess ? item as? Data : nil
    }
    private static func writeKeychain(_ data: Data, account: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.julianfink.MacTools.PrivateMCP", kSecAttrAccount as String:account]
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else { throw Failure.invalid("Zugang konnte nicht im Schlüsselbund gespeichert werden.") }
        } else if status != errSecSuccess { throw Failure.invalid("Schlüsselbund konnte nicht aktualisiert werden.") }
    }
}

@MainActor final class OAuthLoopbackReceiver {
    private let state: String
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16,Error>?
    private var answer: CheckedContinuation<[String:String],Error>?
    private var result: Result<[String:String],Error>?
    private var timeout: Task<Void,Never>?
    init(state: String) { self.state = state }
    func start(port: UInt16?) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let listener = try NWListener(using:parameters); self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self,weak listener] status in Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready: if let port = listener?.port?.rawValue { self.ready?.resume(returning:port); self.ready = nil }
                case .failed(let error): self.ready?.resume(throwing:error); self.ready = nil; self.finish(.failure(error))
                default: break
                }
            } }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.receive(connection) } }
            listener.start(queue:.main)
        }
    }
    func wait() async throws -> [String:String] {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            answer = continuation
            timeout = Task { [weak self] in do { try await Task.sleep(nanoseconds:300_000_000_000) } catch { return }; self?.finish(.failure(NativeMCPClient.Failure.invalid("Anmeldung abgelaufen. Bitte erneut anmelden."))) }
        }
    }
    private func receive(_ connection: NWConnection) {
        connection.start(queue:.main)
        read(connection, buffer: Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16384 - buffer.count) { [weak self] data,_,complete,error in Task { @MainActor in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let accumulated = buffer + data
            guard accumulated.count < 16384 else { connection.cancel(); return }
            let source = String(decoding:accumulated,as:UTF8.self)
            guard source.contains("\r\n") else { if complete { connection.cancel() } else { self.read(connection,buffer:accumulated) }; return }
            let line = source.components(separatedBy:"\r\n")[0]
            let parts = line.split(separator:" ")
            guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string:"http://127.0.0.1" + parts[1]), url.path == "/callback" else { connection.cancel(); return }
            let fields = Dictionary((url.queryItems ?? []).compactMap { item in item.value.map { (item.name,$0) } },uniquingKeysWith:{ _,last in last })
            guard fields["state"] == self.state else { connection.cancel(); return }
            let text = "Anmeldung empfangen. Du kannst zu MacTools zurückkehren."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(text.utf8.count)\r\n\r\n" + text
            connection.send(content:Data(response.utf8),completion:.contentProcessed { _ in connection.cancel() })
            self.finish(.success(fields))
        } }
    }
    private func finish(_ value: Result<[String:String],Error>) { guard result == nil else { return }; result = value; timeout?.cancel(); timeout = nil; answer?.resume(with:value); answer = nil; listener?.cancel(); listener = nil }
    func cancel() { ready?.resume(throwing:CancellationError()); ready = nil; finish(.failure(CancellationError())) }
}

/// Credentials and OAuth codes stay on the discovered HTTPS origin during redirects.
private final class NativeMCPRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == response.url?.host ? request : nil)
    }
}

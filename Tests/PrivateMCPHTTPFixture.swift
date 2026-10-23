import Foundation
import CryptoKit

/// In-memory HTTP MCP/OAuth fixture. It never forwards a request to the network.
final class PrivateMCPHTTPFixture: URLProtocol {
    static var failed = false, nearLimit = false, missingCapacity = false, healthyStrategies = false
    static var calls: [String] = [], challenge = ""
    static var registrations = 0, refreshes = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        do {
            var status = 200, headers = ["Content-Type":"application/json"]
            let url = request.url!, path = url.path
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating:0,count:4096); while stream.hasBytesAvailable { let count = stream.read(&bytes,maxLength:bytes.count); if count <= 0 { break }; body.append(bytes,count:count) } }
            let json = (try? JSONSerialization.jsonObject(with:body)) as? [String:Any] ?? [:]
            var result: [String:Any] = [:]
            if path == "/mcp" {
                if request.value(forHTTPHeaderField:"Authorization") == nil { status = 401; headers["WWW-Authenticate"] = "Bearer resource_metadata=\"https://fixture.invalid/resource\"" }
                else {
                    let method = json["method"] as? String ?? "", params = json["params"] as? [String:Any] ?? [:]
                    var value: [String:Any] = [:]
                    if method == "initialize" { value = ["protocolVersion":"2025-03-26","capabilities":["tools":[:]],"serverInfo":["name":"fixture","version":"1"]]; headers["Mcp-Session-Id"] = "native-fixture" }
                    else if method == "notifications/initialized" { status = 202 }
                    else if method == "tools/call", let tool = params["name"] as? String {
                        Self.calls.append(tool)
                        let args = params["arguments"] as? [String:Any] ?? [:]
                        var data: Any
                        switch tool {
                        case "get_system_health": data = ["kubernetes":["pods":["checked":true,"total":20,"ready":20,"pending":0,"failed":0,"unknown":0]],"machine":["cpu":["percent":7.8],"memory":["percent":55.2],"storage":["percent":61.3],"hostname":"fixture-node"]]
                        case "get_namespace_metrics": data = [["namespace":"alpha-one","pods":3,"persistentVolumeClaims":2,"cpuMillicores":64.0,"cpuLimitMillicores":1700,"cpuUnlimitedContainers":0,"memoryBytes":600_000_000,"memoryLimitBytes":3_000_000_000,"memoryUnlimitedContainers":0,"storageUsedBytes":9_000_000_000,"storageBytes":22_000_000_000,"storageUsedAvailable":true,"metricsAvailable":true],["namespace":"without-metrics","metricsAvailable":false,"persistentVolumeClaims":0]]
                        case "get_platform_health": data = ["version":"test","clusterMode":"in-cluster"]
                        case "get_operational_health": data = ["liveness":"UP","trafficReady":true,"runtimeReady":true]
                        case "get_leadership_status": data = ["state":"ACTIVE"]
                        case "get_database_storage": data = ["usedBytes":Self.nearLimit ? 18_000_000_000 : 9_179_633_331]; if !Self.missingCapacity { var storage = data as! [String:Any]; storage["capacityBytes"] = 19_327_352_832; data = storage }
                        case "list_workspaces": data = ["workspaces":[["workspaceId":"fixture-workspace","displayName":"Prüf-Workspace"]]]
                        case "list_portfolio_deployments": precondition(args["workspaceId"] as? String == "fixture-workspace"); data = ["portfolioDeployments":[["executionMode":"PAPER","allocations":[["strategyDeploymentId":"paper"]]]]]
                        case "list_shadow_runtimes":
                            let heartbeat: [String:Any] = ["state":"PENDING_DATA","observedAt":"2026-10-24T00:05:14Z","lastHeartbeatAt":"2026-10-24T00:05:12Z","expiresAfterSeconds":20]
                            data = ["runtimes":[
                                ["strategyDeploymentId":"good","observedState":"DEGRADED","desiredState":"RUNNING","activityState":"PENDING_DATA","heartbeat":heartbeat],
                                ["strategyDeploymentId":"starting","observedState":"STARTING","desiredState":"RUNNING","activityState":"PENDING_DATA","heartbeat":heartbeat],
                                ["strategyDeploymentId":"bad","observedState":Self.healthyStrategies ? "RUNNING" : "STARTING","desiredState":"RUNNING","activityState":Self.healthyStrategies ? "PROCESSING" : "HEARTBEAT_MISSING"],
                                ["strategyDeploymentId":"bad-two","observedState":Self.healthyStrategies ? "RUNNING" : "STARTING","desiredState":"RUNNING","activityState":Self.healthyStrategies ? "PROCESSING" : "HEARTBEAT_MISSING"]]]
                        case "resolve_strategy_presentations": data = ["presentations":[["contentHash":"hash-1","displayName":"Session Paper / Shadow"],["contentHash":"hash-2","displayName":"News Acceptance"],["contentHash":"hash-3","displayName":"Paper Roundtrip"]],"deploymentBindings":[["strategyDeploymentId":"good","contentHash":"hash-1"],["strategyDeploymentId":"starting","contentHash":"hash-1"],["strategyDeploymentId":"bad","contentHash":"hash-2"],["strategyDeploymentId":"bad-two","contentHash":"hash-3"],["strategyDeploymentId":"paper","contentHash":"hash-3"]]]
                        case "list_paper_runtimes": precondition(args["strategyDeploymentId"] as? String == "paper"); data = ["runtimes":[["strategyDeploymentId":"paper","observedState":"PAUSED","desiredState":"PAUSED"]]]
                        default: throw NativeMCPClient.Failure.invalid("Unexpected fixture tool: " + tool)
                        }
                        value = ["content":[],"isError":Self.failed,"structuredContent":["data":data]]
                    } else if method != "notifications/initialized" { throw NativeMCPClient.Failure.invalid("Unexpected fixture method") }
                    result = ["jsonrpc":"2.0","id":json["id"] ?? 0,"result":value]
                }
            } else if path == "/resource" { result = ["resource":"https://fixture.invalid/mcp","authorization_servers":["https://fixture.invalid/auth"]] }
            else if path.contains("oauth-authorization-server") { result = ["issuer":"https://fixture.invalid/auth","authorization_endpoint":"https://fixture.invalid/auth/authorize","token_endpoint":"https://fixture.invalid/auth/token","registration_endpoint":"https://fixture.invalid/auth/register","scopes_supported":["health"],"code_challenge_methods_supported":["S256"]] }
            else if path == "/auth/register" {
                precondition(Set(json.keys) == ["client_name","redirect_uris","token_endpoint_auth_method","grant_types","response_types"], "Strict DCR rejects scope/application_type")
                Self.registrations += 1; result = ["client_id":"native-client"]
            } else if path == "/auth/token" {
                let fields = Dictionary((URLComponents(string:"https://fixture.invalid/?" + String(decoding:body,as:UTF8.self))?.queryItems ?? []).compactMap { item in item.value.map { (item.name,$0) } },uniquingKeysWith:{ _,last in last })
                precondition(fields["client_id"] == "native-client" && fields["resource"] == "https://fixture.invalid/mcp")
                if fields["grant_type"] == "authorization_code" {
                    precondition(fields["code"] == "fixture-code")
                    let hash = Data(SHA256.hash(data:Data(fields["code_verifier"]!.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
                    precondition(hash == Self.challenge, "PKCE must match the authorization URL")
                } else { Self.refreshes += 1; precondition(fields["refresh_token"] == "fixture-refresh") }
                result = ["access_token":"fixture-token","refresh_token":"fixture-refresh","expires_in":3600]
            } else { throw NativeMCPClient.Failure.invalid("Unexpected fixture path: " + path) }
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:result)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    @MainActor static func makeClient() -> NativeMCPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PrivateMCPHTTPFixture.self]
        let secret = FixtureSecret()
        secret.data = try! JSONEncoder().encode(NativeMCPClient.Credential(clientID:"native-client",redirectURI:"http://127.0.0.1:1/callback",accessToken:"fixture-token",refreshToken:"fixture-refresh",expiresAt:Date().addingTimeInterval(3600),tokenEndpoint:"https://fixture.invalid/auth/token",resource:"https://fixture.invalid/mcp"))
        return NativeMCPClient(endpoint:URL(string:"https://fixture.invalid/mcp")!,session:URLSession(configuration:config),loadSecret:{ secret.data },saveSecret:{ secret.data = $0 })
    }
}
@MainActor final class FixtureSecret { var data: Data? }

import Foundation
import CryptoKit
enum ToolNavigation { enum Section { case infrapilot, alphaTrader } }
@main struct PrivateMCPChecks {
 @MainActor static func main() async throws {
  precondition(!PrivateMCPAccess.enabled)
  let domain = "MacTools.NativeMCPChecks." + UUID().uuidString, prefs = UserDefaults(suiteName:domain)!
  defer { prefs.removePersistentDomain(forName:domain) }
  for raw in ["http://example.test/mcp","https://user:secret@example.test/mcp","https://example.test/mcp?token=secret"] { do { _ = try PrivateMCPService.validatedEndpoint(raw); fatalError("Unsafe URL accepted") } catch { } }
  let blocked = PrivateMCPService(kind:.infrapilot,defaults:prefs,permitted:false)
  blocked.start(); await blocked.refresh(); await blocked.signIn(); precondition(!blocked.enabled && PrivateMCPHTTPFixture.calls.isEmpty)
  for kind in PrivateMCPKind.allCases {
   prefs.set("https://fixture.invalid/mcp",forKey:"privateMCP.\(kind.rawValue).endpoint")
   PrivateMCPHTTPFixture.failed = false; PrivateMCPHTTPFixture.healthyStrategies = false
   let service = PrivateMCPService(kind:kind,defaults:prefs,client:PrivateMCPHTTPFixture.makeClient(),permitted:true)
   await service.refresh(); precondition(service.error == nil && service.health?.metrics.count == (kind == .infrapilot ? 4 : 7),service.error ?? service.detailWarning ?? "Missing metrics")
   let consumer = UUID()
   precondition(!PrivateMCPHTTPFixture.calls.contains("get_namespace_metrics") && !PrivateMCPHTTPFixture.calls.contains("get_platform_health") && !PrivateMCPHTTPFixture.calls.contains("resolve_strategy_presentations") && !PrivateMCPHTTPFixture.calls.contains("get_leadership_status"))
   service.setDetailsVisible(true,consumer:consumer); await service.refreshDetails()
   if kind == .infrapilot {
    let namespace = service.health!.namespaces.first!
    precondition(namespace.id == "alpha-one" && namespace.cpu == 0.064 && namespace.cpuLimit == 1.7 && namespace.network == nil)
    precondition(service.health!.namespaces.last!.memory == nil && service.health!.namespaces.last!.storage == nil)
    precondition(service.namespaceHistory.count == 1 && service.namespaceWarning == nil)
    await service.refresh(); precondition(service.namespaceHistory.count == 1)
    print("PASS: namespace CPU conversion, memory/PVC limits, absent metrics stay missing, network unavailable, minute sample deduplication")
   }
   if kind == .alphatrader {
    precondition(service.health?.strategies?.facts.first?.title.contains("Prüf-Workspace") == true && service.health?.strategies?.facts.contains(where: { $0.title.contains("News Acceptance") }) == true)
    precondition(Set(service.health!.strategies!.facts.map(\.id)).count == 5)
    precondition(service.health?.strategies?.running == 0 && service.health?.strategies?.waiting == 2 && service.health?.strategies?.paused == 1 && service.health?.strategies?.unhealthy == 2 && service.critical)
    PrivateMCPHTTPFixture.healthyStrategies = true; await service.refresh(); precondition(!service.critical)
    PrivateMCPHTTPFixture.nearLimit = true; await service.refresh(); precondition(service.critical && service.health?.healthy == false)
    PrivateMCPHTTPFixture.nearLimit = false; PrivateMCPHTTPFixture.missingCapacity = true; await service.refresh(); precondition(service.critical)
    PrivateMCPHTTPFixture.missingCapacity = false; await service.refresh(); precondition(!service.critical)
   }
   let detailCalls = PrivateMCPHTTPFixture.calls.filter { ["get_namespace_metrics","get_platform_health","resolve_strategy_presentations","get_leadership_status"].contains($0) }.count
   await service.refreshDetails()
   service.setDetailsVisible(false,consumer:consumer); await service.refresh()
   precondition(detailCalls == PrivateMCPHTTPFixture.calls.filter { ["get_namespace_metrics","get_platform_health","resolve_strategy_presentations","get_leadership_status"].contains($0) }.count)
   print("PASS: hidden details make no detail requests; opening reuses menu data; namespace minute throttle and 15-minute metadata cache prevent duplicate requests")
   let confirmed = service.health
   PrivateMCPHTTPFixture.failed = true; await service.refresh(); precondition(service.health == confirmed && service.error != nil && service.critical)
   service.stop(); PrivateMCPHTTPFixture.calls = []
  }
  func runtime(_ observed: String, _ activity: String = "", desired: String = "RUNNING", age: Double? = nil) -> [String:Any] {
   var row: [String:Any] = ["strategyDeploymentId":"one", "observedState":observed, "desiredState":desired, "activityState":activity]
   if let age {
    let now = Date(timeIntervalSince1970:1_700_000_000), formatter = ISO8601DateFormatter()
    row["heartbeat"] = ["observedAt":formatter.string(from:now),"lastHeartbeatAt":formatter.string(from:now.addingTimeInterval(-age)),"expiresAfterSeconds":20.0]
   }
   return row
  }
  func summary(_ records: [[String:Any]]) throws -> AlphaTraderStrategySummary {
   let result = try AlphaTraderStrategySummary.parse(records.map { (workspace:"fixture",mode:"PAPER",runtime:$0) })
   precondition(result.running + result.waiting + result.starting + result.paused + result.unhealthy + result.unknown == result.total, "Categories must be exclusive")
   return result
  }
  for activity in ["PENDING_DATA", "WAITING_FOR_CANDIDATES", "WAITING_FOR_EVALUATION"] {
   for observed in ["STARTING", "DEGRADED", "RUNNING"] {
    let result = try summary([runtime(observed,activity,age:3)])
    precondition(result.waiting == 1 && result.unhealthy == 0, "Fresh heartbeat while waiting is not a runtime failure")
   }
  }
  precondition((try! summary([runtime("STARTING")])).starting == 1)
  precondition((try! summary([runtime("STARTING","CONNECTING",age:3)])).unhealthy == 0)
  precondition((try! summary([runtime("RUNNING","PENDING_DATA",age:21)])).unhealthy == 1)
  precondition((try! summary([runtime("STARTING","HEARTBEAT_MISSING")])).unhealthy == 1)
  precondition((try! summary([runtime("RUNNING","HEARTBEAT_STALE")])).unhealthy == 1)
  precondition((try! summary([runtime("FAILED","PENDING_DATA",age:3)])).unhealthy == 1)
  precondition((try! summary([runtime("PAUSED","HEARTBEAT_MISSING",desired:"PAUSED")])).paused == 1)
  precondition((try! summary([runtime("FAILED",desired:"STOPPED"), runtime("RUNNING","PROCESSING",age:3)])).unhealthy == 0)
  precondition((try! summary([runtime("RUNNING","PENDING_DATA")])).unknown == 1)
  print("PASS: mutually exclusive deployment counts; fresh STARTING/DEGRADED waiting, expired/missing heartbeat, paused runtime and stopped historical replacement")
  print("PASS: direct HTTP MCP initialize/notification/tool calls; no CLI; typed health/strategy metrics; DB 85% and missing-capacity alarms; failed calls preserve last confirmed snapshot")
  let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PrivateMCPHTTPFixture.self]
  let secret = FixtureSecret()
  let client = NativeMCPClient(endpoint:URL(string:"https://fixture.invalid/mcp")!,session:URLSession(configuration:configuration),loadSecret:{ secret.data },saveSecret:{ secret.data = $0 })
  try await client.signIn { url in
   let fields = Dictionary((URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).compactMap { item in item.value.map { (item.name,$0) } },uniquingKeysWith:{ _,last in last })
   PrivateMCPHTTPFixture.challenge = fields["code_challenge"]!
   precondition(fields["code_challenge_method"] == "S256" && fields["scope"] == "health")
   var callback = URLComponents(string:fields["redirect_uri"]!)!; callback.queryItems = [URLQueryItem(name:"code",value:"fixture-code"),URLQueryItem(name:"state",value:fields["state"]!)]
   Task {
    var invalid = callback; invalid.queryItems = [URLQueryItem(name:"code",value:"fixture-code"),URLQueryItem(name:"state",value:"wrong-state")]
    _ = try? await URLSession.shared.data(from:invalid.url!); precondition(secret.data == nil, "Invalid OAuth state must not store credentials")
    _ = try await URLSession.shared.data(from:callback.url!)
   }
  }
  precondition(secret.data != nil && PrivateMCPHTTPFixture.registrations == 1)
  var saved = try JSONDecoder().decode(NativeMCPClient.Credential.self,from:secret.data!)
  saved.expiresAt = .distantPast; secret.data = try JSONEncoder().encode(saved)
  PrivateMCPHTTPFixture.failed = false
  _ = try await client.call("get_operational_health",arguments:[:]); precondition(PrivateMCPHTTPFixture.refreshes == 1)
  let registrationsBeforeRestart = PrivateMCPHTTPFixture.registrations
  let restarted = NativeMCPClient(endpoint:URL(string:"https://fixture.invalid/mcp")!,session:URLSession(configuration:configuration),loadSecret:{ secret.data },saveSecret:{ secret.data = $0 })
  _ = try await restarted.call("get_operational_health",arguments:[:])
  precondition(PrivateMCPHTTPFixture.registrations == registrationsBeforeRestart, "Restart must reuse stored credentials without registering or opening a browser")
  restarted.cancel()
  print("PASS: a fresh MCP client instance reuses the persisted credential without OAuth registration or browser sign-in")
  let event = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"ok\":true}}\n\n".utf8)
  let decoded = try NativeMCPClient.message(event,expectedID:42); precondition(decoded["result"] != nil)
  client.cancel()
  print("PASS: strict minimal DCR, discovery, real loopback callback with state and S256 PKCE, token exchange/refresh, injected secret vault and SSE JSON decoding; no browser or real provider grant")
 }
}

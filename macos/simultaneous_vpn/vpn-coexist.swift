import Darwin
import Foundation
import SystemConfiguration

let label = "local.vpn-coexist"
let directory = "/var/db/" + label
let proxyDirectory = "/Library/PrivilegedHelperTools/" + label
let resolverKey = "State:/Network/Service/" + label + "-default/DNS"

struct LANMatch: Codable, Equatable {
  var dhcp_server: String?
  var probe: String?
}

struct NetworkSettings: Codable, Equatable {
  var domain: String
  var endpoints: [String]
  var routes: [String]
  var lan: LANMatch?
}

struct Configuration: Codable, Equatable {
  var vpn_dns: [String]
  var networks: [NetworkSettings]
  var firewall: String?

  var endpoints: [String] { Array(Set(networks.flatMap { $0.endpoints })).sorted() }

  static func load(_ path: String) throws -> Configuration {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let config = try JSONDecoder().decode(Self.self, from: data)
    func check(_ valid: Bool, _ message: String) throws {
      if !valid { throw NSError(domain: label, code: 65, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func keys(_ object: [String: Any], _ allowed: Set<String>) throws {
      try check(Set(object.keys).isSubset(of: allowed), "Unknown configuration keys")
    }
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    try keys(object, ["vpn_dns", "networks", "firewall"])
    for network in object["networks"] as? [[String: Any]] ?? [] {
      try keys(network, ["domain", "endpoints", "routes", "lan"])
      if let lan = network["lan"] as? [String: Any] { try keys(lan, ["dhcp_server", "probe"]) }
    }
    try check(["none", "amnezia"].contains(config.firewall ?? "none"), "Unknown firewall adapter")
    try check(!config.vpn_dns.isEmpty && config.vpn_dns.allSatisfy(dnsAddress), "Invalid vpn_dns")
    var domains = Set<String>()
    for network in config.networks {
      try check(dnsDomain(network.domain) == network.domain && domains.insert(network.domain).inserted,
                "Invalid or duplicate domain")
      try check(network.endpoints.allSatisfy(dnsAddress), "Invalid endpoint")
      try check(network.routes.allSatisfy(privateNetwork), "Invalid private IPv4 routes")
      if let lan = network.lan {
        try check((lan.dhcp_server == nil) != (lan.probe == nil), "Choose dhcp_server or probe")
        if let server = lan.dhcp_server {
          try check(dnsAddress(server) && !network.routes.isEmpty, "Invalid DHCP match")
        }
        if let probe = lan.probe {
          try check(dnsDomain(probe) == probe && (probe == network.domain || probe.hasSuffix("." + network.domain)),
                    "Probe must belong to the network domain")
        }
      }
    }
    return config
  }
}

func dnsAddress(_ address: String) -> Bool {
  guard let n = ipv4(address) else { return false }
  return n >> 24 != 0 && n >> 24 != 127 && n >> 28 < 14
}

func privateNetwork(_ network: String) -> Bool {
  guard canonicalNetwork(network) == network, let prefix = Int(network.split(separator: "/").last!), prefix > 0,
    let start = ipv4(String(network.split(separator: "/")[0]))
  else { return false }
  let end = start | (UInt32.max >> prefix)
  let endAddress = "\(end >> 24).\((end >> 16) & 255).\((end >> 8) & 255).\(end & 255)"
  return privateIPv4(String(network.split(separator: "/")[0])) && privateIPv4(endAddress)
}

func tunnelInterface(_ name: String) -> Bool {
  name.range(of: "^(utun|tun|tap|ppp|ipsec)[0-9]+$", options: .regularExpression) != nil
}

func routeInterface(_ output: String) -> String? {
  match("(?m)^\\s*interface:\\s*(\\S+)\\s*$", output)
}

func selectPublicDNS(configured: [String], lan: [String], interfaces: [String: String], fullTunnel: Bool) -> [String] {
  let tunneled = configured.filter { interfaces[$0].map(tunnelInterface) == true }
  if !tunneled.isEmpty { return tunneled }
  // A full tunnel with excluded/unroutable DNS needs a client configuration fix.
  if fullTunnel { return [] }
  return lan.isEmpty ? configured : lan
}

func internetVPNActive(_ table: String) -> Bool {
  table.components(separatedBy: .newlines).contains { line in
    let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count >= 4, tunnelInterface(fields[3]) else { return false }
    let network = fields[0] == "default" ? "0.0.0.0/0" : canonicalNetwork(fields[0])
    return ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1"].contains(network ?? "")
  }
}

struct LAN: Codable, Equatable {
  var interface: String
  var address: String
  var network: String
  var gateway: String?
  var servers: [String]
  var domains: [String]
  var dhcpServer: String?
}

struct DetectedNetwork: Codable {
  var domain: String
  var servers: [String]
  var lan: LAN
  var prefixes: [String]
  var observed: Date? = Date()

  var routes: [Route] {
    let localPrefix = Int(lan.network.split(separator: "/")[1])!
    return prefixes.compactMap { prefix in
      let parts = prefix.split(separator: "/")
      if contains(lan.network, String(parts[0])), Int(parts[1])! >= localPrefix { return nil }
      return Route(network: prefix, gateway: lan.gateway!, interface: lan.interface)
    }
  }

  var details: [String: Any] {
    [
      "domain": domain, "access": "lan", "dns": servers, "interface": lan.interface,
      "address": lan.address, "gateway": lan.gateway!, "routes": prefixes,
    ]
  }
}

func detectNetwork(_ settings: NetworkSettings, lan: LAN, server: String? = nil, answer: String = "")
  -> DetectedNetwork?
{
  guard let rule = settings.lan, let gateway = lan.gateway, contains(lan.network, gateway),
    lan.interface.range(of: "^en[0-9]+$", options: .regularExpression) != nil
  else { return nil }
  if let identifier = rule.dhcp_server {
    guard lan.dhcpServer == identifier, lan.domains.contains(settings.domain),
      settings.routes.contains(where: { contains($0, lan.address) }),
      settings.routes.contains(where: { contains($0, gateway) })
    else { return nil }
    return DetectedNetwork(domain: settings.domain, servers: lan.servers, lan: lan, prefixes: settings.routes)
  }
  guard rule.probe != nil, let server = server, lan.servers.contains(server) else { return nil }
  let addresses = answer.components(separatedBy: .newlines).filter(privateIPv4)
  guard !addresses.isEmpty else { return nil }
  return DetectedNetwork(
    domain: settings.domain, servers: [server], lan: lan,
    prefixes: Array(Set(settings.routes + addresses.map { $0 + "/32" })).sorted())
}

func dnsDomain(_ text: String) -> String? {
  let name = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".\" "))
  guard name.utf8.count <= 253, !name.isEmpty,
    name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
      $0.utf8.count <= 63 && $0.range(of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", options: .regularExpression) != nil
    })
  else { return nil }
  return name
}

func privateIPv4(_ address: String) -> Bool {
  guard let n = ipv4(address) else { return false }
  return n >> 24 == 10 || n >> 20 == 0xac1 || n >> 16 == 0xc0a8 || n >> 22 == 0x191
}

func contains(_ network: String, _ address: String) -> Bool {
  let parts = network.split(separator: "/")
  guard parts.count == 2, let base = ipv4(String(parts[0])), let value = ipv4(address),
    let prefix = Int(parts[1]), (0...32).contains(prefix)
  else { return false }
  let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
  return base & mask == value & mask
}

func detectLAN(interface: String, addresses: [String], packet: String) -> LAN? {
  guard let address = match("(?m)^yiaddr = ([0-9.]+)$", packet), addresses.contains(address),
    let maskText = match("(?m)^subnet_mask \\(ip\\): ([0-9.]+)$", packet), let mask = ipv4(maskText), mask != 0,
    (~mask & ((~mask) &+ 1)) == 0,
    let network = canonicalNetwork("\(address)/\(mask.nonzeroBitCount)"),
    let dns = match("(?m)^domain_name_server \\(ip_mult\\): \\{([^}]+)\\}", packet)
  else { return nil }
  let servers = dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
    dnsAddress($0)
  }
  guard !servers.isEmpty else { return nil }
  var domains: [String] = []
  if let domain = match("(?m)^domain_name \\(string\\): (.+)$", packet).flatMap(dnsDomain) { domains.append(domain) }
  if let search = match("(?m)^domain_search \\([^)]*\\): (.+)$", packet) {
    domains += search.components(separatedBy: CharacterSet(charactersIn: "{}, \"")).compactMap(dnsDomain)
  }
  return LAN(
    interface: interface, address: address, network: network,
    gateway: match("(?m)^router \\(ip_mult\\): \\{([0-9.]+)", packet),
    servers: Array(Set(servers)).sorted(), domains: Array(Set(domains)).sorted(),
    dhcpServer: match(#"(?m)^server_identifier \(ip\): ([0-9.]+)$"#, packet))
}

func lanDNSRoutes(_ lans: [LAN]) -> [Route] {
  var result: [Route] = []
  for lan in lans {
    guard let gateway = lan.gateway, contains(lan.network, gateway) else { continue }
    for server in lan.servers where privateIPv4(server) && !contains(lan.network, server) {
      let route = Route(network: server + "/32", gateway: gateway, interface: lan.interface)
      if !result.contains(where: { $0.network == route.network }) { result.append(route) }
    }
  }
  return result
}

func forwarderRules(lans: [LAN], scoped: [String: [String]], upstreams: [String], networks: [DetectedNetwork] = [])
  -> String
{
  var rules = Set(upstreams.map { "server=\($0)" })
  if lans.isEmpty { rules.insert("server=//") }
  for (index, lan) in lans.enumerated() {
    for server in lan.servers {
      if index == 0 { rules.insert("server=//\(server)") }
      rules.insert("rev-server=\(lan.network),\(server)")
      for domain in Set(lan.domains + ["lan", "home.arpa"]) { rules.insert("server=/\(domain)/\(server)") }
    }
  }
  // A detected institution on the physical LAN takes precedence over its VPN DNS.
  var resolvers = scoped
  for network in networks { resolvers[network.domain] = network.servers }
  for (domain, servers) in resolvers {
    rules = rules.filter { !$0.hasPrefix("server=/\(domain)/") }
    for server in servers { rules.insert("server=/\(domain)/\(server)") }
  }
  for network in networks {
    for prefix in network.prefixes {
      for server in network.servers { rules.insert("rev-server=\(prefix),\(server)") }
    }
  }
  return rules.sorted().joined(separator: "\n") + "\n"
}

struct CommandResult {
  var status: Int32
  var output: String
}

final class CommandOutput { var data = Data() }

func run(_ executable: String, _ arguments: [String]) -> CommandResult {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
  process.standardOutput = output
  process.standardError = output
  do { try process.run() } catch {
    return CommandResult(status: -1, output: error.localizedDescription)
  }
  // Drain concurrently, so a subprocess cannot block on a full pipe.
  let finished = DispatchSemaphore(value: 0)
  let capture = CommandOutput()
  DispatchQueue.global().async {
    capture.data = output.fileHandleForReading.readDataToEndOfFile()
    finished.signal()
  }
  let deadline = Date().addingTimeInterval(4)
  while process.isRunning && Date() < deadline { usleep(20_000) }
  if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  process.waitUntilExit()
  _ = finished.wait(timeout: .now() + 1)
  return CommandResult(status: process.terminationStatus, output: String(decoding: capture.data, as: UTF8.self))
}

func ipv4(_ text: String) -> UInt32? {
  var address = in_addr()
  guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
  return UInt32(bigEndian: address.s_addr)
}

func canonicalNetwork(_ value: String) -> String? {
  let fields = value.split(separator: "/", omittingEmptySubsequences: false)
  guard fields.count <= 2 else { return nil }
  let octets = fields[0].split(separator: ".").map(String.init)
  guard !octets.isEmpty, octets.count <= 4 else { return nil }
  let padded = (octets + Array(repeating: "0", count: 4 - octets.count)).joined(separator: ".")
  guard let address = ipv4(padded), let prefix = fields.count == 2 ? Int(fields[1]) : Optional(octets.count * 8),
    (0...32).contains(prefix)
  else { return nil }
  let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
  let network = address & mask
  return "\(network >> 24).\((network >> 16) & 255).\((network >> 8) & 255).\(network & 255)/\(prefix)"
}

func match(_ expression: String, _ text: String) -> String? {
  guard let regex = try? NSRegularExpression(pattern: expression),
    let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
    let range = Range(result.range(at: 1), in: text)
  else { return nil }
  return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
}

struct Route: Codable, Equatable {
  var network: String
  var gateway: String
  var interface: String
}

func parseRoutes(_ text: String) -> [Route] {
  text.components(separatedBy: .newlines).compactMap { line in
    let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count >= 4, let network = canonicalNetwork(fields[0]), ipv4(fields[1]) != nil else { return nil }
    return Route(network: network, gateway: fields[1], interface: fields[3])
  }
}

func directHostRoutes(_ hosts: [String], lans: [LAN]) -> [Route] {
  guard let lan = lans.first(where: { lan in lan.gateway.map { contains(lan.network, $0) } == true }) else { return [] }
  return Array(Set(hosts)).sorted().map { Route(network: $0 + "/32", gateway: lan.gateway!, interface: lan.interface) }
}

func staleDirectRoutes(_ current: [Route], desired: [Route], lans: [LAN]) -> [Route] {
  current.filter { route in
    desired.contains(where: { $0.network == route.network }) && route.interface.hasPrefix("en")
      && !lans.contains(where: { $0.interface == route.interface && contains($0.network, route.gateway) })
  }
}

struct RoutePlan {
  var remove: [Route]
  var add: [Route]
  var conflicts: [String]
}

func planRoutes(owned: [Route], current: [Route], desired: [Route] = [], stale: [Route] = []) -> RoutePlan {
  let remove = owned.filter { current.contains($0) && !desired.contains($0) } + stale.filter { !owned.contains($0) }
  let remaining = current.filter { !remove.contains($0) }
  var add: [Route] = []
  var conflicts: [String] = []
  for route in desired {
    let existing = remaining.filter { $0.network == route.network }
    if existing.isEmpty { add.append(route) } else if existing.contains(where: { $0 != route }) { conflicts.append(route.network) }
  }
  return RoutePlan(remove: remove, add: add, conflicts: conflicts)
}

struct State: Codable {
  var routes: [Route] = []
  var allowedNetworks: [String] = []
  var dnsExceptions: [String] = []
  var addresses: [String: String]?
  var networks: [DetectedNetwork]?
  var configuration: Configuration?
}

final class Controller {
  lazy var store = SCDynamicStoreCreate(nil, label as CFString, nil, nil)!
  let config: Configuration
  var state: State
  var lans: [LAN] = []
  var networks: [DetectedNetwork] = []
  var errors: [String] = []
  var command: (String, [String]) -> CommandResult = run

  init(config: Configuration) {
    self.config = config
    state = (try? JSONDecoder().decode(State.self,
      from: Data(contentsOf: URL(fileURLWithPath: directory + "/state.json")))) ?? State()
    state.addresses = state.addresses ?? [:]
    if state.configuration != config { state.networks = nil }
    state.configuration = config
  }

  func read(_ key: String) -> [String: Any] {
    SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
  }

  func services(_ type: String) -> [(String, [String: Any])] {
    let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/\(type)" as CFString) as? [String] ?? []
    return keys.sorted().map { ($0, read($0)) }
  }

  func localLANs() -> [LAN] {
    let primary = read("State:/Network/Global/IPv4")["PrimaryService"] as? String ?? ""
    var result: [LAN] = []
    for (key, value) in services("IPv4").sorted(by: {
      ($0.0.contains("/\(primary)/") ? 0 : 1, $0.0) < ($1.0.contains("/\(primary)/") ? 0 : 1, $1.0)
    }) {
      guard let interface = value["InterfaceName"] as? String, interface.hasPrefix("en"),
        !result.contains(where: { $0.interface == interface }),
        read("State:/Network/Interface/\(interface)/Link")["Active"] as? Bool == true,
        let addresses = value["Addresses"] as? [String]
      else { continue }
      let packet = command("/usr/sbin/ipconfig", ["getpacket", interface])
      if let lan = detectLAN(interface: interface, addresses: addresses, packet: packet.output) {
        result.append(lan)
      } else {
        // Static IPv4: use the service's current address, mask and DNS.
        let dns = read(String(key.dropLast(4)) + "DNS")
        guard let address = addresses.first, let masks = value["SubnetMasks"] as? [String],
          let mask = masks.first.flatMap(ipv4), mask != 0, (~mask & ((~mask) &+ 1)) == 0,
          let subnet = canonicalNetwork("\(address)/\(mask.nonzeroBitCount)"),
          let servers = dns["ServerAddresses"] as? [String], !servers.filter(dnsAddress).isEmpty
        else { continue }
        let domains = (dns["SearchDomains"] as? [String] ?? []) + [dns["DomainName"] as? String ?? ""]
        result.append(LAN(interface: interface, address: address, network: subnet,
          gateway: value["Router"] as? String, servers: servers.filter(dnsAddress),
          domains: domains.compactMap(dnsDomain), dhcpServer: nil))
      }
    }
    return result
  }

  func localNetworks(domain: String? = nil) -> [DetectedNetwork] {
    var result: [DetectedNetwork] = []
    nextNetwork: for network in config.networks where domain == nil || network.domain == domain {
      for lan in lans {
        if let found = detectNetwork(network, lan: lan) { result.append(found); continue nextNetwork }
        guard let probe = network.lan?.probe else { continue }
        for server in lan.servers {
          let query = command("/usr/bin/dig", ["+time=1", "+tries=1", "+short", "@" + server, probe, "A"])
          if let found = detectNetwork(network, lan: lan, server: server, answer: query.output), query.status == 0 {
            result.append(found)
            continue nextNetwork
          }
          if query.status != 0, let cached = state.networks?.first(where: {
            $0.domain == network.domain && $0.lan == lan && $0.servers == [server]
          }), let observed = cached.observed, (0...60).contains(Date().timeIntervalSince(observed)) {
            result.append(cached)
            continue nextNetwork
          }
        }
      }
    }
    return result
  }

  func dns() -> (scoped: [String: [String]], searches: [String]) {
    var scoped: [String: [String]] = [:]
    var searches = lans.flatMap { $0.domains }
    for (key, value) in services("DNS") where key != resolverKey {
      searches += (value["SearchDomains"] as? [String] ?? []).compactMap(dnsDomain)
      let servers = (value["ServerAddresses"] as? [String] ?? []).filter(dnsAddress)
      for domain in (value["SupplementalMatchDomains"] as? [String] ?? []).compactMap(dnsDomain)
        where !servers.isEmpty
      {
        scoped[domain] = Array(Set((scoped[domain] ?? []) + servers)).sorted()
      }
    }
    var seen = Set<String>()
    return (scoped, searches.filter { seen.insert($0).inserted })
  }

  func routeCommand(_ action: String, _ route: Route) -> Bool {
    let address = lans.first(where: { $0.interface == route.interface })?.address
    var arguments = ["-n", action, "-net", route.network, route.gateway]
    if action != "delete", let address = address { arguments += ["-ifp", route.interface, "-ifa", address] }
    let result = command("/sbin/route", arguments)
    if result.status == 0 { state.addresses?[route.network] = action == "delete" ? nil : address }
    else { errors.append("Route \(action) \(route.network): \(result.output)") }
    return result.status == 0
  }

  func configureRoutes(current: [Route], desired: [Route], endpoints: [Route]) {
    let plan = planRoutes(owned: state.routes, current: current, desired: desired,
      stale: staleDirectRoutes(current, desired: endpoints, lans: lans))
    state.routes = state.routes.filter { current.contains($0) }
    for route in plan.remove where routeCommand("delete", route) { state.routes.removeAll { $0 == route } }
    for route in plan.add where routeCommand("add", route) { state.routes.append(route) }
    for route in state.routes {
      if let lan = lans.first(where: { $0.interface == route.interface }), state.addresses?[route.network] != lan.address {
        _ = routeCommand("change", route)
      }
    }
    if !plan.conflicts.isEmpty { errors.append("Foreign route conflicts: " + plan.conflicts.joined(separator: ", ")) }
  }

  func resolver(_ value: NSDictionary?) {
    if let value = value {
      let current = SCDynamicStoreCopyValue(store, resolverKey as CFString) as? NSDictionary
      if current == value {
        if read("State:/Network/Global/DNS")["ServerAddresses"] as? [String] == ["127.0.0.1"] { return }
        // Republish if a VPN replaced global DNS without changing our service.
        let refresh = value.mutableCopy() as! NSMutableDictionary
        refresh["SupplementalMatchOrders"] = (value["SupplementalMatchDomains"] as? [String] ?? []).map { _ in 2 }
        _ = SCDynamicStoreSetValue(store, resolverKey as CFString, refresh)
      }
      if !SCDynamicStoreSetValue(store, resolverKey as CFString, value) { errors.append("Cannot publish DNS") }
    } else if SCDynamicStoreCopyValue(store, resolverKey as CFString) != nil {
      if !SCDynamicStoreRemoveValue(store, resolverKey as CFString) { errors.append("Cannot remove DNS") }
    }
  }

  func configureDNS(scoped: [String: [String]], searches: [String], upstreams: [String]) {
    do {
      let path = directory + "/dns-servers.conf"
      let rules = forwarderRules(lans: lans, scoped: scoped, upstreams: upstreams, networks: networks)
      if (try? String(contentsOfFile: path, encoding: .utf8)) != rules {
        try Data(rules.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o644)
        if command("/bin/launchctl", ["kill", "SIGHUP", "system/" + label + ".dns"]).status != 0 {
          errors.append("Cannot reload dnsmasq")
        }
      }
      let health = command("/usr/bin/dig", ["+time=1", "+tries=1", "+short", "@127.0.0.1", "chaos", "txt", "version.bind"])
      guard health.status == 0, health.output.contains("dnsmasq-") else {
        errors.append("dnsmasq unavailable; native DNS retained")
        resolver(nil)
        return
      }
      let domains = [""] + Array(Set(Array(scoped.keys) + networks.map { $0.domain })).sorted()
      resolver(["ServerAddresses": ["127.0.0.1"], "SearchDomains": searches,
        "SupplementalMatchDomains": domains, "SupplementalMatchOrders": domains.map { _ in 1 }])
    } catch { errors.append("Cannot update DNS: \(error)") }
  }

  func firewallTable(_ anchor: String, _ name: String, wanted: [String], owned: inout [String]) {
    let table = command("/sbin/pfctl", ["-q", "-a", anchor, "-t", name, "-T", "show"])
    guard table.status == 0 else { owned = []; return }
    let existing = Set(table.output.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    owned = owned.filter { existing.contains($0) }
    for (action, addresses) in [("delete", owned.filter { !wanted.contains($0) }),
                              ("add", wanted.filter { !existing.contains($0) })] where !addresses.isEmpty {
      if command("/sbin/pfctl", ["-q", "-a", anchor, "-t", name, "-T", action] + addresses).status == 0 {
        if action == "add" { owned += addresses } else { owned.removeAll { addresses.contains($0) } }
      } else { errors.append("Cannot update firewall table \(name)") }
    }
  }

  func save(scoped: [String: [String]], upstreams: [String]) {
    do {
      state.networks = networks
      let path = directory + "/state.json"
      try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: path), options: .atomic)
      chmod(path, 0o600)
      let status: [String: Any] = [
        "updated": ISO8601DateFormatter().string(from: Date()), "errors": errors,
        "owned_routes": state.routes.map { "\($0.network) via \($0.gateway) on \($0.interface)" },
        "lan_dns": lans.flatMap { $0.servers }, "public_dns_upstreams": upstreams,
        "networks": config.networks.map { network -> [String: Any] in
          if let local = networks.first(where: { $0.domain == network.domain }) { return local.details }
          let servers = scoped[network.domain] ?? []
          return ["domain": network.domain, "access": servers.isEmpty ? "disconnected" : "vpn", "dns": servers]
        },
      ]
      let statusPath = directory + "/status.json"
      try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: statusPath), options: .atomic)
      chmod(statusPath, 0o644)
    } catch { errors.append("Cannot save state: \(error)") }
    for error in errors { fputs(error + "\n", stderr) }
  }

  func reconcile(cleanup: Bool = false) {
    if !cleanup { lans = localLANs(); networks = localNetworks() }
    let dns = dns()
    let table = command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
    guard table.status == 0 else { errors.append("Cannot read routes"); save(scoped: dns.scoped, upstreams: []); return }
    let endpoints = directHostRoutes(config.endpoints, lans: lans)
    var desired = endpoints + lanDNSRoutes(lans)
    for route in networks.flatMap({ $0.routes }) where !desired.contains(where: { $0.network == route.network }) {
      desired.append(route)
    }
    configureRoutes(current: parseRoutes(table.output), desired: desired, endpoints: endpoints)
    var interfaces: [String: String] = [:]
    for server in config.vpn_dns where !cleanup {
      interfaces[server] = routeInterface(command("/sbin/route", ["-n", "get", server]).output)
    }
    let upstreams = selectPublicDNS(configured: config.vpn_dns, lan: lans.first?.servers ?? [],
      interfaces: interfaces, fullTunnel: internetVPNActive(table.output))
    if cleanup { resolver(nil) } else {
      if upstreams.isEmpty { errors.append("No VPN DNS route; check vpn_dns and client exclusions") }
      configureDNS(scoped: dns.scoped, searches: dns.searches, upstreams: upstreams)
    }
    if config.firewall == "amnezia" || !state.dnsExceptions.isEmpty || !state.allowedNetworks.isEmpty {
      let enabled = !cleanup && config.firewall == "amnezia"
      let servers = Array(Set(["127.0.0.1"] + lans.flatMap { $0.servers } + dns.scoped.values.flatMap { $0 } + upstreams))
      let prefixes = endpoints.map { $0.network } + networks.flatMap { $0.prefixes }
      let addresses = ["127.0.0.1"] + prefixes.map { $0.hasSuffix("/32") ? String($0.dropLast(3)) : $0 }
      firewallTable("amn/310.blockDNS", "dnsaddr", wanted: enabled ? servers : [], owned: &state.dnsExceptions)
      firewallTable("amn/110.allowNets", "allownets", wanted: enabled ? Array(Set(addresses)) : [], owned: &state.allowedNetworks)
    }
    save(scoped: dns.scoped, upstreams: cleanup ? [] : upstreams)
  }
}

// Command line
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "--status"
func fail(_ message: String, _ code: Int32) -> Never { fputs(message + "\n", stderr); exit(code) }
if mode == "--check-config", arguments.count == 2 {
  do { _ = try Configuration.load(arguments[1]); print("Configuration valid"); exit(0) }
  catch { fail("Invalid configuration: \(error.localizedDescription)", 65) }
}
guard ["--status", "--inspect", "--once", "--cleanup"].contains(mode),
  arguments.count <= (mode == "--inspect" ? 2 : 1)
else { fail("Usage: vpn-coexist [--status|--inspect [DOMAIN]|--once|--cleanup|--check-config FILE]", 64) }
if mode == "--status" {
  guard let status = try? String(contentsOfFile: directory + "/status.json", encoding: .utf8)
  else { fail("No status yet", 1) }
  print(status)
  exit(0)
}
if mode != "--inspect", geteuid() != 0 { fail("Administrator privileges required", 77) }
let config: Configuration
do { config = try Configuration.load(proxyDirectory + "/config.json") }
catch { fail("Cannot load configuration: \(error.localizedDescription)", 65) }
if mode == "--inspect" {
  let domain = arguments.count == 2 ? dnsDomain(arguments[1]) : nil
  if arguments.count == 2 && domain == nil { fail("Invalid domain", 64) }
  let inspector = Controller(config: config)
  inspector.lans = inspector.localLANs()
  let networks = inspector.localNetworks(domain: domain)
  if domain != nil && networks.isEmpty { exit(1) }
  let value: Any = domain == nil ? networks.map { $0.details } : networks[0].details
  do { print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)) }
  catch { fail("Cannot serialize inspection", 1) }
  exit(0)
}
guard geteuid() == 0 else { fail("Administrator privileges required", 77) }
umask(0o077)
if mkdir(directory, 0o755) == 0 { chmod(directory, 0o755) }
var attributes = stat()
guard lstat(directory, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFDIR,
  attributes.st_uid == 0, (attributes.st_mode & 0o777) == 0o755
else { fail("Untrusted state directory", 77) }
let lock = open(directory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { fail("Another update is running", 75) }
// Finish this short transaction before launchd removal or terminal interruption.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let controller = Controller(config: config)
controller.reconcile(cleanup: mode == "--cleanup")
exit(controller.errors.isEmpty && (mode != "--cleanup" || controller.state.routes.isEmpty) ? 0 : 1)

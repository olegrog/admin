func selfTest() {
  let sk = NetworkSettings(
    domain: "skoltech.ru", endpoints: ["83.69.192.101"],
    routes: ["10.16.0.0/16", "10.17.0.0/16"], lan: LANMatch(dhcp_server: "10.16.32.100", probe: nil))
  let fic = NetworkSettings(
    domain: "frccsc.ru", endpoints: ["83.149.227.23"],
    routes: ["192.168.70.0/24"], lan: LANMatch(dhcp_server: nil, probe: "login.hpc.frccsc.ru"))
  let homePacket =
    "yiaddr = 192.168.1.20\nsubnet_mask (ip): 255.255.255.0\ndomain_name_server (ip_mult): {192.168.1.1}\nrouter (ip_mult): {192.168.1.1}"
  let officePacket =
    "yiaddr = 10.42.7.20\nsubnet_mask (ip): 255.255.255.0\ndomain_name_server (ip_mult): {10.42.0.53}\nrouter (ip_mult): {10.42.7.1}\ndomain_name (string): office.example\ndomain_search (domain_name_list): {office.example, lab.example}"
  let skPacket = """
    yiaddr = 10.16.118.42
    subnet_mask (ip): 255.255.254.0
    server_identifier (ip): 10.16.32.100
    router (ip_mult): {10.16.119.254}
    domain_name_server (ip_mult): {10.16.32.100, 10.17.11.100}
    domain_name (string): skoltech.ru
    """
  let home = detectLAN(interface: "en0", addresses: ["192.168.1.20"], packet: homePacket)!
  let office = detectLAN(interface: "en0", addresses: ["10.42.7.20"], packet: officePacket)!
  let skLAN = detectLAN(interface: "en0", addresses: ["10.16.118.42"], packet: skPacket)!
  let localSk = detectNetwork(sk, lan: skLAN)!
  let localFic = detectNetwork(fic, lan: home, server: home.servers[0], answer: "172.18.7.25\n")!
  precondition(localSk.servers == skLAN.servers && localSk.prefixes == sk.routes)
  precondition(detectNetwork(sk, lan: home) == nil && detectNetwork(sk, lan: office) == nil)
  var hotspot = skLAN
  hotspot.dhcpServer = "10.16.119.254"
  precondition(detectNetwork(sk, lan: hotspot) == nil)
  hotspot = skLAN
  hotspot.domains = ["lan"]
  precondition(detectNetwork(sk, lan: hotspot) == nil)
  hotspot = skLAN
  hotspot.interface = "utun4"
  precondition(detectNetwork(sk, lan: hotspot) == nil)
  precondition(detectNetwork(fic, lan: home, server: home.servers[0], answer: "203.0.113.21\n") == nil)
  precondition(detectNetwork(fic, lan: home, server: home.servers[0]) == nil)
  precondition(detectNetwork(fic, lan: home, server: "8.8.8.8", answer: "172.18.7.25\n") == nil)
  let onLink = detectNetwork(fic, lan: home, server: home.servers[0], answer: "192.168.1.10\n")!
  precondition(!onLink.routes.contains(where: { $0.network == "192.168.1.10/32" }))
  precondition(detectLAN(interface: "en0", addresses: ["192.168.2.40"], packet: homePacket) == nil)
  precondition(
    detectLAN(
      interface: "en0", addresses: [home.address],
      packet: homePacket.replacingOccurrences(of: "255.255.255.0", with: "255.0.255.0")) == nil)
  print(
    "PASS: unified DHCP/probe network detection, stale lease and hotspot rejection, private probe and on-link routing")

  let endpoints = directHostRoutes(sk.endpoints, lans: [home])
  let oldEndpoint = Route(network: "83.69.192.101/32", gateway: "10.99.0.1", interface: "en0")
  let unrelated = Route(network: "203.0.113.1/32", gateway: "10.99.0.1", interface: "en0")
  let stale = staleDirectRoutes([oldEndpoint, unrelated], desired: endpoints, lans: [home])
  precondition(stale == [oldEndpoint])
  let repaired = planRoutes(owned: [], current: [oldEndpoint, unrelated], desired: endpoints, stale: stale)
  precondition(repaired.remove == [oldEndpoint] && repaired.add == endpoints && repaired.conflicts.isEmpty)
  precondition(staleDirectRoutes(endpoints, desired: endpoints, lans: [home]).isEmpty)
  // OpenConnect adds a host route alongside our identical /32 network route.
  let duplicates = parseRoutes("83.69.192.101 192.168.1.1 UGHS en0\n83.69.192.101/32 192.168.1.1 UGSc en0")
  let duplicatePlan = planRoutes(owned: endpoints, current: duplicates, desired: endpoints)
  precondition(duplicatePlan.add.isEmpty && duplicatePlan.remove.isEmpty && duplicatePlan.conflicts.isEmpty)
  let otherGateway = Route(network: endpoints[0].network, gateway: "192.168.1.2", interface: "en0")
  precondition(planRoutes(owned: endpoints, current: duplicates + [otherGateway], desired: endpoints).conflicts == [endpoints[0].network])
  let switchedEndpoints = directHostRoutes(sk.endpoints, lans: [office])
  let switchedPlan = planRoutes(owned: endpoints, current: endpoints, desired: switchedEndpoints)
  precondition(switchedPlan.remove == endpoints && switchedPlan.add == switchedEndpoints)
  precondition(directHostRoutes(sk.endpoints, lans: []).isEmpty)
  let skVPN = Route(network: "10.0.0.0/8", gateway: "10.16.252.2", interface: "utun5")
  let ficVPN = Route(network: "192.168.70.0/24", gateway: "192.168.72.2", interface: "utun7")
  let arrival = planRoutes(owned: [], current: [skVPN, ficVPN], desired: localSk.routes)
  precondition(arrival.add == localSk.routes && arrival.remove.isEmpty)
  let departure = planRoutes(owned: arrival.add, current: arrival.add + [skVPN, ficVPN])
  precondition(departure.remove == arrival.add && departure.add.isEmpty)
  let foreign = Route(network: sk.routes[0], gateway: skVPN.gateway, interface: skVPN.interface)
  let conflict = planRoutes(owned: [], current: [foreign], desired: localSk.routes)
  precondition(conflict.remove.isEmpty && conflict.conflicts == [sk.routes[0]])
  let idempotent = planRoutes(owned: arrival.add, current: arrival.add + [skVPN, ficVPN], desired: localSk.routes)
  precondition(idempotent.add.isEmpty && idempotent.remove.isEmpty)
  let changedFic = detectNetwork(fic, lan: home, server: home.servers[0], answer: "172.18.7.26\n")!
  let moved = planRoutes(owned: localFic.routes, current: localFic.routes, desired: changedFic.routes)
  precondition(moved.remove.map { $0.network } == ["172.18.7.25/32"])
  precondition(moved.add.map { $0.network } == ["172.18.7.26/32"])
  precondition(planRoutes(owned: localFic.routes, current: localFic.routes).remove == localFic.routes)
  precondition(lanDNSRoutes([home]).isEmpty)
  precondition(lanDNSRoutes([office]) == [Route(network: "10.42.0.53/32", gateway: "10.42.7.1", interface: "en0")])
  precondition(canonicalNetwork("10.16/16") == "10.16.0.0/16")
  precondition(parseRoutes("10.16/16 10.16.119.254 UGSc en0").first == localSk.routes.first)
  print(
    "PASS: endpoint gateway repair, network arrival/departure, foreign VPN route preservation, conflicts and idempotence"
  )

  let dns = ["1.1.1.1", "1.0.0.1"]
  precondition(internetVPNActive("0/1 utun5 UScg utun5\ndefault 192.168.1.1 UGScg en0"))
  precondition(internetVPNActive("default link#31 UCS utun5"))
  precondition(internetVPNActive("0/1 10.8.0.1 UGSc tun0"))
  precondition(internetVPNActive("default 10.8.0.1 UGSc ppp0"))
  precondition(!internetVPNActive("10/8 10.16.252.2 UGSc utun6\ndefault 192.168.1.1 UGScg en0"))
  precondition(routeInterface("   route to: 1.1.1.1\n  interface: utun8\n      flags: <UP,DONE>\n") == "utun8")
  precondition(routeInterface("route: not in table\n") == nil)
  precondition(selectPublicDNS(configured: dns, lan: home.servers, interfaces: [:], fullTunnel: false) == home.servers)
  let splitDNS = ["1.1.1.1": "utun8", "1.0.0.1": "en0"]
  precondition(
    selectPublicDNS(configured: dns, lan: home.servers, interfaces: splitDNS, fullTunnel: false) == ["1.1.1.1"])
  precondition(
    selectPublicDNS(configured: dns, lan: home.servers, interfaces: splitDNS, fullTunnel: true) == ["1.1.1.1"])
  precondition(
    selectPublicDNS(configured: dns, lan: home.servers, interfaces: ["1.1.1.1": "en0"], fullTunnel: true).isEmpty)
  precondition(selectPublicDNS(configured: dns, lan: [], interfaces: [:], fullTunnel: true).isEmpty)
  precondition(selectPublicDNS(configured: dns, lan: [], interfaces: [:], fullTunnel: false) == dns)
  precondition(tunnelInterface("tap0") && tunnelInterface("ipsec1") && !tunnelInterface("bridge100"))
  print("PASS: client-independent tunnel detection, split VPN DNS routing and blocked-DNS fallback")

  let vpnDNS = [sk.domain: skLAN.servers, fic.domain: ["192.168.72.1"]]
  let homeDNS = forwarderRules(lans: [home], scoped: vpnDNS, upstreams: dns)
  precondition(homeDNS.contains("server=//192.168.1.1\n"))
  precondition(homeDNS.contains("server=/skoltech.ru/10.16.32.100\n"))
  precondition(homeDNS.contains("server=/frccsc.ru/192.168.72.1\n"))
  precondition(homeDNS.contains("server=1.1.1.1\n"))
  let skDNS = forwarderRules(lans: [skLAN], scoped: vpnDNS, upstreams: dns, networks: [localSk])
  precondition(skDNS.contains("server=//10.16.32.100\n"))
  precondition(skDNS.contains("server=/frccsc.ru/192.168.72.1\n"))
  precondition(skDNS.contains("rev-server=10.16.0.0/16,10.16.32.100\n"))
  let ficDNS = forwarderRules(lans: [home], scoped: vpnDNS, upstreams: dns, networks: [localFic])
  precondition(ficDNS.contains("server=/frccsc.ru/192.168.1.1\n"))
  precondition(!ficDNS.contains("server=/frccsc.ru/192.168.72.1\n"))
  precondition(ficDNS.contains("server=/skoltech.ru/10.16.32.100\n"))
  precondition(ficDNS.contains("rev-server=192.168.70.0/24,192.168.1.1\n"))
  precondition(localFic.domain != sk.domain)
  let officeDNS = forwarderRules(lans: [office], scoped: vpnDNS, upstreams: dns)
  precondition(officeDNS.contains("server=/lab.example/10.42.0.53\n"))
  precondition(officeDNS.contains("rev-server=10.42.7.0/24,10.42.0.53\n"))
  precondition(!officeDNS.contains(home.servers[0]))
  precondition(forwarderRules(lans: [], scoped: [:], upstreams: dns).contains("server=//\n"))
  precondition(dnsDomain("evil.example\nserver=8.8.8.8") == nil)
  print(
    "PASS: other LAN plus both VPNs, Skoltech LAN plus FRCCSC VPN, FRCCSC LAN plus Skoltech VPN, local and reverse DNS")
}

func routeUpdatesTest() throws {
  let config = Configuration(vpn_dns: ["1.1.1.1"], networks: [], firewall: nil)
  let home = LAN(interface: "en0", address: "192.168.1.101", network: "192.168.1.0/24",
    gateway: "192.168.1.1", servers: ["192.168.1.1"], domains: [], dhcpServer: "192.168.1.1")
  let route = Route(network: "83.69.192.101/32", gateway: "192.168.1.1", interface: "en0")
  let unrelated = Route(network: "203.0.113.1/32", gateway: "192.168.1.1", interface: "en0")
  let updater = Controller(config: config)
  updater.state = State(addresses: [:])
  updater.lans = [home]
  var calls: [[String]] = []
  var result: Int32 = 0
  let command: (String, [String]) -> CommandResult = { executable, arguments in
    precondition(executable == "/sbin/route")
    calls.append(arguments)
    return CommandResult(status: result, output: "mock route")
  }
  updater.command = command
  updater.configureRoutes(current: [unrelated], desired: [route], endpoints: [route])
  precondition(calls == [["-n", "add", "-net", route.network, route.gateway,
    "-ifp", "en0", "-ifa", home.address]])

  // A fresh process loads the prior snapshot and leaves correct routes alone.
  let next = Controller(config: config)
  next.state = try JSONDecoder().decode(State.self, from: JSONEncoder().encode(updater.state))
  next.command = command
  next.lans = [home]
  next.configureRoutes(current: [route, unrelated], desired: [route], endpoints: [route])
  precondition(calls.count == 1)
  next.lans[0].address = "192.168.1.102"
  result = 1
  next.configureRoutes(current: [route, unrelated], desired: [route], endpoints: [route])
  precondition(next.state.addresses?[route.network] == home.address && !next.errors.isEmpty)
  result = 0
  next.configureRoutes(current: [route, unrelated], desired: [route], endpoints: [route])
  precondition(calls.count == 3 && calls.last!.last == "192.168.1.102")
  next.lans = []
  next.configureRoutes(current: [route, unrelated], desired: [], endpoints: [])
  precondition(next.state.routes.isEmpty && next.state.addresses?[route.network] == nil)
  precondition(calls.last! == ["-n", "delete", "-net", route.network, route.gateway])
  precondition(calls.allSatisfy { !$0.contains(unrelated.network) })
  print("PASS: source-address repair across runs, retries, idempotence and route cleanup")

  var entries = Set(["127.0.0.1", "10.0.0.2", "192.168.1.1"])
  next.command = { executable, arguments in
    precondition(executable == "/sbin/pfctl")
    if arguments[6] == "show" { return CommandResult(status: 0, output: entries.sorted().joined(separator: "\n")) }
    let addresses = Set(arguments.dropFirst(7))
    if arguments[6] == "add" { entries.formUnion(addresses) } else { entries.subtract(addresses) }
    return CommandResult(status: 0, output: "")
  }
  var owned = ["127.0.0.1", "10.0.0.2"]
  next.firewallTable("amn/test", "test", wanted: ["127.0.0.1", "10.0.0.3", "192.168.1.1"], owned: &owned)
  precondition(Set(owned) == ["127.0.0.1", "10.0.0.3"])
  next.firewallTable("amn/test", "test", wanted: [], owned: &owned)
  precondition(owned.isEmpty && entries == ["192.168.1.1"])
  print("PASS: firewall exception ownership and cleanup preserve foreign entries")

  let fic = NetworkSettings(domain: "frccsc.ru", endpoints: [], routes: ["192.168.70.0/24"],
    lan: LANMatch(probe: "login.hpc.frccsc.ru"))
  let probe = Controller(config: Configuration(vpn_dns: ["1.1.1.1"], networks: [fic]))
  probe.state = State(addresses: [:], networks: [detectNetwork(fic, lan: home,
    server: home.servers[0], answer: "172.18.7.25\n")!])
  probe.state = try JSONDecoder().decode(State.self, from: JSONEncoder().encode(probe.state))
  probe.lans = [home]
  probe.command = { _, _ in CommandResult(status: 9, output: "timeout") }
  precondition(probe.localNetworks().count == 1)
  probe.state.networks?[0].observed = Date().addingTimeInterval(-61)
  precondition(probe.localNetworks().isEmpty)
  probe.state.networks?[0].observed = Date()
  probe.lans[0].address = "192.168.1.102"
  precondition(probe.localNetworks().isEmpty)
  probe.lans = [home]
  probe.command = { _, _ in CommandResult(status: 0, output: "") }
  precondition(probe.localNetworks().isEmpty)
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(probe.state)) as! [String: Any]
  var cached = legacy["networks"] as! [[String: Any]]
  cached[0].removeValue(forKey: "observed")
  legacy["networks"] = cached
  let restored = try JSONDecoder().decode(State.self, from: JSONSerialization.data(withJSONObject: legacy))
  precondition(restored.networks?.first?.observed == nil)
  print("PASS: persisted LAN detection survives only brief timeouts on the same network")
}

selfTest()
try routeUpdatesTest()

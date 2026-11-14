import Foundation

private final class ProbeCredentials: AccountCredentialStorage {
    private var record:AccountRecord?
    func read() -> AccountRecord? { record }
    func write(_ record: AccountRecord) throws {self.record=record}
    func clear() {record=nil}
}
private final class ProbeRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Explicit hosted smoke check. No browser, personal account, Keychain write, payment or game launch.
@main enum AccountHostedProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count==3 && CommandLine.arguments[2]=="--pair") else {
            fputs("Usage: account-hosted-probe <Info.plist> [--pair]\n", stderr); exit(2)
        }
        let pairing=CommandLine.arguments.count==3
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        info["PlaymeltCommercialAccessEnabled"] = true
        info["PlaymeltAccountServiceAvailable"] = true
        let config = AccountConfiguration(info: info)
        guard config.complete, let base = config.url else { exit(2) }
        var result: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "accountURL": base.absoluteString,
            "personalCredentialsUsed": false, "keychainModified": false, "paymentStarted": false, "browserOpened": false,"interactivePairingRequested":pairing]
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: sessionConfig, delegate: ProbeRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var finished = false, healthy = false
        session.dataTask(with: base.appendingPathComponent("health")) { body, response, error in
            DispatchQueue.main.async {
                let http = response as? HTTPURLResponse
                let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                healthy = error == nil && http?.statusCode == 200 && object?["status"] as? String == "ok"
                result["healthStatus"] = http?.statusCode ?? 0
                result["healthJSON"] = object?["status"] as? String == "ok"
                result["release"] = object?["release"] as? String ?? ""
                result["healthy"] = healthy
                finished = true
            }
        }.resume()
        func until(_ done: () -> Bool, seconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return done()
        }
        result["healthCompleted"] = until({ finished }, seconds: 20)
        if healthy {
            let account = AccountService(config: config, credentials: ProbeCredentials())
            defer { account.shutdown() }
            var started = false, available = false
            account.onChange = {
                if started && account.snapshot()["pending"] as? Bool == false { finished = true }
            }
            finished = false; started = true
            account.connect { url in
                available = url.host == base.host && url.path == base.appendingPathComponent("device").path
                if pairing,available {print("PAIRING_CODE "+(account.snapshot()["userCode"] as? String ?? ""));fflush(stdout)}
                finished = true
            }
            result["deviceStartCompleted"] = until({ finished }, seconds: 30)
            result["deviceContractAccepted"] = available
            result["deviceCodeLength"] = (account.snapshot()["userCode"] as? String ?? "").count
            result["deviceApprovalTested"] = false
            result["signedEntitlementTested"] = false
            if pairing,available {
                let approved=until({account.snapshot()["accessVerified"] as? Bool==true},seconds:180)
                result["deviceApprovalTested"]=approved
                var authorized:Bool?
                if approved {account.authorize{ok,_ in authorized=ok};_ = until({authorized != nil},seconds:30)}
                result["signedEntitlementTested"]=authorized==true
                result["verifiedPlan"]=account.snapshot()["plan"] as? String ?? ""
                result["verifiedPhase"]=account.snapshot()["phase"] as? String ?? ""
                var loggedOut:Bool?
                account.logout{ok in loggedOut=ok};_ = until({loggedOut != nil},seconds:30)
                result["probeDeviceLogoutConfirmed"]=loggedOut==true
            }
        }
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(output); print("")
        let passed=healthy && result["deviceContractAccepted"] as? Bool == true && (!pairing || (result["signedEntitlementTested"] as? Bool==true && result["probeDeviceLogoutConfirmed"] as? Bool==true))
        exit(passed ? 0 : 1)
    }
}

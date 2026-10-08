import Foundation
import TshdKit

print("Locating tsh binary...")
guard let binary = TshdProcess.locateBinary() else {
    print("FAILED: could not locate tsh binary")
    exit(1)
}
print("Found tsh at \(binary)")

let tshd = TshdProcess()
print("Starting tshd, socket path: \(tshd.socketPath)")

do {
    try await tshd.start()
} catch {
    print("FAILED to start tshd: \(error)")
    print("--- collected output ---")
    print(await tshd.collectedOutput())
    exit(1)
}
print("tshd is ready.")

do {
    let client = try TshdClient(socketPath: tshd.socketPath)

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await client.run()
        }
        group.addTask {
            let response = try await client.listRootClusters()
            print("ListRootClusters returned \(response.clusters.count) cluster(s):")
            for cluster in response.clusters {
                print("  - uri=\(cluster.uri) name=\(cluster.name) connected=\(cluster.connected)")
            }
            if let target = ProcessInfo.processInfo.environment["PASSWORDLESS_CLUSTER"] {
                print("Starting passwordless login for \(target) — expect a Touch ID / security key prompt")
                do {
                    try await client.loginPasswordless(clusterURI: target) { event in
                        switch event {
                        case .tap: print("EVENT: tap")
                        case .retap: print("EVENT: retap")
                        case .pin: print("EVENT: pin requested")
                        case .credentials(let names, _): print("EVENT: choose credential among \(names)")
                        }
                    }
                    print("PASSWORDLESS LOGIN SUCCEEDED")
                } catch {
                    print("PASSWORDLESS LOGIN FAILED: \(error)")
                    print("--- tshd output ---")
                    print(await tshd.collectedOutput())
                }
            }
            client.shutdown()
        }

        try await group.next()
        group.cancelAll()
    }
    print("SUCCESS")
} catch {
    print("FAILED during gRPC call: \(error)")
    await tshd.stop()
    exit(1)
}

await tshd.stop()

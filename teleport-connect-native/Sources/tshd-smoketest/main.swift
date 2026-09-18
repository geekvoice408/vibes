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

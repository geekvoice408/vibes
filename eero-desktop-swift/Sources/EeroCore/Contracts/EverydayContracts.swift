import Foundation

/// Request builders and response validation for everyday features (port of `EverydayContracts`).
public enum EverydayContracts {
    public static func backupOrder(_ ids: [String]) throws -> JSON {
        let all = try ids.map(ExtendedContracts.identifier)
        if all.isEmpty || Set(all).count != all.count { throw EeroError.argument("Each saved backup network must appear exactly once.") }
        return JSON.obj(("rearranged_ids", all))
    }

    public static let symptoms = ["connection_drops", "eeros_red", "internet_offline", "internet_slow"]

    public static func symptom(_ value: String) throws -> JSON {
        if !symptoms.contains(value) { throw EeroError.argument("Choose a supported connection problem.") }
        return JSON.obj(("symptom", value))
    }

    public static func productId(_ value: String?) throws -> String {
        guard let value, !value.allSatisfy(\.isWhitespace), value.utf16.count <= 200,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw EeroError.argument("eero did not return a valid product identifier.") }
        return value
    }

    public static func offers(_ products: [String]) throws -> JSON {
        var all: [String] = []
        for p in products { let id = try productId(p); if !all.contains(id) { all.append(id) } }
        if all.isEmpty || all.count > 50 { throw EeroError.argument("Select between one and fifty available products.") }
        return JSON.obj(("product_ids", all))
    }

    public static func referral(_ networkId: String, _ productId: String) throws -> JSON {
        JSON.obj(("product_id", try self.productId(productId)), ("network_id", try ExtendedContracts.identifier(networkId)))
    }

    /// Labelled Guardian sign-in details from `POST /2.2/partners/guardian`.
    public static func guardianLogin(_ data: JSON) throws -> [String: String] {
        let id = data.s("guardian_id"), password = data.s("guardian_secret")
        if id.isEmpty || password.isEmpty || id.utf16.count > 4096 || password.utf16.count > 8192 {
            throw EeroError.operation("eero did not return complete Guardian sign-in details for this account.")
        }
        return ["Guardian username": id, "Guardian password": password]
    }

    /// Display order for `guardianLogin` results.
    public static let guardianLoginOrder = ["Guardian username", "Guardian password"]

    /// Supported Thread credential fields, labelled with spaces instead of underscores.
    public static func threadCredentials(_ data: JSON) throws -> [String: String] {
        var values: [String: String] = [:]
        for key in threadCredentialKeys {
            let value = data.s(key)
            if !value.isEmpty && value.utf16.count <= 8192 { values[key.replacingOccurrences(of: "_", with: " ")] = value }
        }
        if values.isEmpty { throw EeroError.operation("This network did not return Thread credentials for your account.") }
        return values
    }

    public static let threadCredentialKeys = ["active_operational_dataset", "commissioning_credential", "master_key"]
}

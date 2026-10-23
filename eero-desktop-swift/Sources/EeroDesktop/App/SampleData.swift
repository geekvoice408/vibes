#if os(macOS)
import Foundation
import EeroCore

extension AppModel {
    /// Sample account used by `--preview` (port of `MainWindow.SampleData`). No network requests are made.
    func loadSampleData() {
        func parse(_ text: String) -> JSON { (try? JSON.parse(text)) ?? .null }

        account = parse(#"{"name":"Preview account"}"#)
        networkURL = "/2.2/networks/preview"
        networkList = parse(#"[{"name":"Maple House","url":"/2.2/networks/preview"}]"#).list
        var net = parse(#"{"name":"Maple House","health":{"internet":{"status":"connected"}},"speed":{"down":{"value":942,"units":"Mbps"},"up":{"value":118,"units":"Mbps"}},"wpa3":true,"band_steering":true,"sqm":true,"upnp":false,"ipv6":true}"#)
        var sampleNodes = parse(#"[{"location":"Living room","model":"eero Pro 6E","gateway":true,"status":"green","os_version":"Preview","ip_address":"192.168.4.1","connected_clients_count":3},{"location":"Office","model":"eero Pro 6E","gateway":false,"status":"green","os_version":"Preview","ip_address":"192.168.4.2","connected_clients_count":2}]"#).list
        var sampleDevices = parse(#"[{"nickname":"Office PC","connected":true,"wireless":false,"ip":"192.168.4.20","manufacturer":"Microsoft","mac":"02:00:00:00:00:01"},{"nickname":"Living room TV","connected":true,"wireless":true,"frequency":"5 GHz","ip":"192.168.4.34","mac":"02:00:00:00:00:02"},{"nickname":"Kitchen speaker","connected":true,"wireless":true,"frequency":"2.4 GHz","ip":"192.168.4.45","mac":"02:00:00:00:00:03"},{"nickname":"Laptop","connected":true,"wireless":true,"frequency":"6 GHz","ip":"192.168.4.52","mac":"02:00:00:00:00:04"},{"nickname":"Tablet","connected":false,"wireless":true,"ip":"192.168.4.63","mac":"02:00:00:00:00:05"} ]"#).list
        var sampleProfiles = parse(#"[{"name":"Family","paused":false},{"name":"Kids","paused":true}]"#).list
        lastRefresh = Date()

        net["ipv6_upstream"] = true
        net["dns"] = ["mode": "automatic", "caching": true, "custom": ["ips": ["1.1.1.1", "8.8.8.8"]]]
        net["connection"] = ["mode": "nat"]
        net["timezone"] = ["value": "America/Chicago"]
        net["auto_setup_mode"] = "DEFAULT"
        net["accessories"] = [["name": "Sample accessory", "model": "Sample cellular accessory", "dsn": "SAMPLEACCESSORY1", "registered": true, "joined": true, "eero_id": "1"]]
        net["amazon_account_linked"] = true
        net["smart_home_hub"] = true

        for i in sampleDevices.indices { sampleDevices[i]["url"] = .string("/2.2/networks/preview/devices/\(i)") }
        for i in sampleNodes.indices {
            let base = "/2.2/eeros/\(i + 1)"
            sampleNodes[i]["url"] = .string(base)
            sampleNodes[i]["serial"] = .string("PREVIEWNODE000\(i + 1)")
            sampleNodes[i]["led_on"] = true
            sampleNodes[i]["led_brightness"] = 100
            sampleNodes[i]["resources"] = .object(["led_action": .string(base + "/led"), "connections": .string(base + "/connections")])
        }
        for i in sampleProfiles.indices { sampleProfiles[i]["url"] = .string("/2.2/networks/preview/profiles/\(i + 1)") }

        network = net
        nodes = sampleNodes
        devices = sampleDevices
        profiles = sampleProfiles
    }
}
#endif

import Foundation

/// One page in the app's navigation menu (port of `FeatureEntry`).
public struct FeatureEntry: Hashable, Sendable {
    /// Route path, e.g. "Settings/Advanced networking/DNS". Paths are kept identical to the Windows app so routes match.
    public let path: String
    public let description: String
    public let evidence: String
    public let limitation: String?

    public init(_ path: String, _ description: String, _ evidence: String, _ limitation: String? = nil) {
        self.path = path; self.description = description; self.evidence = evidence; self.limitation = limitation
    }

    /// Last path component, for display. Routes that name the local platform display "Mac" instead of "Windows".
    public var title: String {
        let last = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        return last.hasPrefix("Windows ") ? "Mac " + last.dropFirst("Windows ".count) : last
    }

    /// Path of the containing menu, or "" for a root entry.
    public var parent: String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }
}

/// The feature menu map that drives navigation (port of `FeatureCatalog`).
public enum FeatureCatalog {
    public static let entries: [FeatureEntry] = [
        FeatureEntry("Home/Internet", "Internet status, speed tests, WAN and backup connectivity", "TabBarMode, HomeViewModel"),
        FeatureEntry("Home/eeros", "Node details, status lights, connections and restarts", "IEeroService"),
        FeatureEntry("Home/Profiles", "Create profiles, assign devices, pause access and schedule pauses", "ProfileUpdateRequest, ScheduledPause"),
        FeatureEntry("Home/Security & privacy", "Advanced Security, content filters, ad blocking and website controls", "DnsPolicySlug, INetworkService"),
        FeatureEntry("Home/Security & privacy/Content filters", "Unified content filters for additional wifi subnets", "SubnetContentFiltersRequest"),
        FeatureEntry("Home/Add or replace eero", "Add by serial number, discover nearby eeros and configure automatic setup", "IEeroService.addEeroWithSerial"),
        FeatureEntry("Home/Add or replace eero/Find nearby eeros", "Native Bluetooth discovery and read-only eero identity checks", "EeroBleManagerLive, EeroUuids"),
        FeatureEntry("Home/Add or replace eero/Automatic setup", "Cloud-discovered eeros and automatic setup preferences", "getAutoDiscoveredEeros, SetAutoSetupMode"),
        FeatureEntry("Home/Add or replace eero/Create a network", "Create a wired DHCP network and claim its gateway by serial", "CreateNetworkRequest, IEeroService.addEeroWithSerial", "Not validated on unconfigured hardware; Bluetooth write provisioning and gateway replacement are incomplete."),
        FeatureEntry("Home/eeros/Placement tests", "Run cloud placement tests and review eero signal ratings", "runPlacementTest, PlacementResult"),
        FeatureEntry("Home/Security & privacy/VPN", "Guardian device registration, locations, devices and macOS VPN controls", "GuardianVpnPetRequest, Guardian Connect API, WireGuard, NetworkExtension"),
        FeatureEntry("Devices/Blocked devices", "Review and unblock devices", "NetworkService.blockDevice, unblockDevice"),
        FeatureEntry("Activity/Data usage", "Network data usage and device breakdown", "IDataUsageService"),
        FeatureEntry("Activity/Security activity", "Threat and content-filter activity", "IInsightsService"),
        FeatureEntry("Activity/Network events", "Recent network events", "INetworkService.getNetworkEvents"),
        FeatureEntry("Settings/Wifi name & password", "View, change, copy, and share wifi details as a QR code", "NetworkResources.password"),
        FeatureEntry("Settings/Guest wifi network", "Guest network access, credentials and QR sharing", "GuestNetwork, GuestResources"),
        FeatureEntry("Settings/Additional wifi networks", "Additional SSIDs, guest and IoT access, bandwidth limits and subnet filters", "SubnetConfig"),
        FeatureEntry("Settings/Business guest wifi", "Existing guest portal branding, session duration and visitor fields", "CaptivePortalConfigurationRequest"),
        FeatureEntry("Settings/Nickname & location", "Network nickname and timezone", "NetworkService.updateBusinessNameOrNetworkNickname"),
        FeatureEntry("Settings/Advanced networking", "DHCP, DNS, reservations, firewall, wireless and smart-home options", "SettingsRoute, INetworkService"),
        FeatureEntry("Settings/Advanced networking/Internet connection", "WAN address, DHCP, static IP and PPPoE status", "Network.ip_settings, NetworkPppoeConfig"),
        FeatureEntry("Settings/Advanced networking/Internet connection/ISP settings", "Existing-network PPPoE credentials and ISP VLAN tagging", "NetworkPppoeConfig, Network.vlan"),
        FeatureEntry("Settings/Advanced networking/DHCP & NAT", "Automatic/manual addressing, bridge mode and NAT port randomization", "DhcpConfigurationRequest"),
        FeatureEntry("Settings/Advanced networking/DNS", "ISP or custom DNS and local DNS caching", "Dns, HostInfoList"),
        FeatureEntry("Settings/Advanced networking/DNS/DNS performance", "Compare resolver latency and review gateway DNS test results", "DnsPerfTestRequest, NetworkService.runDnsPerfTest"),
        FeatureEntry("Settings/Advanced networking/Reservations & port forwarding", "IPv4 reservations, port mappings and IPv6 firewall rules", "NetRules, NetworkReservation, NetworkForward"),
        FeatureEntry("Settings/Advanced networking/IPv6", "Enable or disable upstream IPv6", "Network.ipv6_upstream"),
        FeatureEntry("Settings/Advanced networking/UPnP", "Automatic port mapping", "Network.upnp"),
        FeatureEntry("Settings/Advanced networking/Wireless settings", "WPA3, client steering, optimization, compatibility and MLO", "Network, MultiLinkOperationModeRequest"),
        FeatureEntry("Settings/Advanced networking/Thread", "Thread network and credential syncing", "UpdateThreadNetworkRequest"),
        FeatureEntry("Settings/Advanced networking/Dynamic DNS", "eero DDNS access and hostname", "INetworkService.ddnsEnable, ddnsDisable"),
        FeatureEntry("Settings/Advanced networking/Power saving", "Power optimization and scheduled power saving", "PowerOptimizationRequest, PowerSavingScheduleRequest"),
        FeatureEntry("Settings/Advanced networking/Internet backup", "Backup access points and connectivity tests", "AddBackupNetworkRequest, BackupInternetEnabledRequest"),
        FeatureEntry("Settings/Advanced networking/Multi-WAN", "WAN links, failover and secondary-WAN device access", "INetworkService.coGetWanLinks"),
        FeatureEntry("Settings/Advanced networking/Multiple static IPs", "Public LAN and NAT public-address ranges", "MultiStaticIpRequest"),
        FeatureEntry("Settings/User permissions", "Network members, admin invitations and revocation", "CreateInviteRequest, INetworkService.removeAdmin"),
        FeatureEntry("Settings/User permissions/Join a network", "Review, accept or decline an eero invitation", "InviteQueryRequest, ExternalInviteRequest"),
        FeatureEntry("Settings/User permissions/Incoming access invitations", "Review, accept or decline account access invitations", "MemberPromotionResponse, PromotionInviteRequest"),
        FeatureEntry("Settings/Software updates", "Update status, install available firmware and preferred update hour", "NetworkUpdates, PreferredUpdateHour"),
        FeatureEntry("Settings/Appearance", "Light, dark or macOS system appearance", "SettingsRoute.Appearance"),
        FeatureEntry("Settings/Notifications", "Network notification preferences, history and Mac notifications", "NetworkNotifications, PushSettings"),
        FeatureEntry("Settings/Troubleshooting", "Connection checks, diagnostics, coverage and upgrade scans", "INetworkService.wifiCoverageScan, wifiGenerationScan"),
        FeatureEntry("Settings/Troubleshooting/Guided diagnostics", "Diagnose slow internet, offline service, dropped connections and red eeros", "HealthCheckSymptom, HealthCheckResults"),
        FeatureEntry("Settings/Troubleshooting/Connect a device", "Temporarily pause and restore 5 GHz for device setup", "TemporaryFlags.hide_5g, updateTemporaryFlags"),
        FeatureEntry("Settings/Advanced networking/Wireless settings/Fast roaming", "Review and configure fast transition compatibility", "FastTransitionStatus"),
        FeatureEntry("Settings/Advanced networking/Internet backup/Find backup wifi", "Discover nearby backup wifi networks and add a selected result", "BackupNetworkDiscoveryStatusResponse"),
        FeatureEntry("Settings/Notifications/Windows notifications", "Open at login, background alerts and missed-update tracking", "macOS background notifications"),
        FeatureEntry("Settings/Account settings", "Account details, name, verified email/phone changes and email preferences", "IUserService"),
        FeatureEntry("Settings/Account settings/Subscriptions", "Subscription status, software-key activation and partner benefits", "IPremiumService, ActivateLicenseKeyRequestBody"),
        FeatureEntry("Settings/Account settings/Subscriptions/Redeem a license key", "Validate a software key, review renewal and activate for a network", "ValidateLicenseKeyRequestBody, ActivateLicenseKeyRequestBody"),
        FeatureEntry("Settings/Account settings/Subscriptions/Partner benefits", "1Password and Malwarebytes codes, benefit status and VPN seats", "IPremiumService"),
        FeatureEntry("Settings/Account settings/Subscriptions/Manage subscriptions & purchases", "Official eero payment service using a temporary account token", "TemporaryExternalToken, TargetPage"),
        FeatureEntry("Settings/Account settings/Subscriptions/Offers & referrals", "Eligible plan offers, referral links, referral email and referral status", "EeroPlusOfferRequest, SubscriptionReferralRequest"),
        FeatureEntry("Settings/Account settings/Subscriptions/Billing & status", "Refresh benefits, payment methods and purchase history", "IPremiumService.getCustomer, TargetPage"),
        FeatureEntry("Settings/Account settings/Subscriptions/Business billing", "Business payment-account management and onboarding", "PaymentAccountManagementResponse, PaymentAccountOnboardingResponse"),
        FeatureEntry("Home/Security & privacy/Identity protection", "Identity protection activation, digital-footprint scans and email verification", "DigitalFootprintScanRequest, DigitalFootprintVerifyCodeRequest"),
        FeatureEntry("Settings/Connected services", "Amazon, eero Built-in and connected-service status", "Network.proxied_nodes, simple_setup"),
        FeatureEntry("Settings/Connected services/Connected device setup", "Review and configure per-vendor device setup permissions", "SimpleSetupNetworkConfiguration"),
        FeatureEntry("Settings/Connected services/Amazon connected home", "Linked-account status, Zigbee discovery and account unlinking", "runZigbeeDeviceDiscovery, unlinkAmazonAccount"),
        FeatureEntry("Settings/Connected services/Accessories & cellular", "Accessory setup status, details, removal and phone-line associations", "AccessoryStatus, Accessory, SipConfigAssociation"),
        FeatureEntry("Settings/Business guest wifi/eero Insight", "Open the official business management portal", "SettingsViewModel.setupEeroInsight"),
        FeatureEntry("Settings/Network management", "Network switching, ownership transfer and removal", "NetworkResources.transfer, deleteNetwork"),
        FeatureEntry("Settings/Network management/Pending transfers", "Accept or decline incoming network transfers", "PendingTransfersData, acceptNetworkTransfer, denyNetworkTransfer"),
        FeatureEntry("Settings/Network management/Outgoing transfer", "Review, resend or cancel a pending ownership invitation", "getTransferNetworkInvite, resendTransferNetwork"),
        FeatureEntry("Settings/About", "Version, sources, capabilities and compatibility information", "Feature inventory"),
        FeatureEntry("Home/Chat", "Streaming eero chat, recommendations and permission requests", "IConversationsService, ConversationStreamingService"),
        FeatureEntry("Help/Support history", "Read and continue previous eero conversations", "ConversationsResponse, ConversationResponse"),
        FeatureEntry("Help/Contact support", "Account-specific chat, help links and contact information", "SupportInfo, SupportInfoItem, TYPE.CHAT"),
        FeatureEntry("Help", "Official support, support details and feature availability", "TabBarMode.Troubleshooting"),
        FeatureEntry("Help/Service availability", "Account, hardware and service requirements", "Service integrations", "Full Bluetooth provisioning and gateway replacement are unavailable. Amazon sign-in requires an existing eero account using the same Amazon login; no developer account or Business subscription is needed. Email/phone sign-in remains available for accounts that use it. Purchases remain managed by their billing provider. Guardian VPN needs an eligible account, a WireGuard VPN configuration and your approval to add it in macOS System Settings."),
    ]

    /// Breadcrumb parent of a route; root routes fall back to "Home".
    public static func parent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "Home" }
        return String(path[..<i])
    }

    /// Top-level section of a route.
    public static func root(_ path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
    }

    /// Direct child entries of a route, in catalog order.
    public static func children(_ path: String) -> [FeatureEntry] { entries.filter { $0.parent == path } }

    /// Catalog entry for an exact route, if any.
    public static func entry(_ path: String) -> FeatureEntry? { entries.first { $0.path == path } }
}

import CryptoKit
import Foundation
import Testing
@testable import ServerLife

@Suite struct S3PureTests {
    @Test func credentialsFromEnvironment() throws {
        let t: JSON = ["name": "B", "credentials": ["mode": "env", "envPrefix": "BACKUP_"]]
        let c = try S3Pure.resolveCredentials(t, env: ["BACKUP_AWS_ACCESS_KEY_ID": "AK", "AWS_SECRET_ACCESS_KEY": "SK",
                                                       "AWS_SESSION_TOKEN": "ST"])
        #expect(c == SigV4.Credentials(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "ST"))
        #expect(throws: AppError.self) { try S3Pure.resolveCredentials(t, env: [:]) }
        do { _ = try S3Pure.resolveCredentials(t, env: [:]) } catch {
            #expect((error as? AppError)?.message == "B: BACKUP__ACCESS_KEY_ID and BACKUP__SECRET_ACCESS_KEY are not set in this app's environment. "
                    + "Launch ServerLife from a shell that has them, or store keys on the bucket instead.")
        }
        let plain: JSON = ["name": "P"]
        do { _ = try S3Pure.resolveCredentials(plain, env: [:]) } catch {
            #expect((error as? AppError)?.message.hasPrefix("P: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are not set") == true)
        }
    }

    @Test func credentialsOtherModes() throws {
        let explicit: JSON = ["name": "E", "credentials": ["mode": "explicit", "accessKeyId": "A", "secretAccessKey": "S"]]
        #expect(try S3Pure.resolveCredentials(explicit, env: [:]).accessKeyId == "A")
        let missing: JSON = ["name": "E", "credentials": ["mode": "explicit", "accessKeyId": "A"]]
        do { _ = try S3Pure.resolveCredentials(missing, env: [:]); Issue.record("should throw") } catch {
            #expect((error as? AppError)?.message == "E: no access key stored. Edit the bucket and enter one, or switch it to environment credentials.")
        }
        let tele: JSON = ["name": "T", "credentials": ["mode": "teleport", "app": "aws"]]
        do { _ = try S3Pure.resolveCredentials(tele, env: [:]); Issue.record("should throw") } catch {
            #expect((error as? AppError)?.message == "T: the Teleport AWS proxy has not been started for this bucket.")
        }
        let prof: JSON = ["name": "P", "credentials": ["mode": "profile"]]
        do { _ = try S3Pure.resolveCredentials(prof, env: [:]); Issue.record("should throw") } catch {
            #expect((error as? AppError)?.message == "P: the AWS profile has not been resolved for this bucket.")
        }
    }

    @Test func endpoints() throws {
        let aws: JSON = ["bucket": "b1", "region": "eu-west-2"]
        let ep = try S3Pure.endpoint(aws, env: [:])
        #expect(ep == S3Endpoint(scheme: "https", host: "b1.s3.eu-west-2.amazonaws.com", region: "eu-west-2", pathStyle: false, basePath: ""))
        #expect(try S3Pure.endpoint(["bucket": "b"], env: ["AWS_DEFAULT_REGION": "ap-south-1"]).region == "ap-south-1")
        #expect(try S3Pure.endpoint(["bucket": "b"], env: [:]).region == "us-east-1")

        let minio: JSON = ["bucket": "data", "endpoint": "http://minio.local:9000/base/", "pathStyle": true]
        let m = try S3Pure.endpoint(minio, env: [:])
        #expect(m.scheme == "http" && m.host == "minio.local:9000" && m.pathStyle && m.basePath == "/base")
        #expect(try S3Pure.endpoint(["bucket": "x", "endpoint": "minio.example"], env: [:]).scheme == "https")
        // pathStyle defaults to on for a custom endpoint unless explicitly false.
        #expect(try S3Pure.endpoint(["bucket": "x", "endpoint": "e", "pathStyle": false], env: [:]).pathStyle == false)

        #expect(try S3Pure.uri(aws, key: "a b/c.txt", env: [:]).1 == "/a%20b/c.txt")
        #expect(try S3Pure.uri(aws, key: "", env: [:]).1 == "/")
        #expect(try S3Pure.uri(minio, key: "k/x", env: [:]).1 == "/base/data/k/x")
        #expect(try S3Pure.uri(minio, key: "", env: [:]).1 == "/base/data")

        let (sep, suri) = try S3Pure.serviceUri(aws, env: [:])
        #expect(sep.host == "s3.eu-west-2.amazonaws.com" && suri == "/")
        #expect(try S3Pure.serviceUri(minio, env: [:]).1 == "/base/")
    }

    @Test func signedHostIsNormalised() throws {
        #expect(try S3Pure.endpoint(["bucket": "b", "endpoint": "https://MinIO.Example:443/x"], env: [:]).host == "minio.example")
        #expect(try S3Pure.endpoint(["bucket": "b", "endpoint": "http://Lab:80"], env: [:]).host == "lab")
        #expect(try S3Pure.endpoint(["bucket": "b", "endpoint": "http://lab:443"], env: [:]).host == "lab:443")
        do { _ = try S3Pure.endpoint(["bucket": "b", "endpoint": "https://bad host/"], env: [:]); Issue.record("should throw") } catch {
            #expect((error as? AppError)?.message == "Invalid URL")
        }
    }

    @Test func prefixes() {
        #expect(S3Pure.joinPrefix() == "")
        #expect(S3Pure.joinPrefix("", nil) == "")
        #expect(S3Pure.joinPrefix("/a/", "b") == "a/b/")
        #expect(S3Pure.joinPrefix("logs/2024/") == "logs/2024/")
        let t: JSON = ["prefix": "data"]
        #expect(S3Pure.listingBase(t, "") == "data/")
        #expect(S3Pure.listingBase(t, "logs/") == "data/logs/")
        // A full prefix handed back from a listing is not joined twice.
        #expect(S3Pure.listingBase(t, "data/logs/") == "data/logs/")
        #expect(S3Pure.listingBase([:], "x/") == "x/")
    }

    @Test func listPage() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult><Name>b</Name><Prefix>p/</Prefix><IsTruncated>true</IsTruncated>
        <NextContinuationToken>tok&amp;1</NextContinuationToken>
        <Contents><Key>p/</Key><Size>0</Size></Contents>
        <Contents><Key>p/a &amp; b.txt</Key><LastModified>2009-10-12T17:50:30.000Z</LastModified><Size>434234</Size><StorageClass>GLACIER</StorageClass></Contents>
        <Contents><Key>p/c.txt</Key><LastModified>2009-10-12T17:50:30Z</LastModified><Size>1</Size></Contents>
        <CommonPrefixes><Prefix>p/sub/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = S3Pure.parseListPage(xml, base: "p/")
        #expect(page.next == "tok&1")
        #expect(page.entries.map(\.name) == ["sub", "a & b.txt", "c.txt"])
        #expect(page.entries[0].isDirectory && page.entries[0].path == "p/sub/")
        #expect(page.entries[1].size == 434234 && page.entries[1].storageClass == "GLACIER")
        #expect(page.entries[1].mtime == 1_255_369_830_000)
        #expect(page.entries[2].storageClass == "STANDARD" && page.entries[2].mtime == 1_255_369_830_000)
        let fe = page.entries[1].fileEntry
        #expect(fe.type == .file && fe.extra?["storageClass"]?.string == "GLACIER")
        #expect(S3Pure.parseListPage("<IsTruncated>false</IsTruncated>", base: "").next == nil)
        // Truncated with an empty token stops rather than asking again forever.
        #expect(S3Pure.parseListPage("<IsTruncated>true</IsTruncated><NextContinuationToken></NextContinuationToken>", base: "").next == nil)
    }

    @Test func failures() {
        let body = "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>"
        #expect(S3Pure.failure(status: 403, body: "<Error><Code>AccessDenied</Code></Error>", what: "Listing b").message
                == "Listing b: access denied (AccessDenied). Check the credentials and the bucket policy.")
        #expect(S3Pure.failure(status: 404, body: body, what: "Downloading k").message == "Downloading k: not found (NoSuchKey).")
        #expect(S3Pure.failure(status: 400, body: body, what: "X").message == "X: The specified key does not exist.")
        #expect(S3Pure.failure(status: 500, body: "", what: "X").message == "X: HTTP 500")
    }

    @Test func dates() {
        #expect(S3Pure.parseHttpDateMs("Wed, 12 Oct 2009 17:50:00 GMT") == 1_255_369_800_000)
        #expect(S3Pure.parseIsoMs("nope") == 0)
    }

    @Test func storageClasses() {
        #expect(S3StorageClass.all.first?.value == "STANDARD")
        #expect(S3StorageClass.all.count == 8)
        #expect(S3StorageClass.all.map(\.value).contains("DEEP_ARCHIVE"))
    }

    @Test func safeRecordHasNoSecrets() {
        let t: JSON = ["id": "s3_1", "name": "n", "credentials": ["mode": "explicit", "accessKeyId": "AK",
                                                                    "secretAccessKey": "enc:xxx", "sessionToken": "enc:yyy"]]
        let s = S3Service.safe(t)
        #expect(s["credentials"]["secretAccessKey"].isNull && s["credentials"]["sessionToken"].isNull)
        #expect(s["credentials"]["hasSecret"].bool == true && s["credentials"]["accessKeyId"].string == "AK")
        #expect(S3Service.safe(["credentials": ["mode": "profile", "profile": "dev"]])["credentials"]["profile"].string == "dev")
        #expect(S3Service.credentialLabel(["credentials": ["mode": "teleport", "app": "aws-prod"]]) == "teleport: aws-prod")
        #expect(S3Service.credentialLabel([:]) == "environment")
        #expect(S3Service.modeTag(["credentials": ["mode": "profile"]]) == "aws")
    }

    @Test func secretsRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try S3Secrets.seal("wJalr/secret", key: key)
        #expect(sealed.hasPrefix("enc:"))
        #expect(!sealed.contains("wJalr"))
        #expect(try S3Secrets.open(sealed, key: key) == "wJalr/secret")
        #expect(try S3Secrets.open("plain", key: key) == "plain")
        #expect(throws: AppError.self) { try S3Secrets.open(sealed, key: SymmetricKey(size: .bits256)) }
    }

    @Test func scratchDirs() throws {
        let d = try S3Service.scratchDir()
        #expect((d as NSString).lastPathComponent.hasPrefix("serverlife-s3-"))
        #expect(FileManager.default.fileExists(atPath: d))
        try? FileManager.default.removeItem(atPath: d)
        let r = try S3Service.relayDir()
        try S3Service.cleanRelay(r)
        #expect(!FileManager.default.fileExists(atPath: r))
        #expect(throws: AppError.self) { try S3Service.cleanRelay("/tmp/elsewhere") }
        #expect(throws: AppError.self) { try S3Service.cleanRelay(NSHomeDirectory() + "/serverlife-s3-x") }
    }

    @Test func fileSourcePaths() {
        let s = S3FileSource(targetId: "t1")
        #expect(s.id == "s3:t1" && s.kind == .s3 && s.capabilities.isEmpty)
        #expect(s.parent(of: "a/b/c.txt") == "a/b/")
        #expect(s.parent(of: "a/b/") == "a/")
        #expect(s.parent(of: "a/") == "")
        #expect(s.join("a/b", "c") == "a/b/c")
        #expect(s.join("", "c") == "c")
    }
}

@Suite struct AWSParsingTests {
    @Test func ini() {
        let ini = AWSCreds.parseIni("""
        # comment
        [default]
        region = us-west-2 ; trailing
        aws_access_key_id=AKIA
        [profile dev]
        sso_session = corp
        [sso-session corp]
        sso_start_url = https://x
        """)
        #expect(ini["default"]?["region"] == "us-west-2")
        #expect(ini["default"]?["aws_access_key_id"] == "AKIA")
        #expect(ini["profile dev"]?["sso_session"] == "corp")
    }

    @Test func profilesFromDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aws-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try """
        [profile zeta]
        role_arn = arn:aws:iam::1:role/x
        [default]
        region = eu-central-1
        [profile alpha]
        credential_process = /bin/echo
        [sso-session s]
        sso_region = x
        """.write(toFile: dir + "/config", atomically: true, encoding: .utf8)
        try """
        [default]
        aws_access_key_id = AKIDEXAMPLE
        aws_secret_access_key = SECRET
        [keyonly]
        aws_access_key_id = K2
        aws_secret_access_key = S2
        aws_session_token = T2
        """.write(toFile: dir + "/credentials", atomically: true, encoding: .utf8)
        let list = AWSCreds.listProfiles(dir: dir)
        #expect(list.map(\.name) == ["default", "alpha", "keyonly", "zeta"])
        #expect(list[0].region == "eu-central-1" && list[0].staticKey)
        #expect(list[1].credentialProcess && list[3].assumesRole)
        let k = AWSCreds.staticKeys("keyonly", dir: dir)
        #expect(k?.accessKeyId == "K2" && k?.sessionToken == "T2" && k?.source == "~/.aws/credentials")
        #expect(AWSCreds.staticKeys("zeta", dir: dir) == nil)
    }

    @Test func proxyExports() {
        let out = """
        Started AWS proxy on http://127.0.0.1:61234.
        Use the following credentials and HTTPS proxy setting to connect to the proxy:
          export AWS_ACCESS_KEY_ID="ABC"
          export AWS_SECRET_ACCESS_KEY="XYZ"
          export AWS_CA_BUNDLE="/Users/me/.tsh/keys/p/me-app/aws-localca.pem"
          export HTTPS_PROXY="http://127.0.0.1:61234"
        """
        let f = AWSProxy.parseExports(out)
        #expect(f["AWS_ACCESS_KEY_ID"] == "ABC" && f["HTTPS_PROXY"] == "http://127.0.0.1:61234")
        let env = AWSProxy.Env(accessKeyId: "ABC", secretAccessKey: "XYZ", caBundle: f["AWS_CA_BUNDLE"],
                               httpsProxy: f["HTTPS_PROXY"]!, app: "a")
        #expect(env.tunnel == S3Tunnel(proxyHost: "127.0.0.1", proxyPort: 61234, caBundle: f["AWS_CA_BUNDLE"]))
    }

    @Test func roles() {
        let text = """
        Available AWS roles:
        Role Name   Role ARN
        ---------   --------------------------------------
        admin       arn:aws:iam::123456789012:role/admin
        readonly    arn:aws:iam::123456789012:role/readonly

        ERROR: --aws-role flag is required
        """
        let r = AWSProxy.parseRoles(AWSProxy.stripAnsi(text))
        #expect(r.map(\.name) == ["admin", "readonly"])
        #expect(r[0].arn == "arn:aws:iam::123456789012:role/admin")
    }

    @Test func apps() throws {
        let raw = try JSON.parse("""
        [{"metadata":{"name":"aws-prod","description":"Prod","labels":{"aws_account_id":"1234"}},"spec":{"cloud":"AWS","public_addr":"aws.example"}},
         {"metadata":{"name":"grafana"},"spec":{"public_addr":"g.example"}}]
        """)
        let apps = AWSProxy.parseApps(raw)
        #expect(apps.count == 1 && apps[0].name == "aws-prod" && apps[0].accountId == "1234" && apps[0].publicAddr == "aws.example")
    }
}

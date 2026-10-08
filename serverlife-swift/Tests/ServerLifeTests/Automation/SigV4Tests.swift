import Foundation
import Testing
@testable import ServerLife

// AWS's published examples for S3 header-based Signature V4
// ("Signature Calculations for the Authorization Header: Transferring Payload
// in a Single Chunk"), plus the signing-key derivation example from the
// general SigV4 documentation. Offline: no network, no account.

private let exampleCreds = SigV4.Credentials(accessKeyId: "AKIAIOSFODNN7EXAMPLE",
                                             secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
private let exampleDate = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
private let host = "examplebucket.s3.amazonaws.com"

@Suite struct SigV4Vectors {
    @Test func signingKeyDerivation() {
        // docs.aws.amazon.com — "Examples of how to derive a signing key"
        let k = SigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", day: "20120215",
                                 region: "us-east-1", service: "iam")
        #expect(k.map { String(format: "%02x", $0) }.joined()
                == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    @Test func amzDate() {
        let d = SigV4.amzDate(exampleDate)
        #expect(d.full == "20130524T000000Z")
        #expect(d.day == "20130524")
    }

    @Test func getObject() {
        let s = SigV4.sign(method: "GET", host: host, canonicalUri: "/test.txt", headers: ["Range": "bytes=0-9"],
                           region: "us-east-1", credentials: exampleCreds, date: exampleDate)
        #expect(s.canonicalRequest == """
            GET
            /test.txt

            host:examplebucket.s3.amazonaws.com
            range:bytes=0-9
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;range;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        #expect(s.stringToSign == """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
            """)
        #expect(s.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        #expect(s.headers["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func putObject() {
        let body = "Welcome to Amazon S3."
        let hash = SigV4.sha256Hex(body)
        #expect(hash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let s = SigV4.sign(method: "PUT", host: host, canonicalUri: "/" + SigV4.encodeKey("test$file.text"),
                           headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
                           payloadHash: hash, region: "us-east-1", credentials: exampleCreds, date: exampleDate)
        #expect(s.canonicalRequest.hasPrefix("PUT\n/test%24file.text\n\n"))
        #expect(s.stringToSign.hasSuffix("9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"))
        #expect(s.signature == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test func getBucketLifecycle() {
        let s = SigV4.sign(method: "GET", host: host, canonicalUri: "/", query: ["lifecycle": ""],
                           region: "us-east-1", credentials: exampleCreds, date: exampleDate)
        #expect(s.canonicalRequest.hasPrefix("GET\n/\nlifecycle=\n"))
        #expect(s.signature == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    @Test func listObjects() {
        let s = SigV4.sign(method: "GET", host: host, canonicalUri: "/", query: ["prefix": "J", "max-keys": "2"],
                           region: "us-east-1", credentials: exampleCreds, date: exampleDate)
        #expect(s.canonicalRequest.hasPrefix("GET\n/\nmax-keys=2&prefix=J\n"))
        #expect(s.signature == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func sessionTokenIsSigned() {
        var c = exampleCreds
        c.sessionToken = "tok"
        let s = SigV4.sign(method: "GET", host: host, canonicalUri: "/", region: "us-east-1", credentials: c, date: exampleDate)
        #expect(s.headers["x-amz-security-token"] == "tok")
        #expect(s.canonicalRequest.contains("x-amz-security-token:tok\n"))
        #expect(s.headers["Authorization"]?.contains("x-amz-date;x-amz-security-token") == true)
    }
}

@Suite struct SigV4Encoding {
    @Test func rfc3986() {
        #expect(SigV4.encodeRfc3986("a b") == "a%20b")
        #expect(SigV4.encodeRfc3986("!'()*") == "%21%27%28%29%2A")
        #expect(SigV4.encodeRfc3986("-_.~") == "-_.~")
        #expect(SigV4.encodeRfc3986("é") == "%C3%A9")
        #expect(SigV4.encodeRfc3986("a/b") == "a%2Fb")
    }

    @Test func keysKeepSlashes() {
        #expect(SigV4.encodeKey("dir/sub dir/file+1.txt") == "dir/sub%20dir/file%2B1.txt")
        #expect(SigV4.encodeKey("a//b/") == "a//b/")
    }

    @Test func queryOrder() {
        #expect(SigV4.canonicalQuery(["prefix": "a/b", "list-type": "2", "delimiter": "/", "gone": nil])
                == "delimiter=%2F&list-type=2&prefix=a%2Fb")
        #expect(SigV4.canonicalQuery([:]) == "")
    }
}

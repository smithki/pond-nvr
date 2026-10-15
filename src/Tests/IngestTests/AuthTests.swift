import Testing
@testable import Ingest

@Suite struct AuthTests {
    @Test func md5Vectors() {   // RFC 1321, appendix A.5
        #expect(MD5.hex("") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MD5.hex("message digest") == "f96b697d7cb7938d525a2f31aaf161d0")
        #expect(MD5.hex(String(repeating: "1234567890", count: 8)) == "57edf4a22be3c955ac49da2e2107b67a")
    }

    // RFC 2617, section 3.5.
    @Test func digestWithQopMatchesTheRFC() throws {
        let challenge = try #require(AuthChallenge.parse([
            #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#,
        ]))
        let header = challenge.authorization(method: "GET", uri: "/dir/index.html", username: "Mufasa",
                                             password: "Circle Of Life", nc: 1, cnonce: "0a4f113b")
        #expect(header.contains(#"response="6629fae49393a05397450978507c4ef1""#))
        #expect(header.contains("qop=auth, nc=00000001"))
        #expect(header.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
    }

    // What the Reolink camera sends: no qop.
    @Test func reolinkChallenge() throws {
        let challenge = try #require(AuthChallenge.parse([#"Digest realm="BC Streaming Media", nonce="f3afaad5877e3fa5688753ef459c64bb""#]))
        #expect(challenge == .digest(realm: "BC Streaming Media", nonce: "f3afaad5877e3fa5688753ef459c64bb", qop: nil, opaque: nil))
        let url = "rtsp://192.168.1.41:554/h264Preview_01_main"
        let header = challenge.authorization(method: "DESCRIBE", uri: url, username: "admin", password: "pw")
        let ha1 = MD5.hex("admin:BC Streaming Media:pw"), ha2 = MD5.hex("DESCRIBE:\(url)")
        #expect(header == #"Digest username="admin", realm="BC Streaming Media", nonce="f3afaad5877e3fa5688753ef459c64bb", uri="\#(url)", response="\#(MD5.hex("\(ha1):f3afaad5877e3fa5688753ef459c64bb:\(ha2)"))""#)
    }

    @Test func digestPreferredOverBasic() {
        let c = AuthChallenge.parse([#"Basic realm="cam""#, #"Digest realm="cam", nonce="n1""#])
        #expect(c == .digest(realm: "cam", nonce: "n1", qop: nil, opaque: nil))
        #expect(AuthChallenge.parse([#"Basic realm="cam""#]) == .basic(realm: "cam"))
        #expect(AuthChallenge.basic(realm: "cam").authorization(method: "DESCRIBE", uri: "x", username: "admin", password: "pw")
            == "Basic YWRtaW46cHc=")
    }
}

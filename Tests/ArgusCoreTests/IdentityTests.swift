import Foundation
import Testing
import ArgusCore

@Suite struct IdentityTests {
    @Test func `sha256Hex is lowercase hex`() {
        #expect(sha256Hex(utf8("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func `keys and file ids per tool`() {
        let claude = Identity.claude(email: "A@B.com", organizationUuid: "org", refreshToken: "test-refresh-1")
        #expect(claude.email == "a@b.com")
        #expect(claude.key == "claude:a@b.com:org")
        #expect(claude.fileID == sha256Hex(utf8("claude:a@b.com:org")))
        #expect(claude.incompleteFingerprint == nil)
        #expect(Identity.codex(email: "x@y.z", accountID: "acct", refreshToken: nil).key == "codex:x@y.z:acct")
        let agy = Identity.agy(subject: "sub", email: "E@x.com", refreshToken: nil)
        #expect(agy.key == "agy:sub")
        #expect(agy.isComplete)
        #expect(AccountKey(tool: .agy, id: agy.fileID) == AccountKey(tool: .agy, id: sha256Hex(utf8("agy:sub"))))
    }

    @Test func `REQ/F01-AC-1.c8 an incomplete identity is keyed by its refresh token fingerprint and never equals a complete one`() {
        let incomplete = Identity.claude(email: "a@b.com", organizationUuid: nil, refreshToken: "test-refresh-1")
        #expect(!incomplete.isComplete)
        #expect(incomplete.incompleteFingerprint == sha256Hex(utf8("test-refresh-1")))
        #expect(incomplete.key == "claude:incomplete:" + sha256Hex(utf8("test-refresh-1")))
        #expect(incomplete != Identity.claude(email: "a@b.com", organizationUuid: "org", refreshToken: "test-refresh-1"))
        #expect(!Identity.agy(subject: nil, email: "a@b.com", refreshToken: "r").isComplete)
        #expect(!Identity.codex(email: "a@b.com", accountID: "", refreshToken: "r").isComplete)
    }

    @Test func `identities round-trip through Codable`() throws {
        let id = Identity.codex(email: "a@b.com", accountID: "acct", refreshToken: nil)
        #expect(try JSONDecoder().decode(Identity.self, from: JSONEncoder().encode(id)) == id)
    }

    @Test func `tokenSet parses each tool's credential`() {
        let claude = tokenSet(.claude, bytes: utf8(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1000}}"#))
        #expect(claude == TokenSet(accessToken: "a", accessTokenExpiry: Date(timeIntervalSince1970: 1), refreshToken: "r"))
        let access = testJWT(["exp": 2000])
        let codex = tokenSet(.codex, bytes: utf8(#"{"auth_mode":"chatgpt","tokens":{"access_token":"\#(access)","refresh_token":"r"}}"#))
        #expect(codex == TokenSet(accessToken: access, accessTokenExpiry: Date(timeIntervalSince1970: 2000), refreshToken: "r"))
        let agyJSON = #"{"token":{"access_token":"a","refresh_token":"r","expiry":"2026-01-01T00:00:00Z"}}"#
        let agy = tokenSet(.agy, bytes: utf8("go-keyring-base64:" + Data(agyJSON.utf8).base64EncodedString()))
        #expect(agy?.accessTokenExpiry == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(tokenSet(.claude, bytes: utf8("nope")) == nil)
        #expect(tokenSet(.agy, bytes: utf8("go-keyring-base64:@@")) == nil)
    }

    @Test func `agy expiry accepts 0 to 9 fractional digits and offsets`() {
        func expiry(_ s: String) -> Date? {
            let json = #"{"token":{"access_token":"a","refresh_token":"r","expiry":"\#(s)"}}"#
            return tokenSet(.agy, bytes: utf8(json))?.accessTokenExpiry
        }
        #expect(expiry("2026-01-01T00:00:00Z") == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(expiry("2026-01-01T08:00:00.5+08:00") == Date(timeIntervalSince1970: 1_767_225_600.5))
        #expect(expiry("2025-12-31T19:00:00.000000001-05:00")!.timeIntervalSince1970 - 1_767_225_600 < 0.001)
        #expect(expiry("2026-01-01 00:00:00") == nil)
    }
}

@Suite struct DateParsingTests {
    @Test func `non-ASCII digits and malformed offsets parse as no date instead of crashing`() {
        func expiry(_ s: String) -> Date? {
            tokenSet(.agy, bytes: utf8(#"{"token":{"access_token":"a","refresh_token":"r","expiry":"\#(s)"}}"#))?.accessTokenExpiry
        }
        #expect(expiry("٢٠٢٦-01-01T00:00:00Z") == nil)
        #expect(expiry("2026-01-01T00:00:00+٠٨:٠٠") == nil)
        #expect(expiry("2026-01-01T00:00:00+08") == nil)
        #expect(expiry("2026-01-01T00:00:00.٥Z") == nil)
        #expect(expiry("2026-01-01T00:00:00-01:30") == Date(timeIntervalSince1970: 1_767_225_600 + 5400))
    }
}

@testable import TildeCore
import Foundation
import Testing

struct TProxyTests {
    @Test func aNodeTypeComesFromUname() {
        #expect(TProxy.Target(uname: "Darwin arm64\n") == .darwinArm64)
        #expect(TProxy.Target(uname: "Darwin x86_64") == .darwinAmd64)
        #expect(TProxy.Target(uname: "Linux x86_64") == .linuxAmd64)
        #expect(TProxy.Target(uname: "Linux aarch64") == .linuxArm64)
        #expect(TProxy.Target(uname: "Linux arm64") == .linuxArm64)
        #expect(TProxy.Target(uname: "FreeBSD amd64") == nil)
        #expect(TProxy.Target(uname: "Linux armv7l") == nil)
        #expect(TProxy.Target(uname: "") == nil)
    }
}

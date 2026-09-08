import XCTest

@testable import fluse_runtime

/// Dart / Kotlin 実装と**同じファイル**を読んで検証する。
///
/// どれか1つだけを直しても、他の実装のテストが落ちる。ワイヤ表現が
/// ずれたまま気づかない事態を防ぐための唯一の共有仕様。
///
/// **テストリソースはコピーしない。** `#filePath` を起点に
/// `packages/fluse_protocol/test/fixtures/wire_golden.json` を直接読む。
/// コピーすると原本と乖離するため。
final class WireGoldenTests: XCTestCase {
    private lazy var golden: [String: Any] = {
        let url = Self.goldenURL
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("ゴールデンが見つかりません: \(url.path)")
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("ゴールデンが JSON オブジェクトではありません: \(url.path)")
            return [:]
        }
        return json
    }()

    /// このファイル（`ios/Tests/fluse_runtimeTests/WireGoldenTests.swift`）から
    /// `packages/fluse_protocol/test/fixtures/wire_golden.json` への相対パス。
    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WireGoldenTests.swift を除いた fluse_runtimeTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ios/
            .deletingLastPathComponent() // fluse_runtime/
            .deletingLastPathComponent() // packages/
            .appendingPathComponent("fluse_protocol/test/fixtures/wire_golden.json")
            .standardizedFileURL
    }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    private func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func each(_ key: String, _ body: ([String: Any]) throws -> Void) rethrows {
        guard let array = golden[key] as? [Any] else {
            XCTFail("ゴールデンに \(key) がありません")
            return
        }
        for entry in array {
            guard let object = entry as? [String: Any] else {
                XCTFail("\(key) の要素がオブジェクトではありません")
                continue
            }
            try body(object)
        }
    }

    /// `messages` から名前で1件引く。
    private func sample(_ name: String) -> [String: Any] {
        guard let array = golden["messages"] as? [Any] else {
            XCTFail("ゴールデンに messages がありません")
            return [:]
        }
        for entry in array {
            guard let object = entry as? [String: Any] else { continue }
            if object["name"] as? String == name {
                return object["json"] as? [String: Any] ?? [:]
            }
        }
        XCTFail("ゴールデンに \(name) がありません")
        return [:]
    }

    /// JSON の値2つを、型の違い（NSNumber の内部表現の違いなど）を
    /// 気にせず等価判定する。org.json の `similar` / Dart の
    /// `Map` の構造的等価に相当する。
    private func jsonValuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (.some(av), .some(bv)):
            if av is NSNull, bv is NSNull { return true }
            if let astr = av as? String, let bstr = bv as? String {
                return astr == bstr
            }
            if let anum = av as? NSNumber, let bnum = bv as? NSNumber {
                let aBool = CFGetTypeID(anum) == CFBooleanGetTypeID()
                let bBool = CFGetTypeID(bnum) == CFBooleanGetTypeID()
                guard aBool == bBool else { return false }
                return anum.isEqual(to: bnum)
            }
            if let aarr = av as? [Any], let barr = bv as? [Any] {
                guard aarr.count == barr.count else { return false }
                for (x, y) in zip(aarr, barr) where !jsonValuesEqual(x, y) {
                    return false
                }
                return true
            }
            if let adict = av as? [String: Any], let bdict = bv as? [String: Any] {
                guard Set(adict.keys) == Set(bdict.keys) else { return false }
                for key in adict.keys where !jsonValuesEqual(adict[key], bdict[key]) {
                    return false
                }
                return true
            }
            return false
        default:
            return false
        }
    }

    func testProtocolVersionMatchesGolden() {
        XCTAssertEqual(golden["protocolVersion"] as? Int, fluseProtocolVersion)
    }

    func testEncodeMatchesGoldenBytes() throws {
        try each("tunnelFrames") { frame in
            let name = frame["name"] as? String ?? "?"
            guard let opcode = TunnelOpcode.tryParseName(frame["opcode"] as? String ?? "") else {
                XCTFail("\(name) の opcode が不明です")
                return
            }
            let streamId = UInt32(truncating: (frame["streamId"] as! NSNumber))
            let built = TunnelFrame(
                opcode: opcode,
                streamId: streamId,
                payload: hexToBytes(frame["payloadHex"] as? String ?? "")
            )

            XCTAssertEqual(
                bytesToHex(try built.encode()),
                frame["bytesHex"] as? String,
                "\(name) の符号化が違います"
            )
        }
    }

    func testDecodeRestoresGoldenBytes() throws {
        try each("tunnelFrames") { frame in
            let name = frame["name"] as? String ?? "?"
            let decoded = try TunnelFrame.decode(hexToBytes(frame["bytesHex"] as? String ?? ""))

            XCTAssertEqual(decoded.opcode.wireName, frame["opcode"] as? String, name)
            XCTAssertEqual(
                decoded.streamId,
                UInt32(truncating: (frame["streamId"] as! NSNumber)),
                name
            )
            XCTAssertEqual(bytesToHex(decoded.payload), frame["payloadHex"] as? String, name)
        }
    }

    func testInvalidTunnelFramesAreRejected() throws {
        try each("invalidTunnelFrames") { frame in
            let name = frame["name"] as? String ?? "?"
            XCTAssertThrowsError(
                try TunnelFrame.decode(hexToBytes(frame["bytesHex"] as? String ?? "")),
                "\(name) が拒否されていません"
            ) { error in
                XCTAssertTrue(error is FluseProtocolException, name)
            }
        }
    }

    func testMessageRoundTripMatchesGolden() {
        each("messages") { sample in
            let name = sample["name"] as? String ?? "?"
            guard let json = sample["json"] as? [String: Any] else {
                XCTFail("\(name) の json がオブジェクトではありません")
                return
            }

            do {
                let message = try FluseMessageDecoder.fromJson(json)
                let encoded = message.toJson()

                // **値は出さない。** helloWithTokens のようにトークンを持つ
                // 標本があり、失敗時に JSON 全体を出すとログへ流れる。
                let mismatchedKeys = (Set(json.keys).union(encoded.keys))
                    .filter { !jsonValuesEqual(json[$0], encoded[$0]) }
                    .sorted()

                XCTAssertTrue(
                    mismatchedKeys.isEmpty,
                    "\(name) の往復が一致しません。食い違うキー: \(mismatchedKeys)"
                )
            } catch {
                XCTFail("\(name) の fromJson が失敗しました: \(error)")
            }
        }
    }

    func testAllMessageTypesAreCoveredByGolden() {
        var covered = Set<String>()
        each("messages") { sample in
            if let json = sample["json"] as? [String: Any], let type = json["type"] as? String {
                covered.insert(type)
            }
        }

        XCTAssertEqual(
            covered,
            [
                "hello", "vmServiceReady", "ready", "log", "error",
                "accept", "reject", "reload", "compileError", "compileOk",
                "ping", "pong", "close",
            ]
        )
    }

    func testInvalidMessagesAreRejected() throws {
        try each("invalidMessages") { sample in
            let name = sample["name"] as? String ?? "?"
            guard let json = sample["json"] as? [String: Any] else {
                XCTFail("\(name) の json がオブジェクトではありません")
                return
            }
            XCTAssertThrowsError(
                try FluseMessageDecoder.fromJson(json),
                "\(name) が拒否されていません"
            ) { error in
                XCTAssertTrue(error is FluseProtocolException, name)
            }
        }
    }

    func testUnknownCodeStillParses() throws {
        // 新しいサーバのコードを古いアプリが受け取っても、文言は表示できる。
        let json = sample("rejectUnknownCode")
        let message = try FluseMessageDecoder.fromJson(json)

        guard let reject = message as? RejectMessage else {
            XCTFail("RejectMessage ではありません: \(message)")
            return
        }
        XCTAssertNil(reject.knownCode)
        XCTAssertEqual(reject.message, "将来の理由")
    }

    func testTokensAreNotInDescription() throws {
        let json = sample("helloWithTokens")
        let message = try FluseMessageDecoder.fromJson(json)

        // 失敗メッセージに description を渡さない。渡すと、漏れている
        // ことを報告するためにトークンをもう一度ログへ出すことになる。
        for field in ["pairingToken", "deviceToken"] {
            guard let value = json[field] as? String else { continue }
            XCTAssertFalse(
                "\(message)".contains(value),
                "\(field) が description に出ています"
            )
        }
    }
}

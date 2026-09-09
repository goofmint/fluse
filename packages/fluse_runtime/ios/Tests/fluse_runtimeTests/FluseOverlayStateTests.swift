import XCTest

@testable import fluse_runtime

/// `FluseOverlayState` が Kotlin 側と同じ入力に同じ結果を返すかを見る。
///
/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseOverlayStateTest.kt`
/// の `FluseOverlayStateTest` クラス部分。
///
/// 同ファイルの `FluseBadgeStateTest` / `FluseErrorOverlayTest` は
/// `FluseBadge` / `FluseErrorOverlay`（Android の `View` に強く依存する
/// `FluseSurfaces` 配下のクラス）を直に動かすテストで、これらのクラス
/// 自体を今回は移植しない（`FluseOverlayState.swift` のヘッダ参照）ため
/// 対応するテストも無い。
final class FluseOverlayStateTests: XCTestCase {
    private func entry(
        severity: DiagnosticSeverity = .error,
        message: String = "型が合いません",
        file: String? = "lib/main.dart",
        line: Int64? = 42,
        col: Int64? = 7
    ) -> DiagnosticEntry {
        DiagnosticEntry(severity: severity, message: message, file: file, line: line, col: col)
    }

    private func shown(
        _ entries: DiagnosticEntry...,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FluseOverlayContent {
        let command = FluseOverlayState.of(CompileErrorMessage(summary: "1件のエラー", diagnostics: entries))
        guard case let .show(content) = command else {
            XCTFail("Show ではありません: \(command)", file: file, line: line)
            return FluseOverlayContent(summary: "", lines: [])
        }
        return content
    }

    func testCompileErrorShowsOverlay() {
        let content = shown(entry())

        XCTAssertEqual("1件のエラー", content.summary)
        XCTAssertEqual(1, content.lines.count)
    }

    func testLocationComesFirstInLine() {
        // 場所が分からないと、赤画面はただ視界を塞ぐだけになる。
        let line = shown(entry()).lines[0]

        XCTAssertTrue(line.contains("lib/main.dart:42:7"), line)
        XCTAssertTrue(line.contains("型が合いません"), line)
    }

    func testKeepsDiagnosticsWithoutLocation() {
        // file が無いだけで表示ごと消えると、原因を追えなくなる。
        let line = shown(entry(file: nil)).lines[0]

        XCTAssertTrue(line.contains(FluseOverlayState.noLocation), line)
        XCTAssertTrue(line.contains("型が合いません"), line)
    }

    func testShowsAsMuchAsPossibleWhenLineOrColMissing() {
        XCTAssertTrue(shown(entry(col: nil)).lines[0].contains("lib/main.dart:42"))
        XCTAssertTrue(shown(entry(line: nil)).lines[0].contains("lib/main.dart"))
    }

    func testSeverityIsDistinguishedByMark() {
        // 赤地の上では色を変えても見分けが付かない。
        XCTAssertEqual("✗", FluseOverlayState.markOf(.error))
        XCTAssertEqual("△", FluseOverlayState.markOf(.warning))
        XCTAssertEqual("・", FluseOverlayState.markOf(.info))
    }

    func testListsAllDiagnosticsWhenMultiple() {
        let content = shown(entry(), entry(message: "未定義の名前", line: 99))

        XCTAssertEqual(2, content.lines.count)
        XCTAssertTrue(content.lines[1].contains("未定義の名前"))
    }

    func testShowsSummaryEvenWhenDiagnosticsEmpty() {
        // 何も出ないと「反映されていないだけ」と区別が付かない。
        let content = shown()

        XCTAssertEqual("1件のエラー", content.summary)
        XCTAssertEqual([], content.lines)
    }

    func testDoesNotShowHostAbsolutePathAsIs() {
        // 端末の画面に開発者の名前や置き場所まで映る。狭い画面では肝心の
        // ファイル名が押し出される。
        let line = shown(entry(file: "/Users/someone/work/app/lib/ui/home.dart")).lines[0]

        XCTAssertTrue(line.contains("lib/ui/home.dart"), line)
        XCTAssertTrue(line.contains(FluseOverlayState.ellipsis), line)
        XCTAssertFalse(line.contains("/Users/someone"), line)
        // どこを直すかは残す。
        XCTAssertTrue(line.contains(":42:7"), line)
    }

    func testStripsFileScheme() {
        let line = shown(entry(file: "file:///Users/someone/app/lib/main.dart")).lines[0]

        XCTAssertFalse(line.contains("file://"), line)
    }

    func testShortPathIsShownAsIs() {
        XCTAssertEqual("lib/main.dart", FluseOverlayState.shorten("lib/main.dart"))
        XCTAssertEqual("a/b/c.dart", FluseOverlayState.shorten("/a/b/c.dart"))
    }

    func testShortensWindowsPathsToo() {
        // frontend_server は動かした側のパスをそのまま返す。
        XCTAssertEqual(
            "\(FluseOverlayState.ellipsis)app/lib/home.dart",
            FluseOverlayState.shorten("C:\\Users\\someone\\work\\app\\lib\\home.dart")
        )
    }

    func testCompileOkHidesAutomatically() {
        // 利用者に閉じさせない。直ったのに赤いままだと直った事に気づけない。
        XCTAssertEqual(FluseOverlayCommand.hide, FluseOverlayState.of(CompileOkMessage()))
    }

    func testUnrelatedMessagesAreIgnored() {
        // reload のたびに消えると、直す前にエラーが読めなくなる。
        XCTAssertEqual(FluseOverlayCommand.ignore, FluseOverlayState.of(ReloadMessage()))
        XCTAssertEqual(FluseOverlayCommand.ignore, FluseOverlayState.of(ReadyMessage()))
    }
}

/// `FluseBadgeState` のうち、View を持たずに確かめられる部分。
///
/// 移植元の `FluseBadgeStateTest` は `FluseBadge`（Android の View）を
/// 組み立てて遷移を見ているため、そのままは移植できない。初期値だけは
/// 意味のある判断なので写した。
final class FluseBadgeStateTests: XCTestCase {
    func testStartsAsConnecting() {
        // 何も出さないと「繋がっていない」ことに気づけない。
        XCTAssertEqual(FluseBadgeState.initial, .connecting)
    }
}

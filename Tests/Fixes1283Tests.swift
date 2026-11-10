import XCTest
@testable import Folio

/// A server's answer over HTTP/2, as URLSession's metrics report it on a
/// real network (the test server, a URLProtocol, reports no protocol).
private final class H2Transaction: URLSessionTaskTransactionMetrics, @unchecked Sendable {
    override var networkProtocolName: String? { "h2" }
}

private final class H2Metrics: URLSessionTaskMetrics, @unchecked Sendable {
    override var transactionMetrics: [URLSessionTaskTransactionMetrics] { [H2Transaction()] }
}

/// 1.28.3: the download crash (10 Nov report).
final class Fixes1283Tests: XCTestCase {
    /// URLSession reports a connection's metrics on its own queue. The
    /// protocol line went from there straight to the manager, which asserts
    /// the main thread: every finished or cancelled connection ended the app.
    func testTheProtocolLineReachesTheManagerOnTheMainThread() {
        let url = URL(string: "https://stub.folio.invalid/E1.mkv")!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-\(UUID().uuidString).mkv")
        let got = expectation(description: "the protocol line, on the main thread")
        let engine = ChunkedDownload(id: UUID(), request: DownloadEngine.Request(url: url, headers: [:], allowCellular: true, unmeteredOnly: false),
                                     file: file, fileName: "E1.mkv", chunks: [], total: nil, ranges: nil, connections: 1) { e in
            guard case .note(let line) = e, line.contains("HTTP/2") else { return }
            XCTAssertTrue(Thread.isMainThread, "events reach the manager on the main thread")
            got.fulfill()
        }
        let task = URLSession.shared.dataTask(with: url)
        DispatchQueue.global().async {
            engine.urlSession(URLSession.shared, task: task, didFinishCollecting: H2Metrics())
        }
        wait(for: [got], timeout: 5)
        try? FileManager.default.removeItem(at: file)
    }
}

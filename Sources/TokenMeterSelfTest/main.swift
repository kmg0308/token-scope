import Darwin
import Foundation
import TokenMeterSelfTestSupport

do {
    try TokenMeterSelfTest.runAll(includeRealScan: CommandLine.arguments.contains("--real-scan"))
    print("TokenMeterSelfTest passed")
} catch {
    print("::error title=TokenMeterSelfTest::\(error)")
    exit(EXIT_FAILURE)
}

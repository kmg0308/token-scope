import Foundation
import TokenMeterSelfTestSupport

try TokenMeterSelfTest.runAll(includeRealScan: CommandLine.arguments.contains("--real-scan"))
print("TokenMeterSelfTest passed")

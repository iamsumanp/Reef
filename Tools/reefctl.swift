// Debug helper for REEF_DEBUG builds:  reefctl dump  → ~/Library/Logs/Reef/windows.txt
import Foundation
let command = CommandLine.arguments.dropFirst().first ?? "dump"
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("io.github.iamsumanp.reef.debug"), object: command, userInfo: nil, deliverImmediately: true)

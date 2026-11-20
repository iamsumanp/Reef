// A stand-in for Xcode's `PreviewsMacros` compiler plugin.
//
// `#Preview { ... }` expands through a plugin that ships only inside Xcode, so a
// Command Line Tools build fails with "plugin for module 'PreviewsMacros' not
// found". Previews are useless outside Xcode anyway, so this stub answers every
// expansion request with nothing. build.sh compiles it and hands it to the
// compiler with `-load-plugin-executable <path>#PreviewsMacros`.
//
// Wire format (swift-syntax, PluginMessages.swift): each message is an 8-byte
// little-endian length followed by that many bytes of JSON.

import Foundation

let input = FileHandle.standardInput
let output = FileHandle.standardOutput

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = input.readData(ofLength: count - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func send(_ json: String) {
    let payload = Data(json.utf8)
    var length = UInt64(payload.count).littleEndian
    output.write(Data(bytes: &length, count: 8))
    output.write(payload)
}

while let header = readExactly(8) {
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    guard let body = readExactly(Int(UInt64(littleEndian: length))),
          let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let kind = message.keys.first
    else { break }

    switch kind {
    case "getCapability":
        send(#"{"getCapabilityResult":{"capability":{"protocolVersion":7,"features":[]}}}"#)
    case "loadPluginLibrary":
        send(#"{"loadPluginLibraryResult":{"loaded":true,"diagnostics":[]}}"#)
    default:
        // expandFreestandingMacro / expandAttachedMacro: expand to nothing.
        send(#"{"expandMacroResult":{"expandedSource":"","diagnostics":[]}}"#)
    }
}

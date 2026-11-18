import Foundation
import CryptoKit
// Печатается только открытый ключ, закрытый не выводится и не передаётся в argv.
let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let data = Data(base64Encoded: text), data.count == 32 || data.count == 64 else {
    FileHandle.standardError.write(Data("Некорректный формат закрытого ключа Sparkle\n".utf8)); exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(data.prefix(32)))
print(key.publicKey.rawRepresentation.base64EncodedString())

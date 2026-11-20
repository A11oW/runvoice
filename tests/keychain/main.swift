import Foundation

precondition(Keychain.isTestBackend, "Keychain должен использовать тестовый backend")

let account = "rv-test-\(UUID().uuidString)"
precondition(Keychain.value(for: account) == nil, "Новый аккаунт должен быть пустым")

Keychain.set("rv-test-secret", for: account)
precondition(Keychain.value(for: account) == "rv-test-secret", "Значение должно читаться из памяти")
precondition(Keychain.value(for: account) != "rv-test-secret\n", "Значение не должно дописываться")

Keychain.set("rv-test-updated", for: account)
precondition(Keychain.value(for: account) == "rv-test-updated", "Значение должно обновляться")

Keychain.delete(account: account)
precondition(Keychain.value(for: account) == nil, "Удалённый аккаунт должен исчезнуть")

print("OK: Keychain test backend")

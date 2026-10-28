import Foundation

@MainActor
private final class EditorBackend {
    var calls: [(String, [String: BackendJSON])] = []
    var response: BackendJSON = .object([
        "uid": .string("test"), "content": .string("before\n"), "revision": .string("r1")
    ])
    var failure: Error?
}

@main
struct ProfileEditorCheck {
    @MainActor static func main() async throws {
        let backend = EditorBackend()
        let model = NativeProfileEditorModel(uid: "test") { command, params in
            backend.calls.append((command, params))
            if let failure = backend.failure { throw failure }
            return backend.response
        }
        await model.load()
        precondition(model.content == "before\n" && !model.isDirty && !model.canSave)
        precondition(backend.calls[0].0 == "native_read_profile" && backend.calls[0].1 == ["uid": .string("test")])
        model.content = "edited\n"
        precondition(model.isDirty && model.canSave)

        backend.response = .object(["saved": .bool(false), "validation": .object(["valid": .bool(false)])])
        await model.save()
        precondition(model.isDirty && model.content == "edited\n" && model.revision == "r1")
        precondition(model.message != nil && model.details?.contains("validation") == true)
        precondition(backend.calls.last?.1 == [
            "uid": .string("test"), "content": .string("edited\n"), "expectedRevision": .string("r1")
        ])

        backend.failure = NativeBackendError.remote(.init(detail: "File changed", code: .string("profile_conflict"), operation: .object(["kind": .string("reload")])))
        await model.save()
        precondition(model.content == "edited\n" && model.isDirty && model.revision == "r1")
        precondition(model.details?.contains("profile_conflict") == true)
        precondition(model.details?.contains("File changed") == true && model.details?.contains("operation") == true)
        let beforeLoadFailure = backend.calls.count
        await model.load()
        precondition(backend.calls.count == beforeLoadFailure + 1 && model.content == "edited\n" && model.isDirty)

        backend.failure = nil
        backend.response = .object(["saved": .bool(true), "revision": .string("r2"), "validation": .object(["valid": .bool(true)])])
        await model.save()
        precondition(!model.isDirty && model.saved && model.revision == "r2")
        precondition(model.details?.contains("valid") == true)

        model.content = "more edits"
        backend.response = .object(["saved": .bool(true)])
        await model.save()
        precondition(model.isDirty && model.content == "more edits" && model.revision == nil && !model.canSave)
        backend.response = .object(["uid": .string("other"), "content": .string("wrong file"), "revision": .string("r3")])
        await model.load()
        precondition(model.content == "more edits" && model.isDirty && model.revision == nil)
        backend.response = .object(["uid": .string("test"), "content": .string("fresh"), "revision": .string("r3")])
        await model.load()
        precondition(model.content == "fresh" && !model.isDirty && model.revision == "r3")
        print("Profile editor checks passed")
    }
}

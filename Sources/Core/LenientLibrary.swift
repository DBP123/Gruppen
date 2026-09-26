import Foundation

/// Loads a saved array without letting one bad entry take the rest with it.
///
/// ## Why this exists
///
/// Every library in Gruppen is a JSON array decoded in one call —
/// `try? JSONDecoder().decode([Script].self, from: data)` and its three
/// siblings. That is all-or-nothing by construction: `Decodable` on an array
/// fails the *array* when any element fails, and the `try?` then turns that
/// failure into `nil`, which every loader reads as "there was nothing here".
///
/// Measured before this existed: a scripts file holding one entry written by an
/// older build and one written by the current one loaded **zero** scripts. The
/// user's whole library disappeared, silently, and the next save wrote the
/// empty array back over it.
///
/// The individual models are lenient now, which removes the common cause. This
/// removes the failure mode: whatever a single entry turns out to be — written
/// by a newer build, hand-edited into invalidity, truncated by a disk that
/// filled up — it costs that one entry and nothing else.
enum LenientLibrary {
    struct Result<T> {
        var items: [T]
        /// How many entries could not be read. Non-zero means the file held
        /// something this build could not make sense of, which is worth saying
        /// out loud rather than quietly dropping.
        var skipped: Int
    }

    /// Decodes `[T]`, element by element only if it has to.
    ///
    /// The whole-array attempt comes first and succeeds on every well-formed
    /// file, so the common path costs exactly what it did before. The
    /// element-wise pass runs only once something has already gone wrong.
    static func decode<T: Decodable>(_ type: T.Type,
                                     from data: Data,
                                     decoder: JSONDecoder = JSONDecoder()) -> Result<T> {
        if let all = try? decoder.decode([T].self, from: data) {
            return Result(items: all, skipped: 0)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let elements = parsed as? [Any] else {
            // Not an array at all — a truncated or hand-mangled file. There is
            // nothing to salvage element-wise.
            return Result(items: [], skipped: 0)
        }

        var items: [T] = []
        var skipped = 0
        for element in elements {
            // Re-serialised **wrapped in an array**, not on its own.
            // `JSONSerialization.data(withJSONObject:)` raises an ObjC
            // exception — not a Swift error, so `try?` cannot catch it and the
            // process dies — for any top-level fragment. A corrupt file whose
            // array holds a bare string or number is exactly that case, and it
            // is the case this whole type exists to survive. A one-element
            // array is always a legal top-level container.
            guard let blob = try? JSONSerialization.data(withJSONObject: [element]),
                  let decoded = try? decoder.decode([T].self, from: blob),
                  let first = decoded.first else {
                skipped += 1
                continue
            }
            items.append(first)
        }
        return Result(items: items, skipped: skipped)
    }

    /// Reads a file and decodes it. A missing file is empty, not an error —
    /// that is simply the first launch.
    ///
    /// Main-actor because it logs, and the log is the point: a silent skip is
    /// the behaviour this type was written to remove.
    @MainActor
    static func load<T: Decodable>(_ type: T.Type,
                                   from url: URL,
                                   decoder: JSONDecoder = JSONDecoder(),
                                   label: String) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let result = decode(type, from: data, decoder: decoder)
        if result.skipped > 0 {
            GroupStore.log("\(label): kept \(result.items.count), "
                           + "skipped \(result.skipped) unreadable entr\(result.skipped == 1 ? "y" : "ies")")
        }
        return result.items
    }
}

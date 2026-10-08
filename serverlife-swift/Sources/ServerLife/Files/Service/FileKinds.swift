import Foundation

/// Kinds of file, by extension — what colours a building in the 3D view
/// (src/main/filekinds.js). Shared by the scanner and the views so the two can
/// never disagree about what a `.tgz` is.
enum FileKinds {
    static let kinds: [(kind: String, exts: String)] = [
        ("code", "js mjs cjs ts tsx jsx py go rs c h cc cpp hpp java kt rb php sh bash zsh swift m cs scala lua pl r sql vue svelte css scss html htm"),
        ("config", "json yaml yml toml ini conf cfg xml env properties plist service tf hcl lock"),
        ("docs", "md txt rst pdf doc docx odt rtf xls xlsx csv tsv ppt pptx key pages numbers tex epub"),
        ("images", "png jpg jpeg gif svg webp ico bmp tif tiff heic psd raw ai"),
        ("media", "mp4 mov mkv avi webm mp3 wav flac aac ogg m4a m4v"),
        ("archives", "zip gz tgz tar bz2 xz 7z rar zst dmg iso pkg deb rpm jar war whl"),
        ("logs", "log out err journal"),
        ("data", "db sqlite sqlite3 parquet avro bin dat img qcow2 vmdk vdi pack idx"),
        ("binaries", "so dylib dll exe o a class pyc node wasm"),
        ("secrets", "pem crt cer pub p12 pfx jks gpg asc"),
    ]

    /// The kind names, in the order above.
    static var names: [String] { kinds.map(\.kind) }

    /// extension → kind; the first kind to list an extension wins.
    static let extKind: [String: String] = {
        var m: [String: String] = [:]
        for (kind, list) in kinds {
            for ext in list.split(separator: " ") where m[String(ext)] == nil { m[String(ext)] = kind }
        }
        return m
    }()

    /// The extension the scanner groups by: lower case, short, or "" for none.
    static func extOf(_ name: String) -> String {
        let base = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex, base.index(after: dot) != base.endIndex else { return "" }
        let ext = base[base.index(after: dot)...].lowercased()
        // Rotated logs: syslog.1, app.log.3 — a number is not a file type.
        if ext.allSatisfy({ $0.isASCII && $0.isNumber }) { return extOf(String(base[..<dot])) == "log" ? "log" : "" }
        return ext.count <= 10 ? ext : ""
    }

    static func kindOf(_ name: String) -> String { extKind[extOf(name)] ?? "other" }
}

import ArgumentParser
import CelestiaCatalogParser
import Foundation

@main
struct CelestiaCatalogParserApp: ParsableCommand {
    @Argument(help: "The directory path to scan for .dsc, .stc, and .ssc files.")
    var directoryPath: String

    @Option(help: "File path to write extracted object paths to.")
    var objectsOutput: String?

    @Option(help: "File path to write unrecognized lines to.")
    var unrecognizedOutput: String?

    mutating func run() throws {
        let fm = FileManager.default
        let targetExtensions: Set<String> = ["dsc", "stc", "ssc"]

        guard let enumerator = fm.enumerator(atPath: directoryPath) else {
            throw ValidationError("Cannot enumerate directory at \(directoryPath)")
        }

        var allPaths = [String]()
        var allUnrecognized = [(file: String, line: String)]()

        while let relativePath = enumerator.nextObject() as? String {
            let ext = (relativePath as NSString).pathExtension.lowercased()
            if targetExtensions.contains(ext) {
                let fullPath = (directoryPath as NSString).appendingPathComponent(relativePath)
                guard let data = fm.contents(atPath: fullPath) else { continue }
                let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
                
                guard let validContent = content else {
                    continue
                }
                let result = CatalogObjectPathExtractor.extractObjectPaths(from: validContent)
                if !result.objectPaths.isEmpty {
                    print("--- \(relativePath) ---")
                    for path in result.objectPaths {
                        print(path)
                    }
                }
                allPaths.append(contentsOf: result.objectPaths)
                for line in result.unrecognizedLines {
                    allUnrecognized.append((file: relativePath, line: line))
                }
            }
        }

        print("\n=== Total: \(allPaths.count) object paths ===")

        if let objectsOutput {
            let content = allPaths.joined(separator: "\n")
            try content.write(toFile: objectsOutput, atomically: true, encoding: .utf8)
            print("Object paths written to \(objectsOutput)")
        }

        if !allUnrecognized.isEmpty {
            print("\n⚠️  \(allUnrecognized.count) unrecognized line(s):")
            for entry in allUnrecognized {
                print("  [\(entry.file)] \(entry.line)")
            }
        }

        if let unrecognizedOutput {
            let lines = allUnrecognized.map { "[\($0.file)] \($0.line)" }
            let content = lines.joined(separator: "\n")
            try content.write(toFile: unrecognizedOutput, atomically: true, encoding: .utf8)
            print("Unrecognized lines written to \(unrecognizedOutput)")
        }
    }
}

import Foundation

public struct CatalogParseResult: Sendable {
    public let objectPaths: [String]
    public let unrecognizedLines: [String]
}

public enum CatalogObjectPathExtractor {
    public static func extractObjectPaths(from content: String) -> CatalogParseResult {
        var results = [String]()
        var unrecognizedLines = [String]()
        var braceDepth = 0

        // Pre-process: join lines with unclosed quotes into single logical lines
        let rawLines = content.components(separatedBy: .newlines)
        var logicalLines = [String]()
        var accumulator = ""
        var inOpenQuote = false

        for rawLine in rawLines {
            if inOpenQuote {
                // Continue accumulating into the previous logical line
                accumulator += rawLine
            } else {
                accumulator = rawLine
            }

            // Count unescaped quote marks to determine if quote is still open
            let quoteCount = accumulator.filter({ $0 == "\"" }).count
            inOpenQuote = quoteCount % 2 != 0

            if !inOpenQuote {
                logicalLines.append(accumulator)
                accumulator = ""
            }
        }
        // If file ends mid-quote, add whatever we have
        if !accumulator.isEmpty {
            logicalLines.append(accumulator)
        }
        for line in logicalLines {
            // Strip comments: remove everything from the first '#' onward,
            // but ONLY if the '#' is not inside a quoted string.
            var effectiveLine = ""
            var inCommentStrippingQuote = false

            for char in line {
                if char == "\"" {
                    inCommentStrippingQuote.toggle()
                }
                if char == "#" && !inCommentStrippingQuote {
                    break
                }
                effectiveLine.append(char)
            }

            let trimmed = effectiveLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            // Count braces in this line to track depth
            let openCount = trimmed.filter({ $0 == "{" }).count
            let closeCount = trimmed.filter({ $0 == "}" }).count

            let lowerTrimmed = trimmed.lowercased()

            if braceDepth == 0 {
                // Standalone braces (or start of properties like "{ Radius...") — not a new entry
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("}") {
                    braceDepth += openCount - closeCount
                    if braceDepth < 0 { braceDepth = 0 }
                    continue
                }

                // Location and Barycenter entries are not relevant, skip entirely
                if lowerTrimmed.hasPrefix("location") || lowerTrimmed.hasPrefix("barycenter") {
                    braceDepth += openCount - closeCount
                    if braceDepth < 0 { braceDepth = 0 }
                    continue
                }

                // For extraction, ignore everything after the first '{' (outside quotes)
                var extractionLine = trimmed
                var quoteOpen = false
                for (index, char) in trimmed.enumerated() {
                    if char == "\"" { quoteOpen.toggle() }
                    if char == "{" && !quoteOpen {
                        extractionLine = String(trimmed.prefix(index))
                        break
                    }
                }
                let extractionTrimmed = extractionLine.trimmingCharacters(in: .whitespaces)

                // AltSurface "SurfaceName" "ObjectPath": ignore the surface
                // label (first quoted string), extract only the object path (last)
                if lowerTrimmed.hasPrefix("altsurface") {
                    let quotedStrings = extractQuotedStrings(from: extractionTrimmed)
                    if quotedStrings.count >= 2 {
                        let path = quotedStrings[quotedStrings.count - 1]
                        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedPath.isEmpty {
                            results.append(trimmedPath)
                        }
                    } else {
                        unrecognizedLines.append(trimmed)
                    }
                    braceDepth += openCount - closeCount
                    if braceDepth < 0 { braceDepth = 0 }
                    continue
                }

                // "Modify 12527" or "Replace 12527": bare HIP number after keyword
                if lowerTrimmed.hasPrefix("modify") || lowerTrimmed.hasPrefix("replace") {
                    let parts = trimmed.split(separator: " ", maxSplits: 2)

                    // Case: "Modify Barycenter ..." -> Ignore (since we ignore Barycenter)
                    if parts.count >= 2 && parts[1].lowercased() == "barycenter" {
                        braceDepth += openCount - closeCount
                        if braceDepth < 0 { braceDepth = 0 }
                        continue
                    }

                    // Case: Standalone "Modify" or "Replace" -> Ignore
                    if parts.count == 1 {
                        braceDepth += openCount - closeCount
                        if braceDepth < 0 { braceDepth = 0 }
                        continue
                    }

                    var handled = false
                    
                    if parts.count >= 2, let hipNumber = Int(parts[1]) {
                        results.append("HIP \(hipNumber)")
                        handled = true
                    }

                    // If followed by quoted strings (e.g. Replace "Path" { ... }),
                    // the first quoted string is the object path. Ignore subsequent strings
                    // (like properties "Texture", "SpectralType") on the same line.
                    let quoted = extractQuotedStrings(from: extractionTrimmed)
                    if !quoted.isEmpty {
                        if quoted.count >= 2 {
                            var parentPath = quoted[quoted.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                            while parentPath.hasSuffix("/") { parentPath.removeLast() }
                            
                            let nameSplit = quoted[quoted.count - 2].split(separator: ":")
                            let name = nameSplit.first ?? ""
                            
                            if !name.hasPrefix(" ") {
                                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                if name.isEmpty {
                                    if !parentPath.isEmpty && !parentPath.hasPrefix(" ") && !parentPath.contains("/ ") {
                                        results.append(parentPath)
                                    }
                                } else if !trimmedName.isEmpty {
                                    if !parentPath.hasPrefix(" ") && !parentPath.contains("/ ") {
                                        let fullPath = parentPath.isEmpty ? trimmedName : "\(parentPath)/\(trimmedName)"
                                        results.append(fullPath)
                                    }
                                }
                            }
                        } else {
                            if let name = quoted[0].split(separator: ":").first {
                                if !name.hasPrefix(" ") {
                                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmedName.isEmpty {
                                        results.append(trimmedName)
                                    }
                                }
                            }
                        }
                        handled = true
                    }
                    
                    if handled {
                        braceDepth += openCount - closeCount
                        if braceDepth < 0 { braceDepth = 0 }
                        continue
                    }
                    
                    // If not a bare number and no quoted strings, fall through
                    // (though this shouldn't happen for valid Modify statements)
                }

                // Extract quoted strings at the top level
                let quotedStrings = extractQuotedStrings(from: extractionTrimmed)
                if quotedStrings.count >= 2 {
                    // Second-to-last quoted string: object names (colon-separated)
                    // Last quoted string: parent path
                    var parentPath = quotedStrings[quotedStrings.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    while parentPath.hasSuffix("/") { parentPath.removeLast() }

                    let nameSplit = quotedStrings[quotedStrings.count - 2].split(separator: ":")
                    let name = nameSplit.first ?? ""
                    
                    if !name.hasPrefix(" ") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

                        if name.isEmpty {
                            if !parentPath.isEmpty && !parentPath.hasPrefix(" ") && !parentPath.contains("/ ") {
                                results.append(parentPath)
                            }
                        } else if !trimmedName.isEmpty {
                            if !parentPath.hasPrefix(" ") && !parentPath.contains("/ ") {
                                let fullPath = parentPath.isEmpty ? trimmedName : "\(parentPath)/\(trimmedName)"
                                results.append(fullPath)
                            }
                        }
                    }
                } else if quotedStrings.count == 1 {
                    // No parent path, just object names
                    if let name = quotedStrings[0].split(separator: ":").first {
                        if !name.hasPrefix(" ") {
                            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmedName.isEmpty {
                                results.append(trimmedName)
                            }
                        }
                    }
                } else if quotedStrings.isEmpty {
                    // Bare HIP number (e.g. "70890" from "70890 # Proxima Cen")
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    if let hipNumber = Int(parts[0]) {
                        results.append("HIP \(hipNumber)")
                    } else {
                        unrecognizedLines.append(trimmed)
                    }
                }
            }

            braceDepth += openCount - closeCount
            if braceDepth < 0 { braceDepth = 0 }
        }

        return CatalogParseResult(objectPaths: results, unrecognizedLines: unrecognizedLines)
    }

    private static func extractQuotedStrings(from text: String) -> [String] {
        var results = [String]()
        var inQuote = false
        var current = ""

        for char in text {
            if char == "\"" {
                if inQuote {
                    results.append(current)
                    current = ""
                }
                inQuote.toggle()
            } else if inQuote {
                current.append(char)
            }
        }

        return results
    }
}

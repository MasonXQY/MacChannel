import Foundation

struct SwiftPasteboardGeneralAccess: Equatable {
    enum Kind: Equatable {
        case explicitNSPasteboard
        case shorthandOrOtherMember
    }

    let path: String
    let tokenOffset: Int
    let kind: Kind
}

enum SwiftPasteboardSourceAuditor {
    static func accesses(in source: String) -> [SwiftPasteboardGeneralAccess] {
        accesses(in: ["fixture.swift": source])
    }

    static func accesses(in sources: [String: String]) -> [SwiftPasteboardGeneralAccess] {
        sources.keys.sorted().flatMap { path -> [SwiftPasteboardGeneralAccess] in
            guard let source = sources[path] else { return [] }
            return accesses(in: SwiftSourceLexer.tokenize(source), path: path)
        }
    }

    static func satisfiesFailClosedPolicy(
        in sources: [String: String],
        allowingSingleExplicitAccessAt allowedPath: String
    ) -> Bool {
        let detectedAccesses = accesses(in: sources)
        return detectedAccesses.count == 1
            && detectedAccesses[0].path == allowedPath
            && detectedAccesses[0].kind == .explicitNSPasteboard
    }

    private static func accesses(
        in tokens: [SwiftSourceToken],
        path: String
    ) -> [SwiftPasteboardGeneralAccess] {
        var accesses: [SwiftPasteboardGeneralAccess] = []

        for index in tokens.indices {
            guard token(tokens, at: index, isSymbol: "."),
                  token(tokens, at: index + 1, isIdentifier: "general")
            else { continue }
            accesses.append(
                SwiftPasteboardGeneralAccess(
                    path: path,
                    tokenOffset: tokens[index].offset,
                    kind: token(tokens, at: index - 1, isIdentifier: "NSPasteboard")
                        ? .explicitNSPasteboard
                        : .shorthandOrOtherMember
                )
            )
        }
        return accesses
    }

    private static func token(
        _ tokens: [SwiftSourceToken],
        at index: Int,
        isIdentifier expected: String
    ) -> Bool {
        guard tokens.indices.contains(index), case let .identifier(value) = tokens[index].kind
        else { return false }
        return value == expected
    }

    private static func token(
        _ tokens: [SwiftSourceToken],
        at index: Int,
        isSymbol expected: Character
    ) -> Bool {
        guard tokens.indices.contains(index), case let .symbol(value) = tokens[index].kind
        else { return false }
        return value == expected
    }
}

enum SwiftPackageProductionSourceInventory {
    static func sourceRoots(from manifest: String) -> [String] {
        let tokens = SwiftSourceLexer.tokenize(manifest)
        var roots: Set<String> = []
        var index = 0

        while index + 2 < tokens.count {
            guard case .symbol(".") = tokens[index].kind,
                  case let .identifier(targetKind) = tokens[index + 1].kind,
                  targetKind == "target" || targetKind == "executableTarget",
                  case .symbol("(") = tokens[index + 2].kind,
                  let closeIndex = closingParenthesis(in: tokens, openingAt: index + 2)
            else {
                index += 1
                continue
            }
            let fields = topLevelStringFields(
                in: tokens,
                from: index + 3,
                to: closeIndex
            )
            if let name = fields["name"] {
                roots.insert(fields["path"] ?? "Sources/\(name)")
            }
            index = closeIndex + 1
        }
        return roots.sorted()
    }

    private static func closingParenthesis(
        in tokens: [SwiftSourceToken],
        openingAt openingIndex: Int
    ) -> Int? {
        var depth = 0
        for index in openingIndex..<tokens.count {
            if case .symbol("(") = tokens[index].kind { depth += 1 }
            if case .symbol(")") = tokens[index].kind {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func topLevelStringFields(
        in tokens: [SwiftSourceToken],
        from startIndex: Int,
        to endIndex: Int
    ) -> [String: String] {
        var fields: [String: String] = [:]
        var parenthesisDepth = 1
        var index = startIndex
        while index + 2 < endIndex {
            if case .symbol("(") = tokens[index].kind {
                parenthesisDepth += 1
                index += 1
                continue
            }
            if case .symbol(")") = tokens[index].kind {
                parenthesisDepth -= 1
                index += 1
                continue
            }
            if parenthesisDepth == 1,
               case let .identifier(field) = tokens[index].kind,
               case .symbol(":") = tokens[index + 1].kind,
               case let .stringLiteral(value) = tokens[index + 2].kind
            {
                fields[field] = value
                index += 3
                continue
            }
            index += 1
        }
        return fields
    }
}

private struct SwiftSourceToken: Equatable {
    enum Kind: Equatable {
        case identifier(String)
        case symbol(Character)
        case stringLiteral(String)
    }

    let kind: Kind
    let offset: Int
}

private enum SwiftSourceLexer {
    static func tokenize(_ source: String) -> [SwiftSourceToken] {
        let characters = Array(source)
        return scanCode(in: characters, from: 0, untilInterpolationEnd: false).tokens
    }

    private struct CodeScan {
        let tokens: [SwiftSourceToken]
        let endIndex: Int
    }

    private struct StringScan {
        let literalValue: String
        let interpolationTokens: [SwiftSourceToken]
        let endIndex: Int
    }

    private static func scanCode(
        in characters: [Character],
        from start: Int,
        untilInterpolationEnd: Bool
    ) -> CodeScan {
        var tokens: [SwiftSourceToken] = []
        var index = start
        var parenthesisDepth = untilInterpolationEnd ? 1 : 0

        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            if starts(with: ["/", "/"], at: index, in: characters) {
                index += 2
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if starts(with: ["/", "*"], at: index, in: characters) {
                index = skipBlockComment(startingAt: index, in: characters)
                continue
            }
            if let stringScan = scanStringLiteral(startingAt: index, in: characters) {
                tokens.append(
                    SwiftSourceToken(
                        kind: .stringLiteral(stringScan.literalValue),
                        offset: index
                    )
                )
                tokens.append(contentsOf: stringScan.interpolationTokens)
                index = stringScan.endIndex
                continue
            }
            if isIdentifierStart(characters[index]) {
                let start = index
                index += 1
                while index < characters.count, isIdentifierContinuation(characters[index]) {
                    index += 1
                }
                tokens.append(
                    SwiftSourceToken(
                        kind: .identifier(String(characters[start..<index])),
                        offset: start
                    )
                )
                continue
            }

            if untilInterpolationEnd, characters[index] == "(" {
                parenthesisDepth += 1
            } else if untilInterpolationEnd, characters[index] == ")" {
                parenthesisDepth -= 1
                if parenthesisDepth == 0 {
                    return CodeScan(tokens: tokens, endIndex: index + 1)
                }
            }
            tokens.append(
                SwiftSourceToken(kind: .symbol(characters[index]), offset: index)
            )
            index += 1
        }
        return CodeScan(tokens: tokens, endIndex: index)
    }

    private static func skipBlockComment(startingAt start: Int, in source: [Character]) -> Int {
        var index = start + 2
        var depth = 1
        while index < source.count, depth > 0 {
            if starts(with: ["/", "*"], at: index, in: source) {
                depth += 1
                index += 2
            } else if starts(with: ["*", "/"], at: index, in: source) {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    private static func scanStringLiteral(
        startingAt start: Int,
        in source: [Character]
    ) -> StringScan? {
        var quoteIndex = start
        while quoteIndex < source.count, source[quoteIndex] == "#" { quoteIndex += 1 }
        guard quoteIndex < source.count, source[quoteIndex] == "\"" else { return nil }
        let hashCount = quoteIndex - start
        let isMultiline = starts(with: ["\"", "\"", "\""], at: quoteIndex, in: source)
        let quoteCount = isMultiline ? 3 : 1
        let contentStart = quoteIndex + quoteCount
        var index = contentStart
        var literalCharacters: [Character] = []
        var interpolationTokens: [SwiftSourceToken] = []

        while index < source.count {
            if startsWithStringTerminator(
                at: index,
                quoteCount: quoteCount,
                hashCount: hashCount,
                in: source
            ) {
                return StringScan(
                    literalValue: String(literalCharacters),
                    interpolationTokens: interpolationTokens,
                    endIndex: index + quoteCount + hashCount
                )
            }
            if let expressionStart = interpolationExpressionStart(
                at: index,
                hashCount: hashCount,
                in: source
            ) {
                let expression = scanCode(
                    in: source,
                    from: expressionStart,
                    untilInterpolationEnd: true
                )
                interpolationTokens.append(contentsOf: expression.tokens)
                index = expression.endIndex
                continue
            }
            if let escapedEnd = escapedSequenceEnd(
                at: index,
                hashCount: hashCount,
                in: source
            ) {
                literalCharacters.append(contentsOf: source[index..<escapedEnd])
                index = escapedEnd
                continue
            }
            literalCharacters.append(source[index])
            index += 1
        }
        return StringScan(
            literalValue: String(literalCharacters),
            interpolationTokens: interpolationTokens,
            endIndex: source.count
        )
    }

    private static func interpolationExpressionStart(
        at index: Int,
        hashCount: Int,
        in source: [Character]
    ) -> Int? {
        guard index < source.count, source[index] == "\\" else { return nil }
        var cursor = index + 1
        for _ in 0..<hashCount {
            guard cursor < source.count, source[cursor] == "#" else { return nil }
            cursor += 1
        }
        guard cursor < source.count, source[cursor] == "(" else { return nil }
        return cursor + 1
    }

    private static func escapedSequenceEnd(
        at index: Int,
        hashCount: Int,
        in source: [Character]
    ) -> Int? {
        guard index < source.count, source[index] == "\\" else { return nil }
        var cursor = index + 1
        for _ in 0..<hashCount {
            guard cursor < source.count, source[cursor] == "#" else { return nil }
            cursor += 1
        }
        guard cursor < source.count else { return source.count }
        return cursor + 1
    }

    private static func startsWithStringTerminator(
        at index: Int,
        quoteCount: Int,
        hashCount: Int,
        in source: [Character]
    ) -> Bool {
        guard index + quoteCount + hashCount <= source.count else { return false }
        for offset in 0..<quoteCount where source[index + offset] != "\"" { return false }
        for offset in 0..<hashCount where source[index + quoteCount + offset] != "#" {
            return false
        }
        return true
    }

    private static func starts(
        with expected: [Character],
        at index: Int,
        in source: [Character]
    ) -> Bool {
        guard index + expected.count <= source.count else { return false }
        return source[index..<(index + expected.count)].elementsEqual(expected)
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber || character == "$"
    }
}

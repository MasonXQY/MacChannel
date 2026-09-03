import Foundation

struct SwiftPasteboardGeneralAccess: Equatable {
    let path: String
    let tokenOffset: Int
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

    private static func accesses(
        in tokens: [SwiftSourceToken],
        path: String
    ) -> [SwiftPasteboardGeneralAccess] {
        let pasteboardTypedNames = knownPasteboardTypedNames(in: tokens)
        var accesses: [SwiftPasteboardGeneralAccess] = []

        for index in tokens.indices {
            if token(tokens, at: index, isIdentifier: "NSPasteboard"),
               token(tokens, at: index + 1, isSymbol: "."),
               token(tokens, at: index + 2, isIdentifier: "general")
            {
                accesses.append(
                    SwiftPasteboardGeneralAccess(
                        path: path,
                        tokenOffset: tokens[index].offset
                    )
                )
                continue
            }

            guard token(tokens, at: index, isSymbol: "."),
                  token(tokens, at: index + 1, isIdentifier: "general"),
                  token(tokens, at: index - 1, isSymbol: "=")
            else {
                continue
            }
            let equalsIndex = index - 1
            let assignedName = identifierBeforeAssignment(tokens, equalsIndex: equalsIndex)
            if hasPasteboardTypeAnnotation(tokens, equalsIndex: equalsIndex)
                || assignedName.map(pasteboardTypedNames.contains) == true
            {
                accesses.append(
                    SwiftPasteboardGeneralAccess(
                        path: path,
                        tokenOffset: tokens[index].offset
                    )
                )
            }
        }
        return accesses
    }

    private static func knownPasteboardTypedNames(in tokens: [SwiftSourceToken]) -> Set<String> {
        var names: Set<String> = []
        for index in tokens.indices {
            guard case let .identifier(name) = tokens[index].kind,
                  token(tokens, at: index + 1, isSymbol: ":")
            else {
                continue
            }
            var cursor = index + 2
            var isPasteboardType = false
            while tokens.indices.contains(cursor), cursor <= index + 12 {
                if token(tokens, at: cursor, isIdentifier: "NSPasteboard") {
                    isPasteboardType = true
                }
                if isTypeAnnotationBoundary(tokens[cursor]) { break }
                cursor += 1
            }
            if isPasteboardType { names.insert(name) }
        }
        return names
    }

    private static func hasPasteboardTypeAnnotation(
        _ tokens: [SwiftSourceToken],
        equalsIndex: Int
    ) -> Bool {
        var cursor = equalsIndex - 1
        var colonIndex: Int?
        while tokens.indices.contains(cursor), cursor >= max(0, equalsIndex - 16) {
            if isDeclarationBoundary(tokens[cursor]) { break }
            if token(tokens, at: cursor, isSymbol: ":") {
                colonIndex = cursor
                break
            }
            cursor -= 1
        }
        guard let colonIndex else { return false }
        return tokens[(colonIndex + 1)..<equalsIndex].contains { token in
            if case .identifier("NSPasteboard") = token.kind { return true }
            return false
        }
    }

    private static func identifierBeforeAssignment(
        _ tokens: [SwiftSourceToken],
        equalsIndex: Int
    ) -> String? {
        guard tokens.indices.contains(equalsIndex - 1),
              case let .identifier(name) = tokens[equalsIndex - 1].kind
        else {
            return nil
        }
        return name
    }

    private static func isTypeAnnotationBoundary(_ token: SwiftSourceToken) -> Bool {
        switch token.kind {
        case .symbol("="), .symbol(","), .symbol(")"), .symbol(";"),
             .symbol("{"), .symbol("}"):
            true
        default:
            false
        }
    }

    private static func isDeclarationBoundary(_ token: SwiftSourceToken) -> Bool {
        switch token.kind {
        case .symbol(","), .symbol(";"), .symbol("{"), .symbol("}"), .symbol("="):
            true
        default:
            false
        }
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
        var tokens: [SwiftSourceToken] = []
        var index = 0

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
            if let stringToken = stringLiteral(startingAt: index, in: characters) {
                tokens.append(
                    SwiftSourceToken(
                        kind: .stringLiteral(stringToken.value),
                        offset: index
                    )
                )
                index = stringToken.endIndex
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
            tokens.append(
                SwiftSourceToken(kind: .symbol(characters[index]), offset: index)
            )
            index += 1
        }
        return tokens
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

    private static func stringLiteral(
        startingAt start: Int,
        in source: [Character]
    ) -> (value: String, endIndex: Int)? {
        var quoteIndex = start
        while quoteIndex < source.count, source[quoteIndex] == "#" { quoteIndex += 1 }
        guard quoteIndex < source.count, source[quoteIndex] == "\"" else { return nil }
        let hashCount = quoteIndex - start
        let isMultiline = starts(with: ["\"", "\"", "\""], at: quoteIndex, in: source)
        let quoteCount = isMultiline ? 3 : 1
        let contentStart = quoteIndex + quoteCount
        var index = contentStart

        while index < source.count {
            if hashCount == 0, source[index] == "\\" {
                index = min(source.count, index + 2)
                continue
            }
            if startsWithStringTerminator(
                at: index,
                quoteCount: quoteCount,
                hashCount: hashCount,
                in: source
            ) {
                let value = String(source[contentStart..<index])
                return (value, index + quoteCount + hashCount)
            }
            index += 1
        }
        return (String(source[contentStart..<source.count]), source.count)
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

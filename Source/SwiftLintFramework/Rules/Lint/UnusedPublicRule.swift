import Foundation
import SourceKittenFramework

//TODO: Unit test
//      Reduce duplication between this and copied unused decleration rule
//      Remove unused code copied from unused decleration rule


//TODO: Refactor source.lang.swift.ref detection into a method
public struct UnusedPublicRule: AutomaticTestableRule, ConfigurationProviderRule, AnalyzerRule, CollectingRule {
    public struct FileUSRs: Hashable {
        var referenced: Set<RefercencedUSR>
        var declared: Set<DeclaredUSR>

        fileprivate static var empty: FileUSRs { FileUSRs(referenced: [], declared: []) }
    }

    struct DeclaredUSR: Hashable {
        let usr: String
        let module: String
        let nameOffset: ByteCount
        let enclosingUSR: String?
    }
    
    struct RefercencedUSR: Hashable {
        let usr: String
        let module: String
    }
    
    public var configuration = UnusedPublicConfiguration(severity: .error)

    public init() {}

    public static let description = RuleDescription(
        identifier: "unused_public",
        name: "Unused Public",
        description: "Public API should be used externally",
        kind: .lint,
        nonTriggeringExamples: [],//UnusedPublicRuleExamples.nonTriggeringExamples,
        triggeringExamples: [],//UnusedPublicRuleExamples.triggeringExamples,
        requiresFileOnDisk: true
    )

    public func collectInfo(for file: SwiftLintFile, compilerArguments: [String]) -> UnusedPublicRule.FileUSRs {
        guard compilerArguments.isNotEmpty else {
            queuedPrintError("""
                Attempted to lint file at path '\(file.path ?? "...")' with the \
                \(Self.description.identifier) rule without any compiler arguments.
                """)
            return .empty
        }

        guard let index = file.index(compilerArguments: compilerArguments), index.value.isNotEmpty else {
            queuedPrintError("""
                Could not index file at path '\(file.path ?? "...")' with the \
                \(Self.description.identifier) rule.
                """)
            return .empty
        }

        guard let editorOpen = (try? Request.editorOpen(file: file.file).sendIfNotDisabled())
                .map(SourceKittenDictionary.init) else {
            queuedPrintError("""
                Could not open file at path '\(file.path ?? "...")' with the \
                \(Self.description.identifier) rule.
                """)
            return .empty
        }

        return FileUSRs(
            referenced: file.referencedUSRs(index: index, compilerArguments: compilerArguments),
            declared: file.declaredPublicUSRs(index: index,
                                        editorOpen: editorOpen,
                                        compilerArguments: compilerArguments)
        )
    }

    public func validate(file: SwiftLintFile, collectedInfo: [SwiftLintFile: UnusedPublicRule.FileUSRs],
                         compilerArguments: [String]) -> [StyleViolation] {
        let allReferencedUSRs = collectedInfo.values.reduce(into: Set()) { $0.formUnion($1.referenced) }
        return violationOffsets(declaredUSRs: collectedInfo[file]?.declared ?? [],
                                allReferencedUSRs: allReferencedUSRs)
            .map {
                StyleViolation(ruleDescription: Self.description,
                               severity: configuration.severity,
                               location: Location(file: file, byteOffset: $0))
            }
    }

    private func violationOffsets(declaredUSRs: Set<DeclaredUSR>, allReferencedUSRs: Set<RefercencedUSR>) -> [ByteCount] {
        // Unused declarations are:
        // 1. all declarations
        // 2. minus all references whose module are not equal to the declaration
        // 3. minus all references who are overridden(class) or implemented(protocol) in a different module
        
        //TODO: 3. above is too naïve—It assumes if an open class is overridden then all of its open methods are 'used' externally.
        //      It could probably be smarter and deal with class methods on an individual basis and mark them as unused if they're not overridden in the subclass(es)
        return declaredUSRs
            .filter { declaredUSR in
                !allReferencedUSRs.contains(where: {
                                            $0.usr == declaredUSR.usr && $0.module != declaredUSR.module
                }) }
            .filter { declaredUSR in
                !isOverridenOrImplementedExternally(declaredUSR, allReferencedUSRs: allReferencedUSRs)
            }
            .map { $0.nameOffset }
            .sorted()
    }
    
    private func isOverridenOrImplementedExternally(_ declaredUSR: DeclaredUSR, allReferencedUSRs: Set<RefercencedUSR>) -> Bool {
        guard let enclosingUSR = declaredUSR.enclosingUSR else {
            return false
        }
        return allReferencedUSRs.contains(where: {
            $0.usr == enclosingUSR && $0.module != declaredUSR.module
        })
    }
}

// MARK: - File Extensions

private extension SwiftLintFile {
    func index(compilerArguments: [String]) -> SourceKittenDictionary? {
        return path
            .flatMap { path in
                try? Request.index(file: path, arguments: compilerArguments)
                            .send()
            }
            .map(SourceKittenDictionary.init)
    }

    func referencedUSRs(index: SourceKittenDictionary, compilerArguments: [String]) -> Set<UnusedPublicRule.RefercencedUSR> {
        return Set(index.traverseEntities { entity -> UnusedPublicRule.RefercencedUSR? in
            if let usr = entity.usr,
                let kind = entity.kind,
                kind.starts(with: "source.lang.swift.ref") {
                return UnusedPublicRule.RefercencedUSR(usr: usr, module: moduleName(compilerArguments: compilerArguments))
            }

            return nil
        })
    }

    func declaredPublicUSRs(index: SourceKittenDictionary, editorOpen: SourceKittenDictionary,
                      compilerArguments: [String])
        -> Set<UnusedPublicRule.DeclaredUSR> {
        let publicProtocolsAndClasses = index.traverseEntities(traverseBlock: { indexEntity in
            self.publicProtocolsAndClasses(indexEntity: indexEntity, editorOpen: editorOpen)
        })
        let publicUSRs = Set(index.traverseEntities { indexEntity in
            self.declaredPublicUSR(indexEntity: indexEntity, editorOpen: editorOpen, publicProtocolsAndClasses: publicProtocolsAndClasses, compilerArguments: compilerArguments)
        })
        return removeExternallyExposedPublicTypes(from: publicUSRs, index: index, editorOpen: editorOpen)
    }
    
    private func publicProtocolsAndClasses(indexEntity: SourceKittenDictionary, editorOpen: SourceKittenDictionary) -> SourceKittenDictionary? {
        //TODO: Access duplication.  Refactor into method
        guard [.protocol, .class].contains(indexEntity.declarationKind),
              let line = indexEntity.line.map(Int.init),
              let column = indexEntity.column.map(Int.init),
              let access = editorOpen.aclAtOffset(stringView.byteOffset(forLine: line, column: column)),
              [.public, .open].contains(access) else { return  nil }
            return indexEntity
    }
    
    //TODO: WIP Trying to resolve false positives.
    //      Some progress was made in realising that typealiases are only referenced as source.lang.swift.ref with no child entities.
    //      It's not possible to get their access control though so the guard [.public, .open] fails before any special cases can be hit.
    //      I think this means we need to traverse depth first (perhaps via recursion), being more intelligent to determine what is public and collecting any USRs on our way down.
    //      This will probably be more efficient too.
    //      Something like: Start at top level.  If it's private/internal, abort.  If it's got children, continue and report everything mentioned inside a protocol, only things explititly named as public within classes and structs
    private func removeExternallyExposedPublicTypes(from declarations: Set<UnusedPublicRule.DeclaredUSR>, index: SourceKittenDictionary, editorOpen: SourceKittenDictionary) -> Set<UnusedPublicRule.DeclaredUSR> {
        var declarations = declarations
        //Filter out public types which are referenced by another public declaration
        _ = index.traverseEntities { indexEntity in
            print(indexEntity.usr ?? "")
            guard let line = indexEntity.line.map(Int.init),
                  let column = indexEntity.column.map(Int.init),
                  let access = editorOpen.aclAtOffset(stringView.byteOffset(forLine: line, column: column)),
                  [.public, .open].contains(access) else { return }
            var referencedUSRs: [String?] = []
            
            //References don't have child entities.  Add their USRs directly
            if let kind = indexEntity.kind,
               kind.starts(with: "source.lang.swift.ref"),
               let usr = indexEntity.usr {
                referencedUSRs.append(usr)
            } else { //Otherwise add the usrs from the entities array
                let types: [SwiftDeclarationKind] = [.protocol, .struct, .class, .enum, .typealias]
                let entities = indexEntity.entities
                entities.forEach { relatedEntity in
                    guard let kind = relatedEntity.declarationKind,
                          types.contains(kind) else { return }
                    referencedUSRs.append(relatedEntity.usr)
                }
            }
            
            declarations = declarations.filter { !referencedUSRs.contains($0.usr) }
        }
        return declarations
    }

    private func declaredPublicUSR(indexEntity: SourceKittenDictionary, editorOpen: SourceKittenDictionary, publicProtocolsAndClasses: [SourceKittenDictionary],
                     compilerArguments: [String]) -> UnusedPublicRule.DeclaredUSR? {
        guard let stringKind = indexEntity.kind,
              stringKind.starts(with: "source.lang.swift.decl."),
              !stringKind.contains(".accessor."),
              let usr = indexEntity.usr,
              let line = indexEntity.line.map(Int.init),
              let column = indexEntity.column.map(Int.init),
              let kind = indexEntity.declarationKind,
              !declarationKindsToSkip.contains(kind)
        else {
            return nil
        }

        if shouldIgnoreEntity(indexEntity) {
            return nil
        }

        let nameOffset = stringView.byteOffset(forLine: line, column: column)

        if ![.public, .open].contains(editorOpen.aclAtOffset(nameOffset)) {
            return nil
        }
        
        // Skip CodingKeys as they are used for Codable generation
        if kind == .enum,
            indexEntity.name == "CodingKeys",
            case let allRelatedUSRs = indexEntity.traverseEntities(traverseBlock: { $0.usr }),
            allRelatedUSRs.contains("s:s9CodingKeyP") {
            return nil
        }

        // Skip `static var allTests` members since those are used for Linux test discovery.
        if kind == .varStatic, indexEntity.name == "allTests" {
            let allTestCandidates = indexEntity.traverseEntities { subEntity -> Bool in
                subEntity.value["key.is_test_candidate"] as? Bool == true
            }

            if allTestCandidates.contains(true) {
                return nil
            }
        }

        let moduleName = self.moduleName(compilerArguments: compilerArguments)
        let cursorInfo = self.cursorInfo(at: nameOffset, compilerArguments: compilerArguments)

        if let annotatedDecl = cursorInfo?.annotatedDeclaration,
            ["@IBAction", "@objc"].contains(where: annotatedDecl.contains) {
            return nil
        }

        // This works for both subclass overrides & protocol extension overrides.
        if cursorInfo?.value["key.overrides"] != nil {
            return nil
        }

        // Sometimes default protocol implementations don't have `key.overrides` set but they do have
        // `key.related_decls`. The apparent exception is that related declarations also includes declarations
        // with "related names", which appears to be similarly named declarations (i.e. overloads) that are
        // programmatically unrelated to the current cursor-info declaration. Those similarly named declarations
        // aren't in `key.related` so confirm that that one is also populated.
        if cursorInfo?.value["key.related_decls"] != nil && indexEntity.value["key.related"] != nil {
            return nil
        }

       
        let enclosingUSR = publicProtocolsAndClasses.first { indexEntity in
            indexEntity.entities.contains { $0.usr == usr}
        }?.usr
        return .init(usr: usr, module: moduleName, nameOffset: nameOffset, enclosingUSR: enclosingUSR)
    }
    
    private func moduleName(compilerArguments: [String]) -> String {
        guard let moduleNameIndex = compilerArguments.firstIndex(of: "-module-name")?.advanced(by: 1)  else {
            return ""
        }
        return compilerArguments[moduleNameIndex]
    }

    func cursorInfo(at byteOffset: ByteCount, compilerArguments: [String]) -> SourceKittenDictionary? {
        let request = Request.cursorInfo(file: path!, offset: byteOffset, arguments: compilerArguments)
        return (try? request.sendIfNotDisabled()).map(SourceKittenDictionary.init)
    }

    private func shouldIgnoreEntity(_ indexEntity: SourceKittenDictionary) -> Bool {
        if indexEntity.shouldSkipIndexEntityToWorkAroundSR11985() ||
            indexEntity.isIndexEntitySwiftUIProvider() ||
            indexEntity.enclosedSwiftAttributes.contains(where: declarationAttributesToSkip.contains) ||
            indexEntity.isImplicit ||
            indexEntity.value["key.is_test_candidate"] as? Bool == true {
            return true
        }

        if !Set(indexEntity.enclosedSwiftAttributes).isDisjoint(with: [.ibinspectable, .iboutlet]) {
            if let getter = indexEntity.entities.first(where: { $0.declarationKind == .functionAccessorGetter }),
               !getter.isImplicit {
                return true
            }

            if let setter = indexEntity.entities.first(where: { $0.declarationKind == .functionAccessorSetter }),
               !setter.isImplicit {
                return true
            }

            if !Set(indexEntity.entities.compactMap(\.declarationKind))
                .isDisjoint(with: [.functionAccessorWillset, .functionAccessorDidset]) {
                return true
            }
        }

        return false
    }
}

private extension SourceKittenDictionary {
    var usr: String? {
        return value["key.usr"] as? String
    }

    var annotatedDeclaration: String? {
        return value["key.annotated_decl"] as? String
    }

    var isImplicit: Bool {
        return value["key.is_implicit"] as? Bool == true
    }

    func aclAtOffset(_ offset: ByteCount) -> AccessControlLevel? {
        if let nameOffset = nameOffset,
            nameOffset == offset,
            let acl = accessibility {
            return acl
        }
        for child in substructure {
            if let acl = child.aclAtOffset(offset) {
                return acl
            }
        }
        return nil
    }

    func isIndexEntitySwiftUIProvider() -> Bool {
        return (value["key.related"] as? [[String: SourceKitRepresentable]])?
            .map(SourceKittenDictionary.init)
            .contains(where: { $0.usr == "s:7SwiftUI15PreviewProviderP" }) == true
    }

    func shouldSkipIndexEntityToWorkAroundSR11985() -> Bool {
        guard enclosedSwiftAttributes.contains(.objcName), let name = self.name else {
            return false
        }

        // Not a comprehensive list. Add as needed.
        let functionsToSkipForSR11985 = [
            "navigationBar(_:didPop:)",
            "scrollViewDidEndDecelerating(_:)",
            "scrollViewDidEndDragging(_:willDecelerate:)",
            "scrollViewDidScroll(_:)",
            "scrollViewDidScrollToTop(_:)",
            "scrollViewWillBeginDragging(_:)",
            "scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)",
            "tableView(_:canEditRowAt:)",
            "tableView(_:commit:forRowAt:)",
            "tableView(_:editingStyleForRowAt:)",
            "tableView(_:willDisplayHeaderView:forSection:)",
            "tableView(_:willSelectRowAt:)"
        ]

        return functionsToSkipForSR11985.contains(name)
    }
}

// Skip initializers, deinit, enum cases and subscripts since we can't reliably detect if they're used.
private let declarationKindsToSkip: Set<SwiftDeclarationKind> = [
    .enumelement,
    .extensionProtocol,
    .extension,
    .extensionEnum,
    .extensionClass,
    .extensionStruct,
    .functionConstructor,
    .functionDestructor,
    .functionSubscript,
    .genericTypeParam
]

private let declarationAttributesToSkip: Set<SwiftDeclarationAttributeKind> = [
    .ibaction,
    .main,
    .nsApplicationMain,
    .override,
    .uiApplicationMain
]

private extension SourceKittenDictionary {
    func traverseEntities<T>(traverseBlock: (SourceKittenDictionary) -> T?) -> [T] {
        var result: [T] = []
        traverseEntitiesDepthFirst(collectingValuesInto: &result, traverseBlock: traverseBlock)
        return result
    }

    private func traverseEntitiesDepthFirst<T>(collectingValuesInto array: inout [T],
                                               traverseBlock: (SourceKittenDictionary) -> T?) {
        entities.forEach { subDict in
            subDict.traverseEntitiesDepthFirst(collectingValuesInto: &array, traverseBlock: traverseBlock)

            if let collectedValue = traverseBlock(subDict) {
                array.append(collectedValue)
            }
        }
    }
}

private extension StringView {
    func byteOffset(forLine line: Int, column: Int) -> ByteCount {
        guard line > 0 else { return ByteCount(column - 1) }
        return lines[line - 1].byteRange.location + ByteCount(column - 1)
    }
}

private enum ConfigurationKey: String {
    case severity = "severity"
}

public struct UnusedPublicConfiguration: RuleConfiguration, Equatable {
    private(set) var severity: ViolationSeverity

    public var consoleDescription: String {
        return "\(ConfigurationKey.severity.rawValue): \(severity.rawValue), "
    }

    public init(severity: ViolationSeverity) {
        self.severity = severity
    }

    public mutating func apply(configuration: Any) throws {
        guard let configDict = configuration as? [String: Any], configDict.isNotEmpty else {
            throw ConfigurationError.unknownConfiguration
        }

        for (string, value) in configDict {
            guard let key = ConfigurationKey(rawValue: string) else {
                throw ConfigurationError.unknownConfiguration
            }
            switch (key, value) {
            case (.severity, let stringValue as String):
                if let severityValue = ViolationSeverity(rawValue: stringValue) {
                    severity = severityValue
                } else {
                    throw ConfigurationError.unknownConfiguration
                }
            default:
                throw ConfigurationError.unknownConfiguration
            }
        }
    }
}

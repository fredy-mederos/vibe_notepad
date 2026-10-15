import Foundation

/// A structured text format that can be pretty-printed and minified.
public enum DataFormat: Sendable {
    case json
    case xml

    /// The format of documents in `language`, if it has one.
    public init?(language: LanguageID) {
        switch language {
        case .json: self = .json
        case .xml: self = .xml
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .json: "JSON"
        case .xml: "XML"
        }
    }

    public func format(_ source: String, indent: String) throws -> String {
        switch self {
        case .json: try TextTransforms.formatJSON(source, indent: indent)
        case .xml: try TextTransforms.formatXML(source, indent: indent)
        }
    }

    public func minify(_ source: String) throws -> String {
        switch self {
        case .json: try TextTransforms.minifyJSON(source)
        case .xml: try TextTransforms.minifyXML(source)
        }
    }
}

import Foundation

/// RFC 4180 CSV: commas, double-quoted fields when needed, CRLF line ends.
public enum CSV {
    /// Lets Excel know the file is UTF-8 (names with accents or emoji).
    public static let byteOrderMark = "\u{FEFF}"

    public static func field(_ text: String) -> String {
        let needsQuotes = text.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// One line including its CRLF.
    public static func line(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",") + "\r\n"
    }

    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var current = String.UnicodeScalarView()
        var inQuotes = false
        var pending = false
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        func endField() {
            row.append(String(current))
            current = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
            pending = false
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        current.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                    pending = true
                case ",":
                    endField()
                    pending = true
                case "\r":
                    if i + 1 < scalars.count && scalars[i + 1] == "\n" { i += 1 }
                    endRow()
                case "\n":
                    endRow()
                default:
                    current.append(c)
                    pending = true
                }
            }
            i += 1
        }
        if pending || !current.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

import Foundation

/// GPX 1.1, the open route format Strava, Garmin and Google Earth import.
public enum GPX {
    public static func document(for run: Run) -> String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<gpx version=\"1.1\" creator=\"Paqo\" xmlns=\"http://www.topografix.com/GPX/1/1\">",
            "  <metadata>",
            "    <name>\(escape(run.name))</name>",
            "    <time>\(ISO8601.string(from: run.startDate))</time>",
            "  </metadata>",
            "  <trk>",
            "    <name>\(escape(run.name))</name>",
            "    <type>running</type>",
        ]
        var open = false
        for point in run.track {
            if !open || point.startsNewLine {
                if open { lines.append("    </trkseg>") }
                lines.append("    <trkseg>")
                open = true
            }
            var trkpt = "      <trkpt lat=\"\(Format.fixed(point.latitude, decimals: 6))\" lon=\"\(Format.fixed(point.longitude, decimals: 6))\">"
            if let altitude = point.altitude {
                trkpt += "<ele>\(Format.fixed(altitude + run.altitudeOffset, decimals: 1))</ele>"
            }
            trkpt += "<time>\(ISO8601.string(from: point.timestamp))</time></trkpt>"
            lines.append(trkpt)
        }
        if open { lines.append("    </trkseg>") }
        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

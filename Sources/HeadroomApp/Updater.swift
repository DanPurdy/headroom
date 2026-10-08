import AppKit
import Foundation
import HeadroomCore

/// Checks GitHub for a newer release and installs it the way `scripts/install.sh` does.
enum Updater {
    enum Failure: Error {
        case download(String)
        case invalid(String)
        case notWritable

        var message: String {
            switch self {
            case .download(let detail): "Update failed: \(detail)"
            case .invalid(let detail): "Update failed: \(detail)"
            case .notWritable: "Can't replace Headroom where it is. Download the update from the release page."
            }
        }
    }

    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    enum CheckResult {
        case newer(UpdateCheck.Release)
        case upToDate
        case unreachable
    }

    static func check() async -> CheckResult {
        guard let current = currentVersion else { return .unreachable }
        var request = URLRequest(url: UpdateCheck.latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/\(current)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = UpdateCheck.parse(data)
        else { return .unreachable }
        return UpdateCheck.isNewer(release.version, than: current) ? .newer(release) : .upToDate
    }

    /// Downloads and checks the release, then hands over to a helper that swaps the app once this
    /// process has quit and opens the new copy. Returns only on failure.
    static func install(_ release: UpdateCheck.Release) async throws(Failure) {
        let dest = Bundle.main.bundleURL
        let parent = dest.deletingLastPathComponent()
        guard dest.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else { throw .notWritable }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-update-\(UUID().uuidString)")
        let zip = work.appendingPathComponent("Headroom.zip")
        let extracted = work.appendingPathComponent("extract")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: release.download)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download("HTTP error") }
            try FileManager.default.moveItem(at: downloaded, to: zip)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .download(error.localizedDescription)
        }

        let new = extracted.appendingPathComponent("Headroom.app")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path]),
              FileManager.default.fileExists(atPath: new.path) else { throw .invalid("the download didn't contain Headroom.app") }
        guard Bundle(url: new)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw .invalid("the download isn't Headroom") }
        guard run("/usr/bin/codesign", ["--verify", "--strict", new.path]) else { throw .invalid("its code signature is broken") }

        // Keeps the old copy until the new one is in place, and puts it back if the move fails.
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            old="$3.old-$$"
            mv "$3" "$old" || exit 1
            if mv "$2" "$3"; then rm -rf "$old"; else mv "$old" "$3"; fi
            xattr -dr com.apple.quarantine "$3" 2>/dev/null
            open "$3"
            rm -rf "$4"
            """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)", new.path, dest.path, work.path]
        do { try helper.run() } catch { throw .invalid(error.localizedDescription) }
        await MainActor.run { NSApplication.shared.terminate(nil) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

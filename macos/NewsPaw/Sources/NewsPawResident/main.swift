import Darwin
import Foundation
import MachO

func executableURL() -> URL? {
    // launchd can supply a bundle-relative argv[0].
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
    return path.withUnsafeBufferPointer { buffer in
        buffer.baseAddress.map {
            URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
                .resolvingSymlinksInPath()
        }
    }
}

let invocation = Array(CommandLine.arguments.dropFirst())
guard let helper = executableURL() else {
    fputs("The NewsPaw resident executable path could not be resolved.\n", stderr)
    exit(2)
}
let helpers = helper.deletingLastPathComponent()
let python = helpers.deletingLastPathComponent()
    .appendingPathComponent("Resources/Python/bin/python3.13").path
let standard = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NewsPaw", isDirectory: true).path

let arguments: [String]
switch invocation {
case []:
    setenv("NEWSPAW_BUNDLED_RESIDENT", "1", 1)
    arguments = ["-m", "newspaw", "control", "--data-dir", standard]
case ["--self-check"]:
    arguments = ["-m", "newspaw.bundle_runtime", "self-check"]
case ["--check-upgrade"]:
    arguments = ["-m", "newspaw.bundle_runtime", "check-upgrade", standard]
case ["--check-stopped"]:
    arguments = ["-m", "newspaw.bundle_runtime", "check-stopped", standard]
case let args where args.count == 2 && args[0] == "--fixture-control" && args[1].hasPrefix("/"):
    arguments = ["-m", "newspaw", "control", "--data-dir", args[1]]
case let args where args.count == 2 && args[0] == "--fixture-check-upgrade" && args[1].hasPrefix("/"):
    arguments = ["-m", "newspaw.bundle_runtime", "check-upgrade", args[1]]
default:
    fputs("Invalid NewsPaw resident invocation.\n", stderr)
    exit(2)
}

umask(0o077)
let searchPath = helpers.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
setenv("PATH", searchPath, 1)
let command = [python, "-I", "-B"] + arguments
var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
argv.append(nil)
argv.withUnsafeMutableBufferPointer { pointer in
    _ = execv(python, pointer.baseAddress!)
}
fputs("The bundled NewsPaw runtime could not start.\n", stderr)
exit(2)

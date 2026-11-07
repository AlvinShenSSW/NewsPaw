import Darwin
import Foundation

let invocation = Array(CommandLine.arguments.dropFirst())
let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let helpers = helper.deletingLastPathComponent()
let python = helpers.appendingPathComponent("Python/bin/python3.13").path
let standard = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NewsPaw", isDirectory: true).path

let arguments: [String]
switch invocation {
case []:
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

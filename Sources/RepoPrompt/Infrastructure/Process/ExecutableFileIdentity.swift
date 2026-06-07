import Darwin
import Foundation

struct ExecutableFileIdentity: Equatable {
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    static func capture(atPath rawPath: String) throws -> ExecutableFileIdentity {
        guard rawPath.hasPrefix("/") else {
            throw ExecutableFileIdentityError.pathMustBeAbsolute(rawPath)
        }

        let canonicalPath = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var info = stat()
        guard stat(canonicalPath, &info) == 0 else {
            throw ExecutableFileIdentityError.unavailable(canonicalPath)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ExecutableFileIdentityError.notRegularFile(canonicalPath)
        }
        guard access(canonicalPath, X_OK) == 0 else {
            throw ExecutableFileIdentityError.notExecutable(canonicalPath)
        }

        return ExecutableFileIdentity(
            canonicalPath: canonicalPath,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    func validate(atPath path: String) throws {
        let current = try Self.capture(atPath: path)
        guard current == self else {
            throw ExecutableFileIdentityError.identityChanged(
                expectedPath: canonicalPath,
                actualPath: current.canonicalPath
            )
        }
    }
}

enum ExecutableFileIdentityError: Error, Equatable, LocalizedError {
    case pathMustBeAbsolute(String)
    case unavailable(String)
    case notRegularFile(String)
    case notExecutable(String)
    case identityChanged(expectedPath: String, actualPath: String)

    var errorDescription: String? {
        switch self {
        case let .pathMustBeAbsolute(path):
            "Executable path must be absolute: \(path)"
        case let .unavailable(path):
            "Executable is unavailable: \(path)"
        case let .notRegularFile(path):
            "Executable path is not a regular file: \(path)"
        case let .notExecutable(path):
            "Executable path is not executable: \(path)"
        case let .identityChanged(expectedPath, actualPath):
            "Executable identity changed before launch. Expected \(expectedPath), found \(actualPath)."
        }
    }
}

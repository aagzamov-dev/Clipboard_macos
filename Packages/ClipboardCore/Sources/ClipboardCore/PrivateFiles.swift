import Foundation
import Darwin
import CryptoKit

public enum PrivateFiles {
    public static func directory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try rejectLink(url) }
        else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var resourceURL = url; try resourceURL.setResourceValues(values)
    }
    public static func rejectLink(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { throw CoreError.invalidData }
    }
    public static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CoreError.storage(Int32(errno)) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try file.write(contentsOf: data); try file.synchronize(); try file.close() }
        catch { try? file.close(); try? FileManager.default.removeItem(at: url); throw error }
    }
    public static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CoreError.inaccessibleAttachment }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit, info.st_size >= 0 else { throw CoreError.tooLarge }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CoreError.tooLarge }
        return data
    }
    public static func isManagedName(_ name: String) -> Bool { UUID(uuidString: name) != nil && !name.contains("/") && name.count == 36 }
    public static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

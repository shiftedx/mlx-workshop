import Foundation

enum SecurityScopedPathError: Error, Equatable, Sendable {
  case staleBookmark
}

enum SecurityScopedAccessMode: String, Codable, Sendable {
  case readOnly
  case readWrite
}

struct SecurityScopedPath: Codable, Equatable, Sendable {
  let bookmarkData: Data
  let displayPath: String
  let accessMode: SecurityScopedAccessMode

  init(url: URL, accessMode: SecurityScopedAccessMode) throws {
    var options: URL.BookmarkCreationOptions = [.withSecurityScope]
    if accessMode == .readOnly {
      options.insert(.securityScopeAllowOnlyReadAccess)
    }
    bookmarkData = try url.bookmarkData(
      options: options,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    displayPath = url.path
    self.accessMode = accessMode
  }

  func resolve() throws -> SecurityScopedAccess {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    guard !isStale else { throw SecurityScopedPathError.staleBookmark }
    return SecurityScopedAccess(url: url)
  }
}

final class SecurityScopedAccess: @unchecked Sendable {
  let url: URL
  private let didStartAccess: Bool

  fileprivate init(url: URL) {
    self.url = url
    didStartAccess = url.startAccessingSecurityScopedResource()
  }

  deinit {
    if didStartAccess {
      url.stopAccessingSecurityScopedResource()
    }
  }
}

import Foundation

enum SecurityScopedPathError: Error, Equatable, Sendable {
  case staleBookmark
}

enum SecurityScopedAccessMode: String, Codable, Sendable {
  case readOnly
  case readWrite
}

struct SecurityScopedResourceOperations: @unchecked Sendable {
  let startAccessing: (URL) -> Bool
  let stopAccessing: (URL) -> Void
  let createBookmark: (URL, URL.BookmarkCreationOptions) throws -> Data

  static let system = SecurityScopedResourceOperations(
    startAccessing: { $0.startAccessingSecurityScopedResource() },
    stopAccessing: { $0.stopAccessingSecurityScopedResource() },
    createBookmark: { url, options in
      try url.bookmarkData(
        options: options,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    })
}

struct SecurityScopedPath: Codable, Equatable, Sendable {
  let bookmarkData: Data
  let displayPath: String
  let accessMode: SecurityScopedAccessMode

  init(
    url: URL,
    accessMode: SecurityScopedAccessMode,
    operations: SecurityScopedResourceOperations = .system
  ) throws {
    let didStartAccess = operations.startAccessing(url)
    defer {
      if didStartAccess {
        operations.stopAccessing(url)
      }
    }
    var options: URL.BookmarkCreationOptions = [.withSecurityScope]
    if accessMode == .readOnly {
      options.insert(.securityScopeAllowOnlyReadAccess)
    }
    bookmarkData = try operations.createBookmark(url, options)
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

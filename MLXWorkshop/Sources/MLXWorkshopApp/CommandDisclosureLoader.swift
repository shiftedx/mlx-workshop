import Foundation

enum CommandDisclosureError: Error, Equatable {
  case unsupportedSchema(Int)
  case noCommands
}

extension CommandDisclosure {
  static func decodeCommandsFile(_ data: Data) throws -> CommandDisclosure {
    let file = try JSONDecoder().decode(CommandsFile.self, from: data)
    guard file.schemaVersion == WorkflowEvent.supportedSchemaVersion else {
      throw CommandDisclosureError.unsupportedSchema(file.schemaVersion)
    }
    guard !file.commands.isEmpty else { throw CommandDisclosureError.noCommands }
    return CommandDisclosure(
      commands: file.commands.map { command in
        CommandInvocationDisclosure(
          executableIdentity: command.executable,
          arguments: command.arguments,
          redactedDisplay: command.redactedDisplay)
      })
  }

  static func load(from url: URL) throws -> CommandDisclosure {
    try decodeCommandsFile(Data(contentsOf: url))
  }
}

private struct CommandsFile: Decodable {
  let schemaVersion: Int
  let commands: [PersistedCommand]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case commands
  }
}

private struct PersistedCommand: Decodable {
  let executable: String
  let arguments: [String]
  let redactedDisplay: String

  private enum CodingKeys: String, CodingKey {
    case executable
    case arguments
    case redactedDisplay = "redacted_display"
  }
}

import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runRelayCredentialRead(_ values: ParsedValues) -> Never {
        do {
            let credential = try self.resolveRelayCredential(
                reference: values.options["reference"]?.last,
                store: FileRelayCredentialStore())
            guard let data = credential.data(using: .utf8) else {
                throw RelayCredentialCLIError.unavailable
            }
            FileHandle.standardOutput.write(data)
            Self.platformExit(ExitCode.success.rawValue)
        } catch {
            exit(
                code: .failure,
                message: "Relay credential unavailable.",
                kind: .runtime)
        }
    }

    static func resolveRelayCredential(
        reference: String?,
        store: any RelayCredentialStoring) throws -> String
    {
        guard let reference,
              RelayCredentialReference.isValid(reference),
              let credential = try store.loadCredential(reference: reference)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
                  !credential.isEmpty
        else {
            throw RelayCredentialCLIError.unavailable
        }
        return credential
    }

    static func relayCommandDescriptor() -> CommandDescriptor {
        CommandDescriptor(
            name: "relay",
            abstract: "Relay support utilities",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: [
                CommandDescriptor(
                    name: "credential",
                    abstract: "Relay credential utilities",
                    discussion: nil,
                    signature: CommandSignature(),
                    subcommands: [
                        CommandDescriptor(
                            name: "read",
                            abstract: "Read a relay credential for a configured client",
                            discussion: "Internal helper; writes only the credential to stdout.",
                            signature: CommandSignature.describe(RelayCredentialReadOptions())),
                    ],
                    defaultSubcommandName: "read"),
                CommandDescriptor(
                    name: "restore-official",
                    abstract: "Restore managed clients to their official configuration",
                    discussion: "Safe no-op when no relay activation baseline is recorded.",
                    signature: CommandSignature.describe(RelayRestoreOfficialOptions())),
            ],
            defaultSubcommandName: "credential")
    }
}

enum RelayCredentialCLIError: Error, Equatable {
    case unavailable
}

struct RelayCredentialReadOptions: CommanderParsable {
    @Option(name: .long("reference"), help: "Opaque relay credential reference")
    var reference: String?
}

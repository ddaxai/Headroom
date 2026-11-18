import Foundation

extension CodexBarCLI {
    static func restoreProviderBucketsHelp(version: String) -> String {
        [
            "CodexBar \(version)",
            "",
            "Usage:",
            "  codexbar restore-provider-buckets [--dry-run|--apply]",
            "                                            [--codex-directory <directory>]",
            "                                            [--backup-root <directory>]",
            "  codexbar history restore-provider-buckets [--dry-run|--apply]",
            "                                                    [--codex-directory <directory>]",
            "                                                    [--backup-root <directory>]",
            "",
            "Description:",
            "  Plan a reverse restore from codexbar_shared to the original provider buckets.",
            "  The default is dry-run: rollout records without codexbar_origin_provider are left alone,",
            "  and state rows without an unambiguous rollout mapping are reported as unresolved.",
            "  --apply is required before any source history file is changed; a verified backup,",
            "  manifest, and SHA-256 inventory are written first.",
            "  The command never reads or prints credentials and does not record request content.",
        ].joined(separator: "\n")
    }
}

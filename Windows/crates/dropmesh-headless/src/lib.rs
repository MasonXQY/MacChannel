//! Stable command-line contract used only for deterministic integration tests.

use clap::{Args, Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "dropmesh-headless",
    version,
    about = "DropMesh interoperability peer"
)]
pub struct HeadlessArguments {
    #[command(subcommand)]
    pub command: HeadlessCommand,
}

#[derive(Debug, Subcommand)]
pub enum HeadlessCommand {
    /// Authenticate to rendezvous and print bounded JSON-lines presence events.
    Presence(PresenceArguments),
}

#[derive(Debug, Args)]
pub struct PresenceArguments {
    /// Exact production WSS endpoint, including `/v1/ws`.
    #[arg(long)]
    pub origin: String,
    /// Current-user CNG signing key name.
    #[arg(long, default_value = "Zensys.DropMesh.Windows.DeviceIdentity.v1")]
    pub key_name: String,
    /// Stop after this many business events (0 keeps listening).
    #[arg(long, default_value_t = 0)]
    pub events: u32,
}

#[cfg(test)]
#[allow(clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn parses_explicit_presence_contract_without_environment_fallbacks() {
        let arguments = HeadlessArguments::try_parse_from([
            "dropmesh-headless",
            "presence",
            "--origin",
            "wss://channel.example/v1/ws",
            "--key-name",
            "test-key",
            "--events",
            "2",
        ])
        .expect("valid arguments");
        let HeadlessCommand::Presence(presence) = arguments.command;
        assert_eq!(presence.origin, "wss://channel.example/v1/ws");
        assert_eq!(presence.key_name, "test-key");
        assert_eq!(presence.events, 2);
    }

    #[test]
    fn rejects_missing_origin() {
        assert!(HeadlessArguments::try_parse_from(["dropmesh-headless", "presence"]).is_err());
    }
}

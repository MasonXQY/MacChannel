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
    /// Discover same-account enrollment state. Reads the access token from stdin.
    AccountDiscover(AccountDiscoverArguments),
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

#[derive(Debug, Args)]
pub struct AccountDiscoverArguments {
    /// Exact production HTTPS account-service origin.
    #[arg(long)]
    pub origin: String,
    /// Native client audience bound into the account session.
    #[arg(long)]
    pub audience: String,
    /// Account identifier returned by the authenticated web-login flow.
    #[arg(long)]
    pub account_id: String,
    /// Current-user CNG signing key name.
    #[arg(long, default_value = "Zensys.DropMesh.Windows.DeviceIdentity.v1")]
    pub key_name: String,
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
        let HeadlessCommand::Presence(presence) = arguments.command else {
            panic!("presence expected");
        };
        assert_eq!(presence.origin, "wss://channel.example/v1/ws");
        assert_eq!(presence.key_name, "test-key");
        assert_eq!(presence.events, 2);
    }

    #[test]
    fn rejects_missing_origin() {
        assert!(HeadlessArguments::try_parse_from(["dropmesh-headless", "presence"]).is_err());
    }

    #[test]
    fn parses_account_discovery_without_exposing_the_access_token_in_arguments() {
        let arguments = HeadlessArguments::try_parse_from([
            "dropmesh-headless",
            "account-discover",
            "--origin",
            "https://account.example",
            "--audience",
            "com.zensystech.dropmesh",
            "--account-id",
            "11111111-1111-1111-1111-111111111111",
        ])
        .expect("valid arguments");
        let HeadlessCommand::AccountDiscover(discovery) = arguments.command else {
            panic!("account discovery expected");
        };
        assert_eq!(discovery.origin, "https://account.example");
        assert_eq!(discovery.audience, "com.zensystech.dropmesh");
        assert_eq!(discovery.account_id, "11111111-1111-1111-1111-111111111111");
    }
}

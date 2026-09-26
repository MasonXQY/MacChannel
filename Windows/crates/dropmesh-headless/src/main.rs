#[cfg(windows)]
mod windows_main {
    use std::io::Read as _;
    use std::process::ExitCode;
    use std::time::{SystemTime, UNIX_EPOCH};

    use clap::Parser as _;
    use dropmesh_account::AccountDiscovery;
    use dropmesh_headless::{HeadlessArguments, HeadlessCommand};
    use dropmesh_network::{AccountEnrollmentClient, PresenceConnection};
    use dropmesh_platform_windows::WindowsCngIdentity;
    use dropmesh_rendezvous::ServerFrame;
    use serde_json::json;

    pub fn run() -> ExitCode {
        let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(2)
            .enable_all()
            .build()
        else {
            return fail("runtime_unavailable");
        };
        runtime.block_on(run_async())
    }

    async fn run_async() -> ExitCode {
        let arguments = HeadlessArguments::parse();
        match arguments.command {
            HeadlessCommand::Presence(arguments) => {
                let Ok(identity) = WindowsCngIdentity::load_or_create(&arguments.key_name) else {
                    return fail("identity_unavailable");
                };
                let epoch = match SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .ok()
                    .and_then(|duration| i64::try_from(duration.as_millis()).ok())
                {
                    Some(epoch) if epoch > 0 => epoch,
                    _ => return fail("clock_unavailable"),
                };
                let Ok(mut connection) =
                    PresenceConnection::connect(&arguments.origin, &identity, epoch).await
                else {
                    return fail("connection_failed");
                };
                println!(
                    "{}",
                    json!({"type":"connected","deviceID":connection.device_id()})
                );
                let mut delivered = 0_u32;
                loop {
                    let Ok(event) = connection.next_event().await else {
                        return fail("connection_closed");
                    };
                    println!("{}", event_json(event));
                    delivered = delivered.saturating_add(1);
                    if arguments.events > 0 && delivered >= arguments.events {
                        return match connection.close().await {
                            Ok(()) => ExitCode::SUCCESS,
                            Err(_) => fail("close_failed"),
                        };
                    }
                }
            }
            HeadlessCommand::AccountDiscover(arguments) => {
                let Ok(identity) = WindowsCngIdentity::load_or_create(&arguments.key_name) else {
                    return fail("identity_unavailable");
                };
                let Ok(access_token) = read_access_token() else {
                    return fail("access_token_unavailable");
                };
                let Some(epoch) = epoch_milliseconds() else {
                    return fail("clock_unavailable");
                };
                let mut nonce = [0_u8; 32];
                if getrandom::fill(&mut nonce).is_err() {
                    return fail("random_unavailable");
                }
                let Ok(client) =
                    AccountEnrollmentClient::new(&arguments.origin, &arguments.audience)
                else {
                    return fail("account_configuration_invalid");
                };
                let Ok(discovery) = client
                    .discover(
                        &identity,
                        &nonce,
                        epoch,
                        &access_token,
                        &arguments.account_id,
                    )
                    .await
                else {
                    return fail("account_discovery_failed");
                };
                match discovery {
                    AccountDiscovery::Absent => {
                        println!("{}", json!({"type":"account-group","status":"absent"}));
                    }
                    AccountDiscovery::Present(metadata) => println!(
                        "{}",
                        json!({
                            "type":"account-group", "status":"present",
                            "groupID":metadata.group_id(), "generation":metadata.generation(),
                            "headSequence":metadata.head_sequence()
                        })
                    ),
                }
                ExitCode::SUCCESS
            }
        }
    }

    fn epoch_milliseconds() -> Option<i64> {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|duration| i64::try_from(duration.as_millis()).ok())
            .filter(|epoch| *epoch > 0)
    }

    fn read_access_token() -> Result<String, ()> {
        let mut bytes = Vec::new();
        std::io::stdin()
            .take(129)
            .read_to_end(&mut bytes)
            .map_err(|_| ())?;
        if bytes.len() > 128 {
            return Err(());
        }
        while matches!(bytes.last(), Some(b'\n' | b'\r')) {
            bytes.pop();
        }
        String::from_utf8(bytes).map_err(|_| ())
    }

    fn event_json(event: ServerFrame) -> serde_json::Value {
        match event {
            ServerFrame::Presence { device_id, online } => json!({
                "type":"presence", "deviceID":device_id,
                "availability": if online { "internet" } else { "offline" }
            }),
            ServerFrame::Signal { from, payload } => json!({
                "type":"signal", "from":from, "payloadBytes":payload.len()
            }),
            ServerFrame::SignalError { code, target } => json!({
                "type":"signal-error", "code":code, "to":target
            }),
            ServerFrame::ProtocolError { code } => json!({"type":"protocol-error", "code":code}),
            ServerFrame::TrustAccepted => json!({"type":"trust-ok"}),
            ServerFrame::TrustRejected => json!({"type":"trust-error"}),
            ServerFrame::Authenticated { device_id } => json!({
                "type":"unexpected-authentication", "deviceID":device_id
            }),
        }
    }

    fn fail(code: &str) -> ExitCode {
        eprintln!("{}", json!({"type":"error","code":code}));
        ExitCode::FAILURE
    }
}

#[cfg(windows)]
fn main() -> std::process::ExitCode {
    windows_main::run()
}

#[cfg(not(windows))]
fn main() -> std::process::ExitCode {
    eprintln!(r#"{{"type":"error","code":"windows_required"}}"#);
    std::process::ExitCode::FAILURE
}

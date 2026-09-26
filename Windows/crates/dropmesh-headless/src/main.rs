#[cfg(windows)]
mod windows_main {
    use std::process::ExitCode;
    use std::time::{SystemTime, UNIX_EPOCH};

    use clap::Parser as _;
    use dropmesh_headless::{HeadlessArguments, HeadlessCommand};
    use dropmesh_network::PresenceConnection;
    use dropmesh_platform_windows::WindowsCngIdentity;
    use dropmesh_rendezvous::ServerFrame;
    use serde_json::json;

    pub fn run() -> ExitCode {
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(2)
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(_) => return fail("runtime_unavailable"),
        };
        runtime.block_on(run_async())
    }

    async fn run_async() -> ExitCode {
        let arguments = HeadlessArguments::parse();
        match arguments.command {
            HeadlessCommand::Presence(arguments) => {
                let identity = match WindowsCngIdentity::load_or_create(&arguments.key_name) {
                    Ok(identity) => identity,
                    Err(_) => return fail("identity_unavailable"),
                };
                let epoch = match SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .ok()
                    .and_then(|duration| i64::try_from(duration.as_millis()).ok())
                {
                    Some(epoch) if epoch > 0 => epoch,
                    _ => return fail("clock_unavailable"),
                };
                let mut connection =
                    match PresenceConnection::connect(&arguments.origin, &identity, epoch).await {
                        Ok(connection) => connection,
                        Err(_) => return fail("connection_failed"),
                    };
                println!(
                    "{}",
                    json!({"type":"connected","deviceID":connection.device_id()})
                );
                let mut delivered = 0_u32;
                loop {
                    let event = match connection.next_event().await {
                        Ok(event) => event,
                        Err(_) => return fail("connection_closed"),
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
        }
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

//! Bounded HTTPS and authenticated WebSocket transport for the Windows peer.

#![allow(clippy::missing_errors_doc)]

use std::time::Duration;

use dropmesh_account::{AccountDiscovery, encode_discovery_request};
use dropmesh_identity::DeviceIdentity;
use dropmesh_rendezvous::{
    Challenge, MAX_FRAME_BYTES, MAX_HTTP_BODY_BYTES, RendezvousError, SUBPROTOCOL, ServerFrame,
    decode_challenge, decode_server_frame, encode_authentication, encode_signal,
    encode_signed_http_body,
};
use futures_util::{SinkExt as _, StreamExt as _};
use reqwest::{Client, StatusCode, Url, header::CONTENT_TYPE};
use thiserror::Error;
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async_with_config,
    tungstenite::{
        Message, client::IntoClientRequest as _, http::HeaderValue, protocol::WebSocketConfig,
    },
};

const NETWORK_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum NetworkError {
    #[error("network origin or path is invalid")]
    InvalidConfiguration,
    #[error("remote response violated the DropMesh protocol")]
    InvalidResponse,
    #[error("remote response exceeded a configured bound")]
    ResponseTooLarge,
    #[error("rendezvous authentication was rejected")]
    AuthenticationRejected,
    #[error("network operation timed out")]
    TimedOut,
    #[error("network transport failed")]
    Transport,
    #[error("connection is closed")]
    Closed,
}

impl From<RendezvousError> for NetworkError {
    fn from(error: RendezvousError) -> Self {
        match error {
            RendezvousError::FrameTooLarge => Self::ResponseTooLarge,
            RendezvousError::InvalidFrame | RendezvousError::SigningFailed => Self::InvalidResponse,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// HTTPS-only client with redirects, cookies, decompression, proxies and HTTP/2
/// omitted. Every request body is still independently signed by the device.
#[derive(Clone)]
pub struct SignedHttpClient {
    origin: Url,
    client: Client,
}

impl SignedHttpClient {
    pub fn new(origin: &str) -> Result<Self, NetworkError> {
        Self::new_with_policy(origin, false)
    }

    fn new_with_policy(origin: &str, allow_insecure: bool) -> Result<Self, NetworkError> {
        install_crypto_provider();
        let required_scheme = if allow_insecure { "http" } else { "https" };
        let origin = parse_origin(origin, required_scheme)?;
        let client = Client::builder()
            .https_only(!allow_insecure)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| NetworkError::InvalidConfiguration)?;
        Ok(Self { origin, client })
    }

    pub async fn post_signed(
        &self,
        path: &str,
        identity: &dyn DeviceIdentity,
        nonce: &[u8; 32],
        payload: &[u8],
        epoch_milliseconds: i64,
    ) -> Result<HttpResponse, NetworkError> {
        let body = encode_signed_http_body(identity, nonce, payload, epoch_milliseconds)?;
        let url = endpoint(&self.origin, path)?;
        let response = self
            .client
            .post(url)
            .header(CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .await
            .map_err(|_| NetworkError::Transport)?;
        let status = response.status();
        if status.is_redirection() {
            return Err(NetworkError::InvalidResponse);
        }
        if let Some(length) = response.content_length()
            && length > MAX_HTTP_BODY_BYTES as u64
        {
            return Err(NetworkError::ResponseTooLarge);
        }
        if !valid_json_content_type(response.headers().get(CONTENT_TYPE)) {
            return Err(NetworkError::InvalidResponse);
        }
        let mut stream = response.bytes_stream();
        let mut received = Vec::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| NetworkError::Transport)?;
            if received.len().saturating_add(chunk.len()) > MAX_HTTP_BODY_BYTES {
                return Err(NetworkError::ResponseTooLarge);
            }
            received.extend_from_slice(&chunk);
        }
        Ok(HttpResponse {
            status: status.as_u16(),
            body: received,
        })
    }
}

/// Signed account-enrollment operations required before a Windows device can
/// join an existing same-account trust group.
#[derive(Clone)]
pub struct AccountEnrollmentClient {
    http: SignedHttpClient,
    audience: String,
}

impl AccountEnrollmentClient {
    pub fn new(origin: &str, audience: &str) -> Result<Self, NetworkError> {
        Self::new_with_policy(origin, audience, false)
    }

    fn new_with_policy(
        origin: &str,
        audience: &str,
        allow_insecure: bool,
    ) -> Result<Self, NetworkError> {
        const VALIDATION_TOKEN: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        encode_discovery_request(audience, VALIDATION_TOKEN)
            .map_err(|_| NetworkError::InvalidConfiguration)?;
        let http = SignedHttpClient::new_with_policy(origin, allow_insecure)?;
        if http.origin.path() != "/" {
            return Err(NetworkError::InvalidConfiguration);
        }
        Ok(Self {
            http,
            audience: audience.to_owned(),
        })
    }

    pub async fn discover(
        &self,
        identity: &dyn DeviceIdentity,
        nonce: &[u8; 32],
        epoch_milliseconds: i64,
        access_token: &str,
        expected_account_id: &str,
    ) -> Result<AccountDiscovery, NetworkError> {
        let payload = encode_discovery_request(&self.audience, access_token)
            .map_err(|_| NetworkError::InvalidConfiguration)?;
        let response = self
            .http
            .post_signed(
                "/v1/account/group/discover",
                identity,
                nonce,
                &payload,
                epoch_milliseconds,
            )
            .await?;
        match response.status {
            200 => AccountDiscovery::decode_json_strict(&response.body, expected_account_id)
                .map_err(|_| NetworkError::InvalidResponse),
            401 => Err(NetworkError::AuthenticationRejected),
            _ => Err(NetworkError::InvalidResponse),
        }
    }
}

type PresenceSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// Sole owner/reader of one authenticated `/v1/ws` connection.
pub struct PresenceConnection {
    socket: PresenceSocket,
    device_id: String,
}

impl PresenceConnection {
    pub async fn connect(
        origin: &str,
        identity: &dyn DeviceIdentity,
        epoch_milliseconds: i64,
    ) -> Result<Self, NetworkError> {
        Self::connect_with_policy(origin, identity, epoch_milliseconds, false).await
    }

    async fn connect_with_policy(
        origin: &str,
        identity: &dyn DeviceIdentity,
        epoch_milliseconds: i64,
        allow_insecure: bool,
    ) -> Result<Self, NetworkError> {
        install_crypto_provider();
        let required_scheme = if allow_insecure { "ws" } else { "wss" };
        let url = parse_origin(origin, required_scheme)?;
        if url.path() != "/v1/ws" {
            return Err(NetworkError::InvalidConfiguration);
        }
        let mut request = url
            .as_str()
            .into_client_request()
            .map_err(|_| NetworkError::InvalidConfiguration)?;
        request.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            HeaderValue::from_static(SUBPROTOCOL),
        );
        let configuration = WebSocketConfig::default()
            .max_message_size(Some(MAX_FRAME_BYTES))
            .max_frame_size(Some(MAX_FRAME_BYTES));
        let connected = timeout(
            NETWORK_TIMEOUT,
            connect_async_with_config(request, Some(configuration), false),
        )
        .await
        .map_err(|_| NetworkError::TimedOut)?
        .map_err(|_| NetworkError::Transport)?;
        let (mut socket, response) = connected;
        if response.status() != StatusCode::SWITCHING_PROTOCOLS
            || response
                .headers()
                .get("Sec-WebSocket-Protocol")
                .and_then(|v| v.to_str().ok())
                != Some(SUBPROTOCOL)
        {
            let _ = socket.close(None).await;
            return Err(NetworkError::InvalidResponse);
        }

        let challenge_bytes = timeout(NETWORK_TIMEOUT, read_data(&mut socket))
            .await
            .map_err(|_| NetworkError::TimedOut)??;
        let challenge: Challenge = decode_challenge(&challenge_bytes, epoch_milliseconds)?;
        let authentication = encode_authentication(identity, &challenge, epoch_milliseconds)?;
        timeout(
            NETWORK_TIMEOUT,
            socket.send(Message::Binary(authentication.into())),
        )
        .await
        .map_err(|_| NetworkError::TimedOut)?
        .map_err(|_| NetworkError::Transport)?;

        let confirmation = timeout(NETWORK_TIMEOUT, read_data(&mut socket))
            .await
            .map_err(|_| NetworkError::TimedOut)??;
        let expected_device = identity.device_id().to_string();
        match decode_server_frame(&confirmation)? {
            ServerFrame::Authenticated { device_id } if device_id == expected_device => {
                Ok(Self { socket, device_id })
            }
            _ => {
                let _ = socket.close(None).await;
                Err(NetworkError::AuthenticationRejected)
            }
        }
    }

    #[must_use]
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub async fn next_event(&mut self) -> Result<ServerFrame, NetworkError> {
        let bytes = read_data(&mut self.socket).await?;
        match decode_server_frame(&bytes)? {
            ServerFrame::Authenticated { .. } => Err(NetworkError::InvalidResponse),
            event => Ok(event),
        }
    }

    pub async fn send_signal(&mut self, target: &str, payload: &[u8]) -> Result<(), NetworkError> {
        let frame = encode_signal(target, payload)?;
        self.socket
            .send(Message::Binary(frame.into()))
            .await
            .map_err(|_| NetworkError::Transport)
    }

    pub async fn close(mut self) -> Result<(), NetworkError> {
        self.socket
            .close(None)
            .await
            .map_err(|_| NetworkError::Transport)
    }
}

async fn read_data(socket: &mut PresenceSocket) -> Result<Vec<u8>, NetworkError> {
    loop {
        let message = socket
            .next()
            .await
            .ok_or(NetworkError::Closed)?
            .map_err(|_| NetworkError::Transport)?;
        match message {
            Message::Binary(bytes) => {
                if bytes.len() > MAX_FRAME_BYTES {
                    return Err(NetworkError::ResponseTooLarge);
                }
                return Ok(bytes.to_vec());
            }
            Message::Text(text) => {
                if text.len() > MAX_FRAME_BYTES {
                    return Err(NetworkError::ResponseTooLarge);
                }
                return Ok(text.as_bytes().to_vec());
            }
            Message::Ping(bytes) => {
                socket
                    .send(Message::Pong(bytes))
                    .await
                    .map_err(|_| NetworkError::Transport)?;
            }
            Message::Pong(_) => {}
            Message::Close(_) => return Err(NetworkError::Closed),
            Message::Frame(_) => return Err(NetworkError::InvalidResponse),
        }
    }
}

fn install_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

fn parse_origin(value: &str, required_scheme: &str) -> Result<Url, NetworkError> {
    let url = Url::parse(value).map_err(|_| NetworkError::InvalidConfiguration)?;
    if url.scheme() != required_scheme
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(NetworkError::InvalidConfiguration);
    }
    Ok(url)
}

fn endpoint(origin: &Url, path: &str) -> Result<Url, NetworkError> {
    if !path.starts_with('/') || path.starts_with("//") || path.contains(['?', '#']) {
        return Err(NetworkError::InvalidConfiguration);
    }
    let mut url = origin.clone();
    url.set_path(path);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}

fn valid_json_content_type(value: Option<&reqwest::header::HeaderValue>) -> bool {
    let Some(value) = value.and_then(|value| value.to_str().ok()) else {
        return false;
    };
    let mut parts = value.split(';').map(str::trim);
    if parts.next().map(str::to_ascii_lowercase).as_deref() != Some("application/json") {
        return false;
    }
    match (parts.next(), parts.next()) {
        (None, None) => true,
        (Some(charset), None) => matches!(
            charset.to_ascii_lowercase().as_str(),
            "charset=utf-8" | "charset=\"utf-8\""
        ),
        _ => false,
    }
}

#[cfg(test)]
#[allow(clippy::result_large_err, clippy::unwrap_used)]
mod tests {
    use super::*;
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use dropmesh_identity::{DerEcdsaSignature, IdentityError, P256PublicKey};
    use dropmesh_protocol::SignedEnvelope;
    use p256::{
        SecretKey,
        ecdsa::{SigningKey, signature::Signer as _},
        elliptic_curve::sec1::ToSec1Point as _,
    };
    use tokio::{
        io::{AsyncReadExt as _, AsyncWriteExt as _},
        net::TcpListener,
    };
    use tokio_tungstenite::{
        accept_hdr_async,
        tungstenite::handshake::server::{Request, Response},
    };

    struct TestIdentity {
        signing: SigningKey,
        signing_public: P256PublicKey,
        agreement_public: P256PublicKey,
    }
    impl TestIdentity {
        fn seeded(seed: u8) -> Self {
            let signing_secret = SecretKey::from_slice(&[seed; 32]).unwrap();
            let agreement_secret = SecretKey::from_slice(&[seed + 1; 32]).unwrap();
            let signing_public: [u8; 64] =
                signing_secret.public_key().to_sec1_point(false).as_bytes()[1..]
                    .try_into()
                    .unwrap();
            let agreement_public: [u8; 64] = agreement_secret
                .public_key()
                .to_sec1_point(false)
                .as_bytes()[1..]
                .try_into()
                .unwrap();
            Self {
                signing: SigningKey::from(signing_secret),
                signing_public: P256PublicKey::from_raw_xy(signing_public).unwrap(),
                agreement_public: P256PublicKey::from_raw_xy(agreement_public).unwrap(),
            }
        }
    }
    impl DeviceIdentity for TestIdentity {
        fn signing_public_key(&self) -> P256PublicKey {
            self.signing_public
        }
        fn agreement_public_key(&self) -> P256PublicKey {
            self.agreement_public
        }
        fn sign(&self, message: &[u8]) -> Result<DerEcdsaSignature, IdentityError> {
            let signature: p256::ecdsa::Signature = self.signing.sign(message);
            DerEcdsaSignature::from_bytes(signature.to_der().as_bytes())
        }
    }

    #[tokio::test]
    async fn websocket_authenticates_then_delivers_presence() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let identity = TestIdentity::seeded(17);
        let device_id = identity.device_id().to_string();
        let expected_device = device_id.clone();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket =
                accept_hdr_async(stream, |request: &Request, mut response: Response| {
                    assert_eq!(request.headers()["Sec-WebSocket-Protocol"], SUBPROTOCOL);
                    response.headers_mut().insert(
                        "Sec-WebSocket-Protocol",
                        HeaderValue::from_static(SUBPROTOCOL),
                    );
                    Ok(response)
                })
                .await
                .unwrap();
            socket
                .send(Message::Text(
                    format!(
                        r#"{{"expiresAt":1800000030000,"nonce":"{}","type":"challenge"}}"#,
                        STANDARD.encode([8; 32])
                    )
                    .into(),
                ))
                .await
                .unwrap();
            let auth = match socket.next().await.unwrap().unwrap() {
                Message::Binary(bytes) => bytes,
                other => panic!("unexpected authentication frame {other:?}"),
            };
            let value: serde_json::Value = serde_json::from_slice(&auth).unwrap();
            let envelope = SignedEnvelope::decode_canonical_json(
                &serde_json::to_vec(&value["envelope"]).unwrap(),
            )
            .unwrap();
            envelope.verify().unwrap();
            assert_eq!(
                envelope.payload,
                dropmesh_rendezvous::AUTHENTICATION_PAYLOAD
            );
            socket
                .send(Message::Text(
                    format!(r#"{{"deviceID":"{expected_device}","type":"auth-ok"}}"#).into(),
                ))
                .await
                .unwrap();
            socket.send(Message::Text(format!(r#"{{"availability":"internet","deviceID":"{expected_device}","type":"presence"}}"#).into())).await.unwrap();
            socket.close(None).await.unwrap();
        });

        let mut client = PresenceConnection::connect_with_policy(
            &format!("ws://{address}/v1/ws"),
            &identity,
            1_800_000_000_000,
            true,
        )
        .await
        .unwrap();
        assert_eq!(client.device_id(), device_id);
        assert_eq!(
            client.next_event().await.unwrap(),
            ServerFrame::Presence {
                device_id,
                online: true
            }
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn account_discovery_posts_a_signed_request_and_verifies_the_response() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let header_end = loop {
                let mut block = [0_u8; 1_024];
                let count = stream.read(&mut block).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&block[..count]);
                if let Some(index) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                    break index + 4;
                }
            };
            let headers = std::str::from_utf8(&request[..header_end]).unwrap();
            assert!(headers.starts_with("POST /v1/account/group/discover HTTP/1.1\r\n"));
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length: ")
                        .map(str::parse::<usize>)
                })
                .unwrap()
                .unwrap();
            while request.len() - header_end < length {
                let mut block = [0_u8; 1_024];
                let count = stream.read(&mut block).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&block[..count]);
            }
            let envelope =
                SignedEnvelope::decode_canonical_json(&request[header_end..header_end + length])
                    .unwrap();
            envelope.verify().unwrap();
            assert_eq!(
                envelope.payload,
                br#"{"accessToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","audience":"com.zensystech.dropmesh","purpose":"dropmesh.account.group.discover.v1"}"#
            );
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 19\r\nConnection: close\r\n\r\n{\"status\":\"absent\"}",
                )
                .await
                .unwrap();
        });

        let identity = TestIdentity::seeded(29);
        let client = AccountEnrollmentClient::new_with_policy(
            &format!("http://{address}"),
            "com.zensystech.dropmesh",
            true,
        )
        .unwrap();
        let discovery = client
            .discover(
                &identity,
                &[7; 32],
                1_800_000_000_000,
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "11111111-1111-1111-1111-111111111111",
            )
            .await
            .unwrap();
        assert_eq!(discovery, dropmesh_account::AccountDiscovery::Absent);
        server.await.unwrap();
    }

    #[test]
    fn production_origins_are_https_or_wss_without_ambient_url_parts() {
        assert!(SignedHttpClient::new("http://example.test").is_err());
        assert!(SignedHttpClient::new("https://user@example.test").is_err());
        assert!(SignedHttpClient::new("https://example.test?query=1").is_err());
        assert!(SignedHttpClient::new("https://example.test").is_ok());
    }
}

//! The listener's identity and the secrets it checks: a self-signed certificate that a paired
//! Mac pins by fingerprint, and the bearer tokens it hands out, of which only a hash is kept.

use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use ring::rand::{SecureRandom, SystemRandom};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{ring::default_provider, verify_tls13_signature, CryptoProvider},
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    DigitallySignedStruct, SignatureScheme,
};
use sha2::{Digest, Sha256};

/// The certificate and its private key, both DER.
pub(crate) struct Identity {
    pub cert: Vec<u8>,
    pub key: Vec<u8>,
}

impl Identity {
    /// A new self-signed certificate. Its validity dates are rcgen's wide defaults: a paired Mac
    /// trusts it by fingerprint, never by date or name.
    pub fn generate(instance_id: Option<&str>) -> Result<Self> {
        let name = format!("cascade-{}", instance_id.unwrap_or("host"));
        let certified = rcgen::generate_simple_self_signed(vec![name]).context("make the remote certificate")?;
        Ok(Self { cert: certified.cert.der().to_vec(), key: certified.signing_key.serialize_der() })
    }

    pub fn fingerprint(&self) -> String {
        fingerprint(&self.cert)
    }

    /// TLS 1.3 only, no client certificates: a client proves itself with its token.
    pub fn server_config(&self) -> Result<rustls::ServerConfig> {
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.key.clone()));
        rustls::ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .with_no_client_auth()
            .with_single_cert(vec![CertificateDer::from(self.cert.clone())], key)
            .context("load the remote certificate")
    }
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(default_provider())
}

/// SHA-256 of a certificate's DER, lowercase hex.
pub(crate) fn fingerprint(der: &[u8]) -> String {
    hex(&Sha256::digest(der))
}

/// A new bearer token: 32 random bytes, hex.
pub(crate) fn token() -> Result<String> {
    let mut bytes = [0u8; 32];
    SystemRandom::new().fill(&mut bytes).map_err(|_| anyhow::anyhow!("no randomness for a remote token"))?;
    Ok(hex(&bytes))
}

/// What is stored for a token, and what a presented one is looked up by.
pub(crate) fn digest(token: &str) -> String {
    hex(&Sha256::digest(token.as_bytes()))
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(crate) fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len()).step_by(2).map(|at| u8::from_str_radix(text.get(at..at + 2)?, 16).ok()).collect()
}

/// A client's TLS configuration that trusts exactly the certificate with `fingerprint`, whatever
/// name or dates it carries. A paired Mac connects with this.
pub(crate) fn pinned_client_config(fingerprint: &str) -> Result<rustls::ClientConfig> {
    client_config(Pinned { fingerprint: Some(fingerprint.to_owned()), seen: Arc::default(), provider: provider() })
}

/// For pairing's first request only: any certificate is taken, as long as the server holds its
/// key, and its fingerprint is kept in `seen`. Pairing then proves it is the one the host sent
/// (`pairing`), and every later connection pins it.
pub(crate) fn observing_client_config(seen: Arc<Mutex<Option<String>>>) -> Result<rustls::ClientConfig> {
    client_config(Pinned { fingerprint: None, seen, provider: provider() })
}

fn client_config(verifier: Pinned) -> Result<rustls::ClientConfig> {
    Ok(rustls::ClientConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth())
}

#[derive(Debug)]
struct Pinned {
    /// None takes any certificate.
    fingerprint: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let presented = fingerprint(end_entity);
        if self.fingerprint.as_ref().is_some_and(|pinned| *pinned != presented) {
            return Err(rustls::Error::General("not the paired Mac's certificate".into()));
        }
        // The handshake goes on to check the server signs with this certificate's key.
        *self.seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(presented);
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 is not offered".into()))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

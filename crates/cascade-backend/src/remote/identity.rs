//! The listener's identity and the secrets it checks: a self-signed certificate that a paired
//! Mac pins by fingerprint, and the bearer tokens it hands out, of which only a hash is kept.

use std::sync::Arc;

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

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A client's TLS configuration that trusts exactly the certificate with `fingerprint`, whatever
/// name or dates it carries. A paired Mac connects with this; pairing and the client side use it
/// from the next phase on (docs/remote/05-mac-to-mac.md).
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn pinned_client_config(fingerprint: &str) -> Result<rustls::ClientConfig> {
    let verifier = Arc::new(Pinned { fingerprint: fingerprint.to_owned(), provider: provider() });
    Ok(rustls::ClientConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth())
}

#[derive(Debug)]
struct Pinned {
    fingerprint: String,
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
        if fingerprint(end_entity) == self.fingerprint {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("not the paired Mac's certificate".into()))
        }
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

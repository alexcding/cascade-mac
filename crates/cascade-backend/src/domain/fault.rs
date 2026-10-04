/// What a failed sync says about the service it asked. `Transient`: the service could not be
/// reached or would not answer for now (a timeout, the network, a 5xx, a rate limit), which is
/// nobody's to fix and passes. `Permanent`: it answered, and the request is what is wrong (a
/// repository that is gone, a sign-in that lapsed), which stays wrong until someone changes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    Transient,
    Permanent,
}

/// What a command-line client prints, lowercased, when the network or the service is failing
/// for now: `gh` and `acli` word the network's errors as Go does, `curl` in its own words, and
/// all of them name the HTTP status. Every sign has a space in it: a refusal echoes the name
/// it refused (`Could not resolve to a Repository with the name 'owner/p-timeout'`), and a
/// repository or branch name, which has none, must not read as an outage.
const TRANSIENT_SIGNS: [&str; 24] = [
    "timed out",
    "i/o timeout",
    "handshake timeout",
    "timeout awaiting",
    "deadline exceeded",
    "error connecting",
    "failed to connect",
    "connection refused",
    "connection reset",
    "network is unreachable",
    "no such host",
    "could not resolve host",
    "dial tcp",
    "tls handshake",
    "unexpected eof",
    "http 500",
    "http 502",
    "http 503",
    "http 504",
    "http 429",
    "bad gateway",
    "service unavailable",
    "gateway time",
    "rate limit",
];

impl Fault {
    /// Read from what a failed call said. What is not recognised is permanent, so an error
    /// nobody anticipated is shown rather than waited out in silence.
    pub fn read(message: &str) -> Fault {
        let text = message.to_ascii_lowercase();
        if TRANSIENT_SIGNS.iter().any(|sign| text.contains(sign)) {
            Fault::Transient
        } else {
            Fault::Permanent
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failing_network_or_service_is_transient_and_a_refused_request_is_not() {
        for message in [
            "gh timed out after 20s",
            "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com",
            "Post \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: no such host",
            "gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)",
            "gh: API rate limit exceeded for user ID 1.",
            "curl: (6) Could not resolve host: example.atlassian.net",
            "API request failed with HTTP 503",
        ] {
            assert_eq!(Fault::read(message), Fault::Transient, "{message}");
        }
        for sign in TRANSIENT_SIGNS {
            assert!(sign.contains(' '), "{sign:?} could be part of a name a refusal echoes");
        }
        for message in [
            "gh: Could not resolve to a Repository with the name 'owner/p-timeout'.",
            "gh: Could not resolve to a Repository with the name 'ratelimit/eof-502'.",
            "gh: Could not resolve to a Repository with the name 'owner/gone'.",
            "gh: Not Found (HTTP 404)",
            "To get started with GitHub CLI, please run:  gh auth login",
            "API request failed with HTTP 401",
            "unexpected gh graphql response for owner/repo (no pullRequests connection)",
        ] {
            assert_eq!(Fault::read(message), Fault::Permanent, "{message}");
        }
    }
}

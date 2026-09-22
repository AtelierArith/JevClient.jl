# Security policy

JevClient.jl is an unofficial Julia client for TypeSafe AI. It is designed to
keep API keys and request data out of ordinary logs and exceptions, but it
cannot protect secrets from a compromised process, Julia runtime, TLS stack,
operating system administrator, or memory dump. Julia strings and HTTP/TLS
dependencies may retain immutable copies of data.

Do not commit API keys, `.env` files, request bodies, or live credentials. If a
key may have leaked, revoke and reissue it in TypeSafe immediately, remove it
from git history, CI logs, and artifacts, and investigate application and
monitoring logs. JevClient.jl does not provide a key-revocation API.

The regular TypeSafe API must not be described as zero data retention. Confirm
current provider privacy, DPA, and data residency terms before sending sensitive
data. Minimize, redact, or pseudonymize state at the application boundary.

Please report security issues privately through the repository's configured
vulnerability reporting channel. Include the affected version, a minimal
reproduction that contains no secrets, and the impact. Do not include API keys,
request bodies, response bodies, or customer data in a report.

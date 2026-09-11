# Email account flow checks

These checks compile the production service and state machine unchanged on macOS. `Support.swift` replaces networking, session persistence, localization and hashing; they are **not** full app or backend tests. Existing `CryptoUtilTests` cover the real double-MD5 implementation. UI, actual Keychain persistence and backend contracts need the app build and device checklist.

Run from the repository root:

```sh
xcrun swiftc -parse-as-library -module-cache-path /tmp/hily-email-module-cache \
  Sources/Auth/Email/EmailAccountService.swift \
  Sources/Auth/Email/EmailAccountStore.swift \
  Tests/EmailAccountHarness/Support.swift \
  Tests/EmailAccountHarness/EmailAccountChecks.swift \
  -o /tmp/hily-email-checks
/tmp/hily-email-checks
```

Coverage includes anonymous/authenticated endpoint separation, malformed ticket/token responses, email normalization, legacy passwords, new password limits, confirmation matching, resend deadlines, REGISTER/REBIND ticket lifetimes, expiry recovery, confirmation before sending to a new email, feedback limits, repeated submissions and stale-session responses.

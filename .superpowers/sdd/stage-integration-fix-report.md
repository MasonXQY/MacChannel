# Stage integration fix: local-network policy denial while waiting

## Scope

- Fix commit: `cae8b78575339e6e5f4666f58139b6cc4e3642c4`
- Base: `52f3b0758652c0135b91ac3f6f3e26ffced40337`
- Changed production code only in `BonjourPeerBrowser.swift`; no privacy, plan, progress, installer, remote-user, or server changes.

## Root cause and fix

`NWBrowser` and `NWListener` sent local-network privacy denial as
`.waiting(.dns(kDNSServiceErr_PolicyDenied))`. Their shared production callbacks
handled policy denial only under `.failed`, leaving lifecycle state and owned
resources active. Both callbacks now route only policy-denied waiting through
their existing failure transition and cleanup. Other waiting errors remain
pending. Generation checks remain unchanged.

## TDD evidence

RED command:

```sh
swift test --filter 'DeviceDirectoryTests/testBonjour(BrowserPolicyDeniedWaitingEndsOwnedSessionAndRetryReachesReady|AdvertiserPolicyDeniedWaitingCanRetryWhileTransientWaitingStaysPending)'
```

Before the fix: 2 tests executed, 5 assertion failures. Both policy-denied
waiting callbacks remained `starting`; the browser LAN sighting remained
active, and retry could not reach `ready`.

GREEN command:

```sh
swift test --filter 'OnboardingTests/testPolicyDeniedWaitingShowsSettingsGuidanceAndExplicitRetryRecovers|DeviceDirectoryTests/testBonjour'
```

Result: 13 tests executed, 0 failures. This covers real `NWBrowser.State.waiting`
and `NWListener.State.waiting` values through the production handlers, denial
guidance, browser session cleanup, explicit retry to ready, stale generation
rejection, ordinary transient waiting, and preservation of independent internet
presence.

Focused runtime/conflict command:

```sh
swift test --filter 'ConcurrentDistributionGuardTests|AppRuntimeTests/test(FailedInitialPublicConnectRetriesWithoutRebuildingLocalRuntime|ConcurrentReconnectRequestsStartFreshConnectionWithoutOverlap|RuntimeBootstrapDoesNotStartLocalNetworkUntilRelevantAction|StoreRelaunchRestoresOnlyPersistedLocalNetworkActivation)'
```

Result: 10 tests executed, 0 failures. Public-service retry/status behavior,
local-network activation boundaries, and runtime conflict teardown/retry remain
independent and green.

`git diff --check` also completed with no errors before the fix commit.

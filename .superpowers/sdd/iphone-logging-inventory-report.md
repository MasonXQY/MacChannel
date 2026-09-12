# iPhone default logging inventory report

## Outcome

Implemented the bounded default logging inventory change from base
`b5445e2faa5978209725bebafea38b35d631d368`. The no-argument sensitive logging
scanner now recursively includes `iPhone` Swift production sources and excludes
only the exact `iPhone/Tests` subtree. Existing sink rules and exact exemptions
were not changed.

The current inventory contains 26 production Swift files below `iPhone` and 16
test Swift files below `iPhone/Tests`.

## TDD evidence

RED, before changing the scanner:

```text
$ bash -n Scripts/test-sensitive-logging-contract.sh && bash Scripts/test-sensitive-logging-contract.sh
sensitive logging scan accepted a iPhone/App mutation
exit 1
```

This was the expected failure: the old no-argument scanner did not inventory any
native iPhone source path, so it accepted the synthetic production violation.

GREEN, after adding recursive iPhone inventory with the exact test-subtree
exclusion:

```text
$ bash -n Scripts/check-sensitive-logging.sh && bash -n Scripts/test-sensitive-logging-contract.sh && bash Scripts/test-sensitive-logging-contract.sh
sensitive logging default-scan contract PASS
exit 0
```

The contract inserts temporary sensitive `print` mutations in `iPhone/App`,
`iPhone/ShareExtension`, and `iPhone/Shared`; each must make the default scanner
fail. It also proves a production directory whose name contains `Tests` remains
audited, while a fixture inside the exact `iPhone/Tests` subtree is excluded.
Cleanup tracks the exact temporary file and directory and leaves no mutants.

## Required verification

```text
$ bash -n Scripts/check-sensitive-logging.sh
exit 0
$ bash -n Scripts/test-sensitive-logging-contract.sh
exit 0
$ bash Scripts/test-sensitive-logging-contract.sh
sensitive logging default-scan contract PASS
$ bash Scripts/test-privacy-audit.sh
privacy logging mutants PASS
$ bash Scripts/audit-privacy.sh --static-only
privacy STATIC PASS: schema, sensitive-log mutants, Store manifest draft, and coturn persistence contract
$ bash Scripts/check-sensitive-logging.sh
sensitive logging contract PASS
$ git diff --check
exit 0
```

Post-test inspection found no `SensitiveLogging*` files or
`TestsNearbyProduction.*` directories below `iPhone`.

## Files changed

- `Scripts/check-sensitive-logging.sh`
- `Scripts/test-sensitive-logging-contract.sh`
- `.superpowers/sdd/iphone-logging-inventory-report.md`

## Self-review and limits

- The exclusion is anchored to `$repository_root/iPhone/Tests/*`; there is no
  generic path or filename exemption containing `Tests`.
- Existing scanner patterns, shell fixture filters, and exact exceptions are
  unchanged.
- No app/Core/wire/Mac/Store/signing/installed source was changed, and no broad
  SwiftPM or Xcode build was run.
- Static checks do not prove production collection or runtime privacy. The
  runtime audit remains deliberately BLOCKED because trusted producer and
  verifier support are not implemented.
- Independent review was requested but could not start because all agent slots
  were occupied. The coordinator must complete independent review before
  marking the gate complete.

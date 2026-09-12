# History/settings review b12bb48..f79d749

Independent reviewer iphone_native_history_review: Spec incomplete; quality Needs fixes.

Important: Home incoming-completion invalidation is missing. MobileHistoryModel
69-76 only watches completed coordinator transfers, but actual runtime
MobileForegroundRuntime.receiveFinished453-463 records durable receive history,
appends received and publishes without changing transfers. Production snapshot41-45
forwards no receive signal. Add minimal signal forwarding and a real-path regression
with transfers unchanged; retain durable history as truth, not session arrays.

Reviewed strengths: fresh ID-based action resolution, no URL in history projection,
stale read suppression and close ownership, unavailable records retained, native
presentation without delivery callbacks, private discovery persistence before apply,
bundle-derived version and truthful capability wording. Existing simulated coordinator
completion test misses incoming path. Known AppIntents warning retained in final ledger.

Reviewer read frozen diff once plus bounded runtime listener/coordinator/receive
outside check; no writes or duplicate test execution. Physical interoperability,
Files/QuickLook/system share and signing remain separate unverified gates.

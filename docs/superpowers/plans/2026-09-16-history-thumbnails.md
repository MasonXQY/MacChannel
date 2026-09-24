# History thumbnails implementation plan

Approved design: replace history type icons with real small previews where safely
available; images, video frames, system-supported document first pages; batch
stack and count. Retain type icon when unavailable. No list-time authorization,
network Photos export, permanent payload cache, or protocol/Mac behavior changes.

- [ ] Session/source path: passive `historyThumbnail(for:itemID:)` returning a
  small immutable image. Validate deletion, bookmark access and existing Photos
  authorization; never call explicit-action source export while scrolling.
- [ ] Model: try up to three available batch items, including sent records;
  reject late results after deletion/close. Existing legacy received image path
  remains. Regression tests prove outbound and batch selection and invalidation.
- [ ] View: fixed 48pt rounded thumbnail, batch stack/count, type fallback; reuse
  existing preview taps and no new permissions. Test fixture and screenshot.
- [ ] Run app unit/UI regression tests, independent review, device build,
  overwrite install connected phone without reset; record actual limitations.

# v0.1.0

## 09 Sep 2026

### What's Included
- remove stale reference
- Merge ESA-X-010: draft preview grid must be source of truth for listing files
- add
- Add tests/test_draft_job_manifest.py — ESA-X-010 route-level coverage
- Repoint existing /post-draft tests at the new media_manifest body
- Rewrite staged_files to the sent manifest at Tier 1 success
- post_draft reads media_manifest/digital_manifest instead of disk-scanning
- Add resolve_manifest() — ordered staged/static manifest resolution
- list_staged_files() now includes file_id in each returned entry
- remove doco on code level
- update claudemd
- Close the build at M7; mark M8 out of scope
- Merge module M7: Listings, Scheduling, Notifications, background threads
- M7: Listings, Scheduling, Notifications, background threads
- Merge module M6: Draft Job posting engine
- M6: Draft Job posting engine
- Reconcile M6's doc against M5's shipped code
- Merge module M5: Draft Job resource
- M5: Draft Job resource
- Reconcile M5's doc against M2-M4's actual shipped code
- Merge module M4: Files, Reference, Listing Draft Tooling
- M4: Files, Reference, Listing Draft Tooling
- Reconcile M4's doc against M2/M3's actual shipped code
- Merge module M3: Multi-shop plumbing, Shops endpoints, Etsy OAuth
- progress-tracker.md: mark M3 COMPLETE
- M3: Multi-shop plumbing, Shops endpoints, Etsy OAuth
- Add end-of-module summary format and no-ff merge-back instructions
- Reconcile M3's doc against M2's shipped code; fix curl basepath bug in both
- progress-tracker.md: codify local-develop-tracking as an explicit git rule
- M2: ESA Auth (JWT), Account (/me, /config), Admin API
- fewcoco-core.md: reflect Phase 0 completion and Module 1's resolved open items
- Reconcile M2/M4 docs and openapi.yaml against Phase 0's shipped implementation
- M1: mark COMPLETE in progress tracker
- M1: repo skeleton, config, app factory, health
- initial


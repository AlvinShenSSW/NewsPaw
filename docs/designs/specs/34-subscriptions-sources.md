# U02 / #34 — native subscription and source management

Closes #34

The existing Subscriptions & Sources page retains its category cards and adds settings for individual subscriptions and sources. An ordinary regional category can have independent domestic and entertainment subscriptions with their own times, target Bots, source selection and item caps. Optional topic weights use explicit source classification, omit muted topics and prioritize retained evidence without filling missing coverage. Unknown sources remain unclassified until assigned.

Explicit source selection is distinct from category inheritance. An empty explicit selection remains empty and can only be saved inactive. Existing documents retain their original selection behavior. New and incomplete subscriptions can be saved as inactive drafts. The category switch pauses all active subscriptions in that category after confirmation at the displayed revision. Turning it on opens the subscription route preview. A category with several subscriptions asks which one to review. Activation requires a separate action after a current route preview, with actual source readiness, verified model slots, live Bot binding and a schedule. Edits are revision checked and preserve the existing scheduler’s activation boundary.

The source editor reads the actual backend catalog, identifies pasted links on request, saves inactive records and runs a separate collection preview. It displays the observed counts, dates, freshness and coverage. Suggested or discovered entries do not imply a verified source. Pause and removal show scoped impact and require a matching revision. An explicitly selected OPML file is read with a byte limit and imported as inactive drafts with added, duplicate and rejected counts.

Three-language Swift contracts, actual socket smoke and the Python source, routing, scheduling and revision tests cover the workflow. The approved mockup stays unchanged. Visual operation of the new sheets remains a separate macOS desktop check.

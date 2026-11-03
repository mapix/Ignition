# Service tags (1.2.0)

- Create colored tags from the sidebar's Manage Tags entry or from a service's Edit Tags action.
- Assign any number of tags to one or multiple services, including protected system services.
- The sidebar filters by a tag across launchd domains. Untagged shows services without tags.
- Status and search filters combine with the selected tag.
- Tags appear in service rows and details. Tags can be renamed or removed.
- Assignment identity is the explicit launchd domain plus service label, so same-name GUI and system jobs remain distinct and runtime registrations retain their tags.
- Tags are local metadata in the app's Application Support tags.json file; tag actions do not change plist files or launchd state.
- Deleted/recovered services retain their tag associations. Removing a tag removes its associations and clears that tag's active filter.

## Verification

The tests/run-tags.sh runner passed 17 checks for creation, assignment, batch updates, same-name domain separation, runtime identity, system-service tagging, tag/untagged filters, rename, persistence, validation, private storage permissions, deletion and retention of unreadable storage.

Native QA used two unloaded fixture services with separate preferences, agent folder and storage. Creating and applying a tag displayed it in the service row, details and sidebar. Selecting the tag displayed only the matching service.

The native bulk action showed a mixed tag state for two services; selecting the checkbox applied it to both and updated the sidebar count to two. Tags also remained visible after restarting the QA app.

Release build and local installation: 1.2.0, build 3.

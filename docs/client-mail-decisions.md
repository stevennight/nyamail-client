# Client Mail Decisions

- NyaMail stays local-first: the client talks to mail providers directly, and the self-hosted server is for encrypted vault sync, devices, and updates.
- The app UI is the product surface; there is no separate web portal or marketing site in this client repo.
- Message lists load cached headers and previews first, then refresh remotely; full bodies and attachments load when a message is opened.
- Search applies automatically after a short debounce and can still be submitted explicitly.
- Load-more uses mailbox cursors instead of refetching the first page.
- Smart folders aggregate accounts, while account folders remain available under each mailbox account.
- Mail rendering uses a sanitized WebView document: scripts are blocked, remote images are opt-in, and external styles/fonts can be allowed once per message.
- Archive, delete, and move use a short local undo window before committing to the provider; permanent delete from Trash is not implemented yet.
- On mobile, archive, delete, and move from the message detail view return to the list after the local action is applied.
- Release builds should use `scripts/build-release.ps1` so Windows and Android artifacts keep stable names and paths.
- Automated checks should not require a real mailbox unless a user explicitly asks for live smoke testing.
- Smart Inbox: incoming views bundle automated notifications and newsletters (classified from headers and sender) instead of interleaving them with mail from people; it can be turned off.
- Notification bursts (more than three new messages in one refresh) collapse into one summary notification.

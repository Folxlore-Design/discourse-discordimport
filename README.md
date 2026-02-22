# discourse-discordimport

A Discourse plugin that imports [DiscordChatExporter](https://github.com/Tyrrrz/DiscordChatExporter) JSON archives into Discourse topics.

## Features

- Upload a `.zip` or `.tar.gz` archive exported by DiscordChatExporter
- Automatically identifies channels and threads from the archive
- Per-channel control: skip, import into an existing topic, or create a new topic
- Thread handling per channel: split threads into their own topics, or merge them into the primary topic
- Per-user mapping: match Discord users to Discourse accounts, or mark them as Anonymous or Omit
- Preserves original message timestamps
- Renders image attachments inline, other file attachments as links
- Shows emoji reactions at the bottom of each post
- Confirmation modal before any data is written

## Requirements

- Discourse 3.x+
- [DiscordChatExporter](https://github.com/Tyrrrz/DiscordChatExporter) — use JSON export format
- A server rebuild is required after installation (this is a plugin, not a theme component)

## Installation

### Via app.yml (recommended)

Add to your `/var/discourse/containers/app.yml` under `hooks.after_code`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/Folxlore-Design/discourse-discordimport.git
```

Then rebuild:

```bash
cd /var/discourse
sudo ./launcher rebuild app
```

### Manual

Copy the plugin folder to `/var/discourse/shared/standalone/plugins/discourse-discordimport/` on the host machine and rebuild.

## Usage

### 1. Export from Discord

Use DiscordChatExporter to export the channel(s) you want to import. Export in **JSON** format. If the channel has threads you want to include, export those too — each thread is a separate JSON file.

Zip all the JSON files together into a single `.zip` or `.tar.gz` archive.

### 2. Open the import tool

In Discourse, go to **Admin → Plugins → Discord Import**.

### 3. Analyze the archive

Upload your archive and click **Analyze Archive**. The plugin will identify all channels and threads inside and list all Discord users found across the export.

### 4. Configure channels

For each channel found, choose an action:

| Action | Behavior |
|--------|----------|
| **Skip** | Don't import this channel |
| **Add to existing topic** | Append messages to an existing Discourse topic (enter the topic ID) |
| **Create new topic** | Create a new topic (pre-filled title from channel name, choose a category) |

If a channel has threads, an additional option appears:

- **Split threads into separate topics** — each thread becomes its own new topic in the same category as the primary topic
- Unchecked — thread messages are appended to the primary topic, each prefaced by a `--- Thread: "name" ---` separator post

### 5. Map users

Each Discord user found in the export is listed. For each one, choose:

- **A Discourse user** — search by username; messages are posted as that user
- **Anonymous** — messages are posted under a shared `discordimport_anonymous` account (created if it doesn't exist)
- **Omit** — messages from this Discord user are skipped entirely

### 6. Confirm and import

Click **Import…**, review the summary in the confirmation modal, and click **Yes, Import**. The import runs synchronously — for large exports this may take a moment.

Results are shown when complete, with links to each created or updated topic.

## How exports are parsed

- `channel.type == "GuildTextChat"` → treated as a channel
- `channel.type == "GuildPublicThread"` or `"GuildPrivateThread"` → treated as a thread, grouped under its parent channel via `channel.categoryId`
- Messages are filtered: bot messages and non-`Default` type messages (system events, thread creation notices, etc.) are skipped
- Original timestamps are preserved via Rails `PostCreator` with `skip_validations: true`

## License

MIT

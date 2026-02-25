# frozen_string_literal: true

module DiscourseDiscordimport
  class DiscordImporter
    CHANNEL_TYPES = %w[GuildTextChat GuildNews GuildForum].freeze
    THREAD_TYPES  = %w[GuildPublicThread GuildPrivateThread GuildNewsThread].freeze

    # ---------------------------------------------------------------------------
    # analyze(exports) → hash describing what's in the archive
    #
    # exports: array of parsed JSON hashes, one per file in the archive
    # ---------------------------------------------------------------------------
    def self.analyze(exports)
      channels_by_id   = {}
      channels_by_name = {}
      pending_threads  = []

      # Pass 1: identify top-level channels by type
      exports.each do |export|
        ch = export["channel"]
        next unless ch
        next unless CHANNEL_TYPES.include?(ch["type"])

        messages = export["messages"] || []
        importable, skipped = count_messages(messages)
        entry = {
          channel_id:    ch["id"],
          channel_name:  ch["name"],
          guild_name:    export.dig("guild", "name"),
          message_count: importable,
          skipped_count: skipped,
        }.merge(threads: [])
        channels_by_id[ch["id"]]               = entry
        channels_by_name[ch["name"]]           = entry
        channels_by_name[ch["name"].downcase]  = entry
      end

      # Pass 2: everything else is a potential thread.
      # Files with unknown channel.type (not in CHANNEL_TYPES) were silently dropped
      # by the old single-pass approach — this catches them all.
      exports.each do |export|
        ch = export["channel"]
        next unless ch
        next if CHANNEL_TYPES.include?(ch["type"])

        messages = export["messages"] || []
        importable, skipped = count_messages(messages)
        pending_threads << {
          channel_id:        ch["id"],
          channel_name:      ch["name"],
          guild_name:        export.dig("guild", "name"),
          message_count:     importable,
          skipped_count:     skipped,
          parent_channel_id: ch["categoryId"],
          file_name:         export["_file_name"],
        }
      end

      # Nest threads under their parent channels.
      # Primary match: categoryId == channel id.
      # Fallback: parse parent channel name from DiscordChatExporter filename
      #   format "Guild - ChannelName - ThreadName [id].json"
      pending_threads.each do |thread|
        parent = channels_by_id[thread[:parent_channel_id]]

        if parent.nil? && thread[:file_name]
          parent_name = extract_parent_channel_name(thread[:file_name])
          if parent_name
            parent = channels_by_name[parent_name] || channels_by_name[parent_name.downcase]
          end
        end

        if parent
          parent[:threads] << thread.slice(:channel_id, :channel_name, :message_count, :skipped_count)
        else
          # Orphaned thread — treat as standalone channel with no threads
          channels_by_id[thread[:channel_id]] = thread.slice(
            :channel_id, :channel_name, :guild_name, :message_count, :skipped_count
          ).merge(threads: [])
        end
      end

      users = collect_users(exports)

      {
        channels: channels_by_id.values,
        users:    users,
      }
    end

    # ---------------------------------------------------------------------------
    # import(exports, channel_configs, user_mappings, duplicate_mode:) → results hash
    #
    # channel_configs: array of hashes (action, channel_id, topic_id, etc.)
    # user_mappings:   { discord_user_id => discourse_user_id | "omit" | "anonymous" }
    # duplicate_mode:  "ignore" | "update"
    # ---------------------------------------------------------------------------
    def self.import(exports, channel_configs, user_mappings, duplicate_mode: "ignore")
      # Index exports by channel id for fast lookup
      exports_by_channel_id = {}
      exports.each do |export|
        id = export.dig("channel", "id")
        exports_by_channel_id[id] = export if id
      end

      results = []

      channel_configs.each do |config|
        log           = []
        channel_id    = config["channel_id"]
        action        = config["action"]
        split_threads = config["split_threads"] == true || config["split_threads"] == "true"

        main_export = exports_by_channel_id[channel_id]
        unless main_export
          log << "ERROR: No export found for channel #{channel_id}"
          results << { channel_name: channel_id, posts_created: 0, posts_skipped: 0,
                       posts_updated: 0, thread_results: [], log_lines: log }
          next
        end

        channel_name = main_export.dig("channel", "name")
        log << "=== ##{channel_name} ==="

        # Collect thread exports that belong to this channel.
        # Anything that isn't a top-level channel type is a candidate thread.
        # Primary match: categoryId == channel id.
        # Fallback: filename second segment matches channel name.
        thread_exports = exports.select do |e|
          next false if CHANNEL_TYPES.include?(e.dig("channel", "type"))
          e.dig("channel", "categoryId") == channel_id ||
            extract_parent_channel_name(e["_file_name"]) == channel_name
        end
        log << "Found #{thread_exports.size} thread export(s)" if thread_exports.any?

        # Resolve the primary topic
        topic, posts_created, posts_skipped, posts_updated =
          if action == "existing"
            t = Topic.find_by(id: config["topic_id"])
            raise "Topic #{config["topic_id"]} not found" unless t
            log << "Importing into existing topic: #{t.url}"
            created, skipped, updated = import_messages(
              main_export["messages"] || [],
              t.id,
              user_mappings,
              duplicate_mode: duplicate_mode,
              log: log,
            )
            [t, created, skipped, updated]
          else
            title = config["new_topic_title"] || main_export.dig("channel", "name")
            log << "Creating new topic: \"#{sanitize_title(title)}\""
            create_topic_from_export(
              main_export,
              title,
              config["new_topic_category_id"],
              user_mappings,
              duplicate_mode: duplicate_mode,
              log: log,
            )
          end

        unless topic
          log << "ERROR: Could not create or find topic — skipping channel"
          results << { channel_name: channel_name, posts_created: 0,
                       posts_skipped: posts_skipped.to_i, posts_updated: 0,
                       thread_results: [], log_lines: log }
          next
        end

        log << "Topic: #{topic.url}"
        log << "Messages: #{posts_created} imported, #{posts_skipped} skipped" \
               "#{posts_updated > 0 ? ", #{posts_updated} updated" : ""}"

        thread_results = []

        if split_threads
          # Build a lookup map of thread exports by channel id for quick access
          thread_exports_map = {}
          thread_exports.each { |te| thread_exports_map[te.dig("channel", "id")] = te }

          # Pass 1: handle threads that have a ThreadCreated marker in the main channel.
          # These get the origin message as the first post, plus a back-link in the parent.
          handled_thread_ids = {}
          (main_export["messages"] || []).each do |msg|
            next unless msg["type"] == "ThreadCreated"

            thread_channel_id = msg.dig("reference", "channelId")
            te = thread_exports_map[thread_channel_id]
            next unless te

            # Only use a Default message as origin. Some ThreadCreated markers are
            # self-referential (id == reference.channelId); those have no real origin message.
            origin_msg = (main_export["messages"] || []).find do |m|
              m["id"] == thread_channel_id && m["type"] == "Default"
            end

            thread_name = te.dig("channel", "name")
            log << "Thread (marker): \"#{thread_name}\""

            thread_topic, t_created, t_skipped, t_updated = import_thread_from_marker(
              thread_export:  te,
              origin_msg:     origin_msg,
              parent_topic:   topic,
              user_mappings:  user_mappings,
              duplicate_mode: duplicate_mode,
              log: log,
            )
            handled_thread_ids[thread_channel_id] = true

            if thread_topic
              log << "  → #{thread_topic.url} (#{t_created} posts, #{t_skipped} skipped)"
              thread_results << {
                thread_name:   thread_name,
                topic_id:      thread_topic.id,
                topic_url:     thread_topic.url,
                posts_created: t_created,
                posts_skipped: t_skipped,
                posts_updated: t_updated,
              }
            else
              log << "  → ERROR: thread topic could not be created"
            end
          end

          # Pass 2: file-based fallback for thread exports with no ThreadCreated marker
          # (e.g. the parent channel was not fully exported, or private threads).
          thread_exports.each do |te|
            next if handled_thread_ids.key?(te.dig("channel", "id"))

            thread_name = te.dig("channel", "name")
            log << "Thread (file): \"#{thread_name}\""

            thread_topic, t_created, t_skipped, t_updated = create_topic_from_export(
              te, thread_name, topic.category_id, user_mappings,
              duplicate_mode: duplicate_mode, log: log,
            )

            if thread_topic
              log << "  → #{thread_topic.url} (#{t_created} posts, #{t_skipped} skipped)"
              thread_results << {
                thread_name:   thread_name,
                topic_id:      thread_topic.id,
                topic_url:     thread_topic.url,
                posts_created: t_created,
                posts_skipped: t_skipped,
                posts_updated: t_updated,
              }
            else
              log << "  → ERROR: thread topic could not be created"
            end
          end
        else
          # Merge threads into primary topic in timestamp order
          sorted_threads = thread_exports.sort_by do |te|
            te.dig("messages", 0, "timestamp") || ""
          end

          sorted_threads.each do |te|
            thread_name = te.dig("channel", "name")
            messages    = te["messages"] || []
            log << "Merging thread: \"#{thread_name}\" (#{messages.size} messages)"

            # Create separator post — use first resolvable user in the thread
            separator_user = first_resolvable_user(messages, user_mappings)
            if separator_user
              safe_create_post(
                separator_user,
                topic_id: topic.id,
                raw: "*--- Thread: \"#{thread_name}\" ---*",
                created_at: DateTime.parse(messages.first["timestamp"]),
                log: log,
              )
            end

            t_created, t_skipped, t_updated = import_messages(
              messages, topic.id, user_mappings, duplicate_mode: duplicate_mode, log: log,
            )
            posts_created += t_created
            posts_skipped += t_skipped
            posts_updated += t_updated
          end
        end

        log << "=== Done: #{posts_created} imported, #{posts_skipped} skipped" \
               "#{posts_updated > 0 ? ", #{posts_updated} updated" : ""}" \
               "#{thread_results.any? ? ", #{thread_results.size} thread(s)" : ""} ==="

        results << {
          channel_name:   channel_name,
          topic_id:       topic.id,
          topic_url:      topic.url,
          posts_created:  posts_created,
          posts_skipped:  posts_skipped,
          posts_updated:  posts_updated,
          thread_results: thread_results,
          log_lines:      log,
        }
      end

      { results: results }
    end

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    def self.count_messages(messages)
      importable = 0
      skipped    = 0
      messages.each do |m|
        if importable_message?(m)
          importable += 1
        else
          skipped += 1
        end
      end
      [importable, skipped]
    end

    # Default = regular message; Reply = message that quotes another message.
    # Both are user-authored content and should be imported.
    def self.importable_message?(message)
      return false if message.dig("author", "isBot")
      %w[Default Reply].include?(message["type"])
    end

    def self.collect_users(exports)
      seen = {}
      exports.each do |export|
        (export["messages"] || []).each do |message|
          author = message["author"]
          next unless author
          next if author["isBot"]
          id = author["id"]
          next if seen[id]

          nickname = author["nickname"] || author["name"]
          suggested = find_suggested_user(author["name"], nickname)

          seen[id] = {
            discord_id:                  id,
            name:                        author["name"],
            nickname:                    nickname,
            avatar_url:                  author["avatarUrl"],
            suggested_discourse_user_id: suggested&.id,
            suggested_discourse_username: suggested&.username,
          }
        end
      end
      seen.values
    end

    def self.find_suggested_user(discord_name, nickname)
      User.find_by(username: discord_name) ||
        User.where("lower(name) = ?", nickname.downcase).first
    end

    def self.resolve_user(discord_user_id, user_mappings)
      mapping = user_mappings[discord_user_id]
      return nil if mapping.nil? || mapping == "omit"

      if mapping == "anonymous"
        User.find_by(username: "discordimport_anonymous") ||
          User.create!(
            username: "discordimport_anonymous",
            name: "Anonymous",
            email: "discordimport-anonymous@imported.invalid",
            password: SecureRandom.hex(20),
            staged: true,
            approved: true,
          )
      elsif mapping.is_a?(Hash) && mapping["type"] == "new"
        username = mapping["username"].to_s.strip
        return nil if username.empty?
        User.find_by(username: username) ||
          User.create!(
            username: username,
            name: username,
            email: "discord-#{discord_user_id}@imported.invalid",
            password: SecureRandom.hex(20),
            staged: true,
            approved: true,
          )
      else
        User.find_by(id: mapping.to_i)
      end
    end

    def self.first_resolvable_user(messages, user_mappings)
      messages.each do |m|
        next unless importable_message?(m)
        user = resolve_user(m.dig("author", "id"), user_mappings)
        return user if user
      end
      nil
    end

    # Download a Discord CDN attachment and re-upload it to Discourse.
    # Returns a Discourse Upload object, or nil if the download/upload fails.
    # Callers should always handle nil and fall back to the original URL.
    def self.upload_attachment(att, user, log: [])
      url      = att["url"].to_s
      filename = att["fileName"].presence || "attachment"
      return nil unless url.start_with?("https://") && user

      require "open-uri"
      ext      = File.extname(filename).presence || ".bin"
      tempfile = Tempfile.new(["discord-import-", ext])
      tempfile.binmode

      URI.open(url, "rb", read_timeout: 15, open_timeout: 10) do |remote|
        tempfile.write(remote.read)
      end
      tempfile.rewind

      upload = UploadCreator.new(tempfile, filename).create_for(user.id)
      if upload.persisted?
        upload
      else
        log << "  WARN: Upload failed for #{filename}: #{upload.errors.full_messages.join(", ")}"
        Rails.logger.warn("[DiscordImport] Upload failed for #{filename}: #{upload.errors.full_messages.join(", ")}")
        nil
      end
    rescue => e
      log << "  WARN: Could not upload #{filename}: #{e.message}"
      Rails.logger.warn("[DiscordImport] Could not upload attachment #{filename}: #{e.message}")
      nil
    ensure
      tempfile&.close
      begin; tempfile&.unlink; rescue nil; end
    end

    def self.format_content(message, user: nil, log: [])
      parts = []
      content = message["content"].to_s.strip
      parts << content unless content.empty?

      (message["attachments"] || []).each do |att|
        filename = att["fileName"].presence || "attachment"
        upload   = upload_attachment(att, user, log: log) if user

        if upload
          # UploadMarkdown checks filename extension for image detection and
          # includes pixel dimensions when available — the correct Discourse format
          parts << UploadMarkdown.new(upload).to_markdown
        else
          # Fallback to original Discord CDN URL (may expire, but better than nothing).
          # Check contentType AND filename extension — some exports omit contentType.
          is_image = att["contentType"]&.start_with?("image/") ||
                     att["fileName"].to_s.match?(/\.(png|jpe?g|gif|webp|svg|bmp|tiff?)\z/i)
          if is_image
            parts << "![#{filename}](#{att["url"]})"
          else
            parts << "[#{filename}](#{att["url"]})"
          end
        end
      end

      reactions = message["reactions"] || []
      if reactions.any?
        rxn_parts = reactions.map do |r|
          names = (r["users"] || []).map { |u| u["nickname"] || u["name"] }.join(", ")
          "#{r.dig("emoji", "name")} \u00d7#{r["count"]} (#{names})"
        end
        parts << "\n*Reactions: #{rxn_parts.join(" \u00b7 ")}*"
      end

      parts.join("\n\n")
    end

    def self.create_topic_from_export(export, title, category_id, user_mappings, duplicate_mode: "ignore", log: [])
      messages = export["messages"] || []
      total_importable = messages.count(&method(:importable_message?))

      # Find first importable message with a resolvable user to create the topic
      first_message = nil
      first_user    = nil
      messages.each do |m|
        next unless importable_message?(m)
        user = resolve_user(m.dig("author", "id"), user_mappings)
        next unless user
        first_message = m
        first_user    = user
        break
      end

      unless first_message
        log << "  WARN: No importable message with resolvable user — skipping"
        return [nil, 0, total_importable, 0]
      end

      content = format_content(first_message, user: first_user, log: log)
      if content.blank?
        log << "  WARN: First message content is blank — skipping"
        return [nil, 0, total_importable, 0]
      end

      discord_msg_id   = first_message["id"]
      existing_field   = discord_msg_id ? PostCustomField.find_by(name: "discord_message_id", value: discord_msg_id) : nil
      first_created    = 0
      first_skipped    = 0
      first_updated    = 0
      topic            = nil

      if existing_field
        topic = existing_field.post&.topic
        if duplicate_mode == "update" && topic
          existing_field.post.update_columns(raw: content, cooked: PrettyText.cook(content))
          first_updated = 1
        else
          first_skipped = 1
          log << "  Duplicate: first post already imported (#{duplicate_mode == "ignore" ? "skipping" : "recovering topic"})"
        end
      end

      unless topic
        post = safe_create_post(
          first_user,
          title:      sanitize_title(title),
          raw:        content,
          category:   category_id,
          created_at: DateTime.parse(first_message["timestamp"]),
          log:        log,
        )
        return [nil, 0, total_importable, 0] unless post

        PostCustomField.create!(post_id: post.id, name: "discord_message_id", value: discord_msg_id) if discord_msg_id
        topic         = post.topic
        first_created = 1
      end

      remaining = messages.reject { |m| m["id"] == first_message["id"] }
      created, skipped, updated = import_messages(
        remaining, topic.id, user_mappings, duplicate_mode: duplicate_mode, log: log,
      )

      [topic, first_created + created, first_skipped + skipped, first_updated + updated]
    end

    def self.import_messages(messages, topic_id, user_mappings, duplicate_mode: "ignore", log: [])
      created = 0
      skipped = 0
      updated = 0

      messages.each do |message|
        unless importable_message?(message)
          skipped += 1
          next
        end

        discord_msg_id = message["id"]
        existing_field = discord_msg_id ? PostCustomField.find_by(name: "discord_message_id", value: discord_msg_id) : nil

        if existing_field
          if duplicate_mode == "update"
            user = resolve_user(message.dig("author", "id"), user_mappings)
            unless user
              skipped += 1
              next
            end
            content = format_content(message, user: user, log: log)
            if content.blank?
              skipped += 1
              next
            end
            post = existing_field.post
            if post
              post.update_columns(raw: content, cooked: PrettyText.cook(content))
              updated += 1
            else
              skipped += 1
            end
          else
            skipped += 1
          end
          next
        end

        user = resolve_user(message.dig("author", "id"), user_mappings)
        unless user
          skipped += 1
          next
        end

        content = format_content(message, user: user, log: log)
        if content.blank?
          skipped += 1
          next
        end

        post = safe_create_post(
          user,
          topic_id:   topic_id,
          raw:        content,
          created_at: DateTime.parse(message["timestamp"]),
          log:        log,
        )

        if post
          PostCustomField.create!(post_id: post.id, name: "discord_message_id", value: discord_msg_id) if discord_msg_id
          created += 1
        else
          skipped += 1
        end
      end

      [created, skipped, updated]
    end

    # Create a thread topic using the origin message from the parent channel as the first post.
    # Appends a back-link to the origin post in the parent topic.
    # Falls back to create_topic_from_export when origin_msg is unavailable or unusable.
    def self.import_thread_from_marker(
      thread_export:, origin_msg:, parent_topic:, user_mappings:, duplicate_mode:, log: []
    )
      thread_channel_id = thread_export.dig("channel", "id")
      thread_name       = thread_export.dig("channel", "name")

      # In Discord, the thread channel ID equals the origin message's snowflake ID.
      # The origin message is imported as the thread's first post (not via import_messages),
      # so exclude it from the thread message list to avoid a duplicate.
      thread_messages = (thread_export["messages"] || []).reject { |m| m["id"] == thread_channel_id }

      created = 0
      skipped = 0
      updated = 0
      topic   = nil

      # Dedup: if we already imported this thread's origin post, recover the topic.
      existing_origin = PostCustomField.find_by(name: "discord_thread_origin", value: thread_channel_id)
      if existing_origin
        topic = existing_origin.post&.topic
        if topic
          log << "  Dedup: thread already imported → #{topic.url}"
        else
          log << "  Dedup: thread record found but topic is gone — skipping"
          return [nil, 0, 0, 0]
        end
      else
        if origin_msg
          preview = origin_msg["content"].to_s.slice(0, 60).gsub(/\s+/, " ").strip
          log << "  Origin: \"#{preview}#{origin_msg["content"].to_s.length > 60 ? "…" : ""}\""

          origin_user = resolve_user(origin_msg.dig("author", "id"), user_mappings)

          # Can't resolve user — fall back to file-based import (no special first post)
          unless origin_user
            log << "  WARN: Origin user unmapped — falling back to file-based import"
            return create_topic_from_export(
              thread_export, thread_name, parent_topic.category_id, user_mappings,
              duplicate_mode: duplicate_mode, log: log,
            )
          end

          content = format_content(origin_msg, user: origin_user, log: log)
          if content.blank?
            log << "  WARN: Origin message content is blank — falling back to file-based import"
            return create_topic_from_export(
              thread_export, thread_name, parent_topic.category_id, user_mappings,
              duplicate_mode: duplicate_mode, log: log,
            )
          end

          post = safe_create_post(
            origin_user,
            title:      sanitize_title(thread_name),
            raw:        content,
            category:   parent_topic.category_id,
            created_at: DateTime.parse(origin_msg["timestamp"]),
            log:        log,
          )
          return [nil, 0, thread_messages.count(&method(:importable_message?)), 0] unless post

          # Use discord_thread_origin (not discord_message_id) so it doesn't conflict with
          # the same message's post in the parent topic.
          PostCustomField.create!(post_id: post.id, name: "discord_thread_origin", value: thread_channel_id)
          topic   = post.topic
          created = 1
        else
          # No Default origin message — fall back to file-based import
          log << "  No origin message — using file-based import"
          return create_topic_from_export(
            thread_export, thread_name, parent_topic.category_id, user_mappings,
            duplicate_mode: duplicate_mode, log: log,
          )
        end
      end

      # Import remaining thread messages (each gets its own discord_message_id dedup)
      t_created, t_skipped, t_updated = import_messages(
        thread_messages, topic.id, user_mappings, duplicate_mode: duplicate_mode, log: log,
      )
      created += t_created
      skipped += t_skipped
      updated += t_updated

      # Append a back-link to the origin post in the parent topic.
      # The guard prevents duplicate links on re-import.
      if origin_msg
        origin_post_field = PostCustomField.find_by(name: "discord_message_id", value: origin_msg["id"])
        origin_post = origin_post_field&.post
        if origin_post && origin_post.topic_id == parent_topic.id
          link_suffix = "*→ Thread: [#{thread_name}](#{topic.url})*"
          unless origin_post.raw.include?(link_suffix)
            new_raw = "#{origin_post.raw.rstrip}\n\n#{link_suffix}"
            origin_post.update_columns(raw: new_raw, cooked: PrettyText.cook(new_raw))
            log << "  Back-link added to origin post"
          else
            log << "  Back-link already present"
          end
        else
          log << "  WARN: Could not find origin post in parent topic for back-link"
        end
      end

      [topic, created, skipped, updated]
    end

    def self.safe_create_post(user, log: [], **opts)
      PostCreator.create!(
        user,
        **opts,
        skip_validations: true,
        skip_guardian:    true,
      )
    rescue => e
      log << "  ERROR: Failed to create post: #{e.message}"
      Rails.logger.error("[DiscordImport] Failed to create post: #{e.message}")
      nil
    end

    # Truncate and clean a title to fit Discourse's max topic title length.
    # Discord thread names can be very long and contain arbitrary Unicode.
    def self.sanitize_title(title)
      title.to_s.strip.slice(0, SiteSetting.max_topic_title_length).presence || "Imported"
    end

    # DiscordChatExporter filenames follow the pattern:
    #   "Guild - ChannelName - ThreadName [id].json"
    # The second segment (index 1 after splitting on " - ") is the parent channel name.
    def self.extract_parent_channel_name(filename)
      return nil if filename.nil?
      base = File.basename(filename.to_s, ".json")
      parts = base.split(" - ")
      return nil unless parts.length >= 3
      parts[1]
    end
  end
end

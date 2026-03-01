# frozen_string_literal: true

module DiscourseDiscordimport
  class DiscordImporter
    CHANNEL_TYPES = %w[GuildTextChat GuildNews GuildForum].freeze
    THREAD_TYPES  = %w[GuildPublicThread GuildPrivateThread GuildNewsThread].freeze

    # ---------------------------------------------------------------------------
    # analyze(exports) → hash describing what's in the archive
    # ---------------------------------------------------------------------------
    def self.analyze(exports)
      channels_by_id   = {}
      channels_by_name = {}
      pending_threads  = []

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
        channels_by_id[ch["id"]]              = entry
        channels_by_name[ch["name"]]          = entry
        channels_by_name[ch["name"].downcase] = entry
      end

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
          channels_by_id[thread[:channel_id]] = thread.slice(
            :channel_id, :channel_name, :guild_name, :message_count, :skipped_count
          ).merge(threads: [])
        end
      end

      { channels: channels_by_id.values, users: collect_users(exports) }
    end

    # ---------------------------------------------------------------------------
    # import(exports, channel_configs, user_mappings, duplicate_mode:) → results
    # ---------------------------------------------------------------------------
    def self.import(exports, channel_configs, user_mappings, duplicate_mode: "ignore")
      exports_by_channel_id = exports.each_with_object({}) do |e, h|
        id = e.dig("channel", "id")
        h[id] = e if id
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

        messages = main_export["messages"] || []

        # Collect thread exports for this channel
        thread_exports = exports.select do |e|
          next false if CHANNEL_TYPES.include?(e.dig("channel", "type"))
          e.dig("channel", "categoryId") == channel_id ||
            extract_parent_channel_name(e["_file_name"]) == channel_name
        end
        thread_exports_by_id = thread_exports.each_with_object({}) do |te, h|
          h[te.dig("channel", "id")] = te
        end
        log << "Found #{thread_exports.size} thread export(s)" if thread_exports.any?

        # Identify message IDs that will become thread topic first posts.
        # These are excluded from the primary topic when split_threads is on.
        starter_ids = Set.new
        if split_threads
          messages.each do |msg|
            next unless msg["type"] == "ThreadCreated"
            origin_id = msg.dig("reference", "channelId")
            starter_ids.add(origin_id) if origin_id && thread_exports_by_id[origin_id]
          end
        end

        # Find or create the primary topic
        topic         = nil
        posts_created = 0
        posts_skipped = 0
        posts_updated = 0

        if action == "existing"
          topic = Topic.find_by(id: config["topic_id"])
          unless topic
            log << "ERROR: Topic #{config["topic_id"]} not found"
            results << { channel_name: channel_name, posts_created: 0, posts_skipped: 0,
                         posts_updated: 0, thread_results: [], log_lines: log }
            next
          end
          log << "Adding to existing topic: #{topic.url}"
        else
          title     = config["new_topic_title"].presence || channel_name
          first_msg = messages.find { |m| importable_message?(m) && !starter_ids.include?(m["id"]) }
          unless first_msg
            log << "ERROR: No importable messages for new topic"
            results << { channel_name: channel_name, posts_created: 0, posts_skipped: 0,
                         posts_updated: 0, thread_results: [], log_lines: log }
            next
          end
          log << "Creating topic: \"#{sanitize_title(title)}\""
          topic, posts_created, posts_skipped, posts_updated = create_topic_from_message(
            first_msg, title, config["new_topic_category_id"], user_mappings,
            duplicate_mode: duplicate_mode, log: log,
          )
          unless topic
            log << "ERROR: Could not create topic"
            results << { channel_name: channel_name, posts_created: 0, posts_skipped: 0,
                         posts_updated: 0, thread_results: [], log_lines: log }
            next
          end
          log << "Topic: #{topic.url}"
        end

        thread_results     = []
        handled_thread_ids = Set.new

        # Single pass through channel messages:
        #   ThreadCreated → create thread topic (split mode)
        #   importable, non-starter → add to primary topic
        messages.each do |msg|
          if msg["type"] == "ThreadCreated" && split_threads
            thread_channel_id = msg.dig("reference", "channelId")
            te = thread_exports_by_id[thread_channel_id]
            next unless te
            next if handled_thread_ids.include?(thread_channel_id)
            handled_thread_ids.add(thread_channel_id)

            thread_name = te.dig("channel", "name")
            log << "Thread: \"#{thread_name}\""

            # Origin message: the Default message whose ID == thread_channel_id.
            # nil for self-referential markers.
            origin_msg = messages.find { |m| m["id"] == thread_channel_id && m["type"] == "Default" }

            thread_topic, tc, ts, tu = import_thread(
              thread_export:  te,
              origin_msg:     origin_msg,
              category_id:    topic.category_id,
              user_mappings:  user_mappings,
              duplicate_mode: duplicate_mode,
              log:            log,
            )

            if thread_topic
              log << "  → #{thread_topic.url} (#{tc} posts, #{ts} skipped)"
              thread_results << {
                thread_name:   thread_name,
                topic_id:      thread_topic.id,
                topic_url:     thread_topic.url,
                posts_created: tc,
                posts_skipped: ts,
                posts_updated: tu,
              }
            else
              log << "  → ERROR: could not create thread topic"
            end

          elsif importable_message?(msg) && !starter_ids.include?(msg["id"])
            c, s, u = import_messages([msg], topic.id, user_mappings,
                                      duplicate_mode: duplicate_mode, log: log)
            posts_created += c
            posts_skipped += s
            posts_updated += u
          end
        end

        if split_threads
          # File-based threads: thread exports with no ThreadCreated marker in parent
          thread_exports_by_id.each do |tid, te|
            next if handled_thread_ids.include?(tid)

            thread_name = te.dig("channel", "name")
            log << "Thread (file): \"#{thread_name}\""

            thread_topic, tc, ts, tu = import_thread(
              thread_export:  te,
              origin_msg:     nil,
              category_id:    topic.category_id,
              user_mappings:  user_mappings,
              duplicate_mode: duplicate_mode,
              log:            log,
            )

            if thread_topic
              log << "  → #{thread_topic.url} (#{tc} posts, #{ts} skipped)"
              thread_results << {
                thread_name:   thread_name,
                topic_id:      thread_topic.id,
                topic_url:     thread_topic.url,
                posts_created: tc,
                posts_skipped: ts,
                posts_updated: tu,
              }
            else
              log << "  → ERROR: could not create thread topic"
            end
          end
        else
          # Merge mode: append thread messages to the primary topic in timestamp order
          thread_exports.sort_by { |te| te.dig("messages", 0, "timestamp") || "" }.each do |te|
            thread_name = te.dig("channel", "name")
            thread_msgs = te["messages"] || []
            log << "Merging thread: \"#{thread_name}\" (#{thread_msgs.size} messages)"

            separator_user = first_resolvable_user(thread_msgs, user_mappings)
            if separator_user && thread_msgs.any?
              safe_create_post(
                separator_user,
                topic_id:   topic.id,
                raw:        "*--- Thread: \"#{thread_name}\" ---*",
                created_at: DateTime.parse(thread_msgs.first["timestamp"]),
                log:        log,
              )
            end

            c, s, u = import_messages(thread_msgs, topic.id, user_mappings,
                                      duplicate_mode: duplicate_mode, log: log)
            posts_created += c
            posts_skipped += s
            posts_updated += u
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

    # Default = regular message; Reply = message that quotes another.
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

          nickname  = author["nickname"] || author["name"]
          suggested = find_suggested_user(author["name"], nickname)

          seen[id] = {
            discord_id:                   id,
            name:                         author["name"],
            nickname:                     nickname,
            avatar_url:                   author["avatarUrl"],
            suggested_discourse_user_id:  suggested&.id,
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
            name:     "Anonymous",
            email:    "discordimport-anonymous@imported.invalid",
            password: SecureRandom.hex(20),
            staged:   true,
            approved: true,
          )
      elsif mapping.is_a?(Hash) && mapping["type"] == "new"
        username = mapping["username"].to_s.strip
        return nil if username.empty?
        User.find_by(username: username) ||
          User.create!(
            username: username,
            name:     username,
            email:    "discord-#{discord_user_id}@imported.invalid",
            password: SecureRandom.hex(20),
            staged:   true,
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
    # Returns a Discourse Upload object, or nil on failure.
    def self.upload_attachment(att, user, log: [])
      url      = att["url"].to_s
      filename = att["fileName"].presence || "attachment"
      return nil unless url.start_with?("https://") && user

      # Discord CDN URLs contain an ex= hex Unix timestamp for the expiry time.
      # Check before connecting — expired URLs stall for the full open_timeout.
      if (ex_match = url.match(/[?&]ex=([0-9a-f]+)/i))
        if ex_match[1].to_i(16) < Time.now.to_i
          log << "  WARN: CDN link expired for #{filename} (use a fresh export to include attachments)"
          return nil
        end
      end

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
      Rails.logger.warn("[DiscordImport] Could not upload #{filename}: #{e.message}")
      nil
    ensure
      tempfile&.close
      begin; tempfile&.unlink; rescue nil; end
    end

    def self.format_content(message, user: nil, log: [])
      parts   = []
      content = message["content"].to_s.strip
      parts << content unless content.empty?

      (message["attachments"] || []).each do |att|
        filename = att["fileName"].presence || "attachment"
        upload   = upload_attachment(att, user, log: log) if user

        if upload
          parts << UploadMarkdown.new(upload).to_markdown
        else
          is_image = att["contentType"]&.start_with?("image/") ||
                     att["fileName"].to_s.match?(/\.(png|jpe?g|gif|webp|svg|bmp|tiff?)\z/i)
          parts << (is_image ? "![#{filename}](#{att["url"]})" : "[#{filename}](#{att["url"]})")
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

    # Create a Discourse topic from a single Discord message, with dedup.
    # Returns [topic, created, skipped, updated].
    def self.create_topic_from_message(msg, title, category_id, user_mappings, duplicate_mode: "ignore", log: [])
      user = resolve_user(msg.dig("author", "id"), user_mappings)
      unless user
        log << "  WARN: No resolvable user for message #{msg["id"]}"
        return [nil, 0, 1, 0]
      end

      content = format_content(msg, user: user, log: log)
      if content.blank?
        log << "  WARN: Message content is blank"
        return [nil, 0, 1, 0]
      end

      discord_msg_id = msg["id"]
      existing_field = discord_msg_id ? PostCustomField.find_by(name: "discord_message_id", value: discord_msg_id) : nil

      if existing_field
        candidate = existing_field.post&.topic
        if candidate && !candidate.trashed?
          if duplicate_mode == "update"
            existing_field.post.update_columns(raw: content, cooked: PrettyText.cook(content))
            Rails.logger.info("[DiscordImport] Updated post #{existing_field.post_id} (msg #{discord_msg_id})")
            return [candidate, 0, 0, 1]
          else
            log << "  Duplicate: topic already imported"
            return [candidate, 0, 1, 0]
          end
        else
          log << "  Stale record (topic deleted) — reimporting"
          existing_field.destroy
        end
      end

      post = safe_create_post(
        user,
        title:      sanitize_title(title),
        raw:        content,
        category:   category_id,
        created_at: DateTime.parse(msg["timestamp"]),
        log:        log,
      )
      return [nil, 0, 1, 0] unless post

      PostCustomField.create!(post_id: post.id, name: "discord_message_id", value: discord_msg_id) if discord_msg_id
      [post.topic, 1, 0, 0]
    end

    # Create a topic from an export file, using the first importable message as OP.
    # Used for file-based threads (no origin message) and merge-mode threads.
    def self.create_topic_from_export(export, title, category_id, user_mappings, duplicate_mode: "ignore", log: [])
      messages         = export["messages"] || []
      total_importable = messages.count(&method(:importable_message?))

      first_msg = nil
      messages.each do |m|
        next unless importable_message?(m)
        next unless resolve_user(m.dig("author", "id"), user_mappings)
        first_msg = m
        break
      end

      unless first_msg
        log << "  WARN: No importable message with resolvable user — skipping"
        return [nil, 0, total_importable, 0]
      end

      topic, created, skipped, updated = create_topic_from_message(
        first_msg, title, category_id, user_mappings,
        duplicate_mode: duplicate_mode, log: log,
      )
      return [nil, 0, total_importable, 0] unless topic

      remaining = messages.reject { |m| m["id"] == first_msg["id"] }
      c, s, u   = import_messages(remaining, topic.id, user_mappings,
                                  duplicate_mode: duplicate_mode, log: log)
      [topic, created + c, skipped + s, updated + u]
    end

    # Import an array of messages as replies to an existing topic.
    def self.import_messages(messages, topic_id, user_mappings, duplicate_mode: "ignore", log: [])
      created = 0
      skipped = 0
      updated = 0

      messages.each do |message|
        begin
          unless importable_message?(message)
            skipped += 1
            next
          end

          discord_msg_id = message["id"]
          existing_field = discord_msg_id ? PostCustomField.find_by(name: "discord_message_id", value: discord_msg_id) : nil

          if existing_field
            # Only a genuine duplicate if it's already on THIS topic.
            # If on a different/deleted topic, the field is stale — discard and reimport.
            if existing_field.post&.topic_id == topic_id
              if duplicate_mode == "update"
                user    = resolve_user(message.dig("author", "id"), user_mappings)
                content = user ? format_content(message, user: user, log: log) : nil
                if content.present?
                  existing_field.post.update_columns(raw: content, cooked: PrettyText.cook(content))
                  Rails.logger.info("[DiscordImport] Updated post #{existing_field.post_id} (msg #{discord_msg_id})")
                  updated += 1
                else
                  skipped += 1
                end
              else
                skipped += 1
              end
              next
            else
              existing_field.destroy
            end
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
        rescue => e
          log << "  ERROR: message #{message["id"]}: #{e.class}: #{e.message}"
          Rails.logger.error("[DiscordImport] Exception on message #{message["id"]}: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}")
          skipped += 1
        end
      end

      [created, skipped, updated]
    end

    # Import a Discord thread as a new Discourse topic.
    # If origin_msg is given, it becomes the topic OP.
    # Otherwise the first importable message from the thread file is used.
    def self.import_thread(thread_export:, origin_msg:, category_id:, user_mappings:, duplicate_mode:, log: [])
      thread_name = thread_export.dig("channel", "name")
      thread_msgs = thread_export["messages"] || []

      if origin_msg
        topic, created, skipped, updated = create_topic_from_message(
          origin_msg, thread_name, category_id, user_mappings,
          duplicate_mode: duplicate_mode, log: log,
        )
        return [nil, 0, 0, 0] unless topic

        # Import thread messages, skipping the origin message if it appears in the file
        remaining = thread_msgs.reject { |m| m["id"] == origin_msg["id"] }
        c, s, u   = import_messages(remaining, topic.id, user_mappings,
                                    duplicate_mode: duplicate_mode, log: log)
        [topic, created + c, skipped + s, updated + u]
      else
        # No origin message (self-referential marker or file-based fallback)
        create_topic_from_export(thread_export, thread_name, category_id, user_mappings,
                                 duplicate_mode: duplicate_mode, log: log)
      end
    end

    def self.safe_create_post(user, log: [], **opts)
      post = PostCreator.create!(user, **opts, skip_validations: true, skip_guardian: true)
      Rails.logger.info("[DiscordImport] Created post #{post.id} in topic #{post.topic_id}")
      post
    rescue => e
      log << "  ERROR: Failed to create post: #{e.message}"
      Rails.logger.error("[DiscordImport] Failed to create post: #{e.class}: #{e.message}")
      nil
    end

    def self.sanitize_title(title)
      title.to_s.strip.slice(0, SiteSetting.max_topic_title_length).presence || "Imported"
    end

    # DiscordChatExporter filenames: "Guild - ChannelName - ThreadName [id].json"
    # The second segment (index 1) is the parent channel name.
    def self.extract_parent_channel_name(filename)
      return nil if filename.nil?
      base  = File.basename(filename.to_s, ".json")
      parts = base.split(" - ")
      return nil unless parts.length >= 3
      parts[1]
    end
  end
end

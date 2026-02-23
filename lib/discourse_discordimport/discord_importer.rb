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
        channel_id    = config["channel_id"]
        action        = config["action"]
        split_threads = config["split_threads"] == true || config["split_threads"] == "true"

        main_export = exports_by_channel_id[channel_id]
        next unless main_export

        channel_name = main_export.dig("channel", "name")

        # Collect thread exports that belong to this channel.
        # Anything that isn't a top-level channel type is a candidate thread.
        # Primary match: categoryId == channel id.
        # Fallback: filename second segment matches channel name.
        thread_exports = exports.select do |e|
          next false if CHANNEL_TYPES.include?(e.dig("channel", "type"))
          e.dig("channel", "categoryId") == channel_id ||
            extract_parent_channel_name(e["_file_name"]) == channel_name
        end

        # Resolve the primary topic
        topic, posts_created, posts_skipped, posts_updated =
          if action == "existing"
            topic = Topic.find_by(id: config["topic_id"])
            raise "Topic #{config["topic_id"]} not found" unless topic
            created, skipped, updated = import_messages(
              main_export["messages"] || [],
              topic.id,
              user_mappings,
              duplicate_mode: duplicate_mode,
            )
            [topic, created, skipped, updated]
          else
            create_topic_from_export(
              main_export,
              config["new_topic_title"] || main_export.dig("channel", "name"),
              config["new_topic_category_id"],
              user_mappings,
              duplicate_mode: duplicate_mode,
            )
          end

        next unless topic

        thread_results = []

        if split_threads
          thread_exports.each do |te|
            thread_name = te.dig("channel", "name")
            category_id = topic.category_id

            thread_topic, t_created, t_skipped, t_updated = create_topic_from_export(
              te,
              thread_name,
              category_id,
              user_mappings,
              duplicate_mode: duplicate_mode,
            )
            next unless thread_topic

            thread_results << {
              thread_name:   thread_name,
              topic_id:      thread_topic.id,
              topic_url:     thread_topic.url,
              posts_created: t_created,
              posts_skipped: t_skipped,
              posts_updated: t_updated,
            }
          end
        else
          # Merge threads into primary topic in timestamp order
          sorted_threads = thread_exports.sort_by do |te|
            te.dig("messages", 0, "timestamp") || ""
          end

          sorted_threads.each do |te|
            thread_name = te.dig("channel", "name")
            messages    = te["messages"] || []

            # Create separator post — use first resolvable user in the thread
            separator_user = first_resolvable_user(messages, user_mappings)
            if separator_user
              safe_create_post(
                separator_user,
                topic_id: topic.id,
                raw: "*--- Thread: \"#{thread_name}\" ---*",
                created_at: DateTime.parse(messages.first["timestamp"]),
              )
            end

            t_created, t_skipped, t_updated = import_messages(messages, topic.id, user_mappings, duplicate_mode: duplicate_mode)
            posts_created += t_created
            posts_skipped += t_skipped
            posts_updated += t_updated
          end
        end

        results << {
          channel_name:   channel_name,
          topic_id:       topic.id,
          topic_url:      topic.url,
          posts_created:  posts_created,
          posts_skipped:  posts_skipped,
          posts_updated:  posts_updated,
          thread_results: thread_results,
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

    def self.importable_message?(message)
      return false if message.dig("author", "isBot")
      message["type"] == "Default"
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
    def self.upload_attachment(att, user)
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
      upload.persisted? ? upload : nil
    rescue => e
      Rails.logger.warn("[DiscordImport] Could not upload attachment #{filename}: #{e.message}")
      nil
    ensure
      tempfile&.close
      begin; tempfile&.unlink; rescue nil; end
    end

    def self.format_content(message, user: nil)
      parts = []
      content = message["content"].to_s.strip
      parts << content unless content.empty?

      (message["attachments"] || []).each do |att|
        filename = att["fileName"].presence || "attachment"
        upload   = upload_attachment(att, user) if user

        if upload
          if att["contentType"]&.start_with?("image/")
            parts << "![#{filename}](#{upload.short_url})"
          else
            parts << "[#{filename}|attachment](#{upload.short_url})"
          end
        else
          # Fallback to original Discord CDN URL (may expire, but better than nothing)
          if att["contentType"]&.start_with?("image/")
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

    def self.create_topic_from_export(export, title, category_id, user_mappings, duplicate_mode: "ignore")
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

      return [nil, 0, total_importable, 0] unless first_message

      content = format_content(first_message, user: first_user)
      return [nil, 0, total_importable, 0] if content.blank?

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
        end
      end

      unless topic
        post = safe_create_post(
          first_user,
          title:      title,
          raw:        content,
          category:   category_id,
          created_at: DateTime.parse(first_message["timestamp"]),
        )
        return [nil, 0, total_importable, 0] unless post

        PostCustomField.create!(post_id: post.id, name: "discord_message_id", value: discord_msg_id) if discord_msg_id
        topic         = post.topic
        first_created = 1
      end

      remaining = messages.reject { |m| m["id"] == first_message["id"] }
      created, skipped, updated = import_messages(remaining, topic.id, user_mappings, duplicate_mode: duplicate_mode)

      [topic, first_created + created, first_skipped + skipped, first_updated + updated]
    end

    def self.import_messages(messages, topic_id, user_mappings, duplicate_mode: "ignore")
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
            content = format_content(message, user: user)
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

        content = format_content(message, user: user)
        if content.blank?
          skipped += 1
          next
        end

        post = safe_create_post(
          user,
          topic_id:   topic_id,
          raw:        content,
          created_at: DateTime.parse(message["timestamp"]),
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

    def self.safe_create_post(user, **opts)
      PostCreator.create!(
        user,
        **opts,
        skip_validations: true,
        skip_guardian:    true,
      )
    rescue => e
      Rails.logger.error("[DiscordImport] Failed to create post: #{e.message}")
      nil
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

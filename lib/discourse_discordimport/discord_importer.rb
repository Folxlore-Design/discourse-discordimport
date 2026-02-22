# frozen_string_literal: true

module DiscourseDiscordimport
  class DiscordImporter
    CHANNEL_TYPES = %w[GuildTextChat].freeze
    THREAD_TYPES  = %w[GuildPublicThread GuildPrivateThread].freeze

    # ---------------------------------------------------------------------------
    # analyze(exports) → hash describing what's in the archive
    #
    # exports: array of parsed JSON hashes, one per file in the archive
    # ---------------------------------------------------------------------------
    def self.analyze(exports)
      channels_by_id = {}
      threads = []

      exports.each do |export|
        ch = export["channel"]
        next unless ch

        type = ch["type"]
        messages = export["messages"] || []
        importable, skipped = count_messages(messages)

        entry = {
          channel_id:   ch["id"],
          channel_name: ch["name"],
          guild_name:   export.dig("guild", "name"),
          message_count: importable,
          skipped_count: skipped,
        }

        if CHANNEL_TYPES.include?(type)
          channels_by_id[ch["id"]] = entry.merge(threads: [])
        elsif THREAD_TYPES.include?(type)
          threads << entry.merge(parent_channel_id: ch["categoryId"])
        end
      end

      # Nest threads under their parent channels; orphans become top-level channels
      threads.each do |thread|
        parent = channels_by_id[thread[:parent_channel_id]]
        if parent
          parent[:threads] << thread.except(:parent_channel_id)
        else
          # Orphaned thread — treat as standalone channel with no threads
          channels_by_id[thread[:channel_id]] = thread.except(:parent_channel_id).merge(threads: [])
        end
      end

      users = collect_users(exports)

      {
        channels: channels_by_id.values,
        users:    users,
      }
    end

    # ---------------------------------------------------------------------------
    # import(exports, channel_configs, user_mappings) → results hash
    #
    # channel_configs: array of hashes (action, channel_id, topic_id, etc.)
    # user_mappings:   { discord_user_id => discourse_user_id | "omit" | "anonymous" }
    # ---------------------------------------------------------------------------
    def self.import(exports, channel_configs, user_mappings)
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

        # Collect thread exports that belong to this channel
        thread_exports = exports.select do |e|
          THREAD_TYPES.include?(e.dig("channel", "type")) &&
            e.dig("channel", "categoryId") == channel_id
        end

        # Resolve the primary topic
        topic, posts_created, posts_skipped =
          if action == "existing"
            topic = Topic.find_by(id: config["topic_id"])
            raise "Topic #{config["topic_id"]} not found" unless topic
            created, skipped = import_messages(
              main_export["messages"] || [],
              topic.id,
              user_mappings,
            )
            [topic, created, skipped]
          else
            created_topic, created, skipped = create_topic_from_export(
              main_export,
              config["new_topic_title"] || main_export.dig("channel", "name"),
              config["new_topic_category_id"],
              user_mappings,
            )
            [created_topic, created, skipped]
          end

        next unless topic

        thread_results = []

        if split_threads
          thread_exports.each do |te|
            thread_name = te.dig("channel", "name")
            category_id = topic.category_id

            thread_topic, t_created, t_skipped = create_topic_from_export(
              te,
              thread_name,
              category_id,
              user_mappings,
            )
            next unless thread_topic

            thread_results << {
              thread_name:   thread_name,
              topic_id:      thread_topic.id,
              topic_url:     thread_topic.url,
              posts_created: t_created,
              posts_skipped: t_skipped,
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

            t_created, t_skipped = import_messages(messages, topic.id, user_mappings)
            posts_created += t_created
            posts_skipped += t_skipped
          end
        end

        results << {
          channel_name:  channel_name,
          topic_id:      topic.id,
          topic_url:     topic.url,
          posts_created: posts_created,
          posts_skipped: posts_skipped,
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

    def self.format_content(message)
      parts = []
      content = message["content"].to_s.strip
      parts << content unless content.empty?

      (message["attachments"] || []).each do |att|
        if att["contentType"]&.start_with?("image/")
          parts << "![#{att["fileName"]}](#{att["url"]})"
        else
          parts << "[#{att["fileName"]}](#{att["url"]})"
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

    def self.create_topic_from_export(export, title, category_id, user_mappings)
      messages = export["messages"] || []

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

      return [nil, 0, messages.count(&method(:importable_message?))] unless first_message

      content = format_content(first_message)
      return [nil, 0, messages.count(&method(:importable_message?))] if content.blank?

      post = safe_create_post(
        first_user,
        title:       title,
        raw:         content,
        category:    category_id,
        created_at:  DateTime.parse(first_message["timestamp"]),
      )
      return [nil, 0, messages.count(&method(:importable_message?))] unless post

      topic = post.topic
      remaining = messages.reject { |m| m["id"] == first_message["id"] }
      created, skipped = import_messages(remaining, topic.id, user_mappings)

      [topic, created + 1, skipped]
    end

    def self.import_messages(messages, topic_id, user_mappings)
      created = 0
      skipped = 0

      messages.each do |message|
        unless importable_message?(message)
          skipped += 1
          next
        end

        user = resolve_user(message.dig("author", "id"), user_mappings)
        unless user
          skipped += 1
          next
        end

        content = format_content(message)
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
          created += 1
        else
          skipped += 1
        end
      end

      [created, skipped]
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
  end
end

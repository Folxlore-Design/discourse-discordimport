# frozen_string_literal: true

# name: discourse-discordimport
# about: Import Discord chat exports (DiscordChatExporter JSON archives) into Discourse topics
# version: 0.1.0
# authors: coven.folxlore.net
# url: https://github.com/branwyn/discourse-discordimport
# component: false

register_asset "stylesheets/discord-import.scss"

enabled_site_setting :discordimport_enabled

after_initialize do
  register_post_custom_field_type("discord_message_id", :string)

  module ::DiscourseDiscordimport
    PLUGIN_NAME = "discourse-discordimport"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseDiscordimport
    end
  end

  require_relative "lib/discourse_discordimport/discord_importer"
  require_relative "app/controllers/discourse_discordimport/import_controller"

  Discourse::Application.routes.append do
    mount ::DiscourseDiscordimport::Engine, at: "/discordimport"
  end

  DiscourseDiscordimport::Engine.routes.draw do
    post "/analyze" => "import#analyze"
    post "/import"  => "import#create"
  end

  add_admin_route "discordimport.admin_title", "discord-import"
end

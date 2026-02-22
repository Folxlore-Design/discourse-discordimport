# frozen_string_literal: true

class DiscourseDiscordimport::ImportController < ::ApplicationController
  requires_plugin DiscourseDiscordimport::PLUGIN_NAME
  before_action :ensure_logged_in
  before_action :ensure_staff

  def analyze
    file = params.require(:file)
    exports = parse_exports(file)
    render json: DiscourseDiscordimport::DiscordImporter.analyze(exports)
  rescue => e
    render json: { error: e.message }, status: 422
  end

  def create
    file    = params.require(:file)
    exports = parse_exports(file)

    channel_configs = JSON.parse(params.require(:channel_configs))
    user_mappings   = JSON.parse(params.require(:user_mappings))
    duplicate_mode  = params[:duplicate_mode].presence || "ignore"

    result = DiscourseDiscordimport::DiscordImporter.import(
      exports,
      channel_configs,
      user_mappings,
      duplicate_mode: duplicate_mode,
    )

    render json: result
  rescue => e
    Rails.logger.error("[DiscordImport] Import failed: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}")
    render json: { error: e.message }, status: 422
  end

  private

  def parse_exports(file)
    name = file.original_filename.to_s.downcase
    if name.end_with?(".zip")
      parse_zip(file)
    elsif name.end_with?(".tar.gz") || name.end_with?(".tgz")
      parse_tar_gz(file)
    else
      raise "Unsupported archive format. Please upload a .zip or .tar.gz file."
    end
  end

  def parse_zip(file)
    require "zip"
    exports = []
    Zip::File.open(file.path) do |zip|
      zip.each do |entry|
        next unless entry.file? && entry.name.end_with?(".json")
        data = JSON.parse(entry.get_input_stream.read)
        next unless data["channel"] && data["messages"]
        data["_file_name"] = File.basename(entry.name)
        exports << data
      end
    end
    raise "No valid DiscordChatExporter JSON files found in archive." if exports.empty?
    exports
  end

  def parse_tar_gz(file)
    require "zlib"
    require "rubygems/package"
    exports = []
    Zlib::GzipReader.open(file.path) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          next unless entry.file? && entry.full_name.end_with?(".json")
          data = JSON.parse(entry.read)
          next unless data["channel"] && data["messages"]
          data["_file_name"] = File.basename(entry.full_name)
          exports << data
        end
      end
    end
    raise "No valid DiscordChatExporter JSON files found in archive." if exports.empty?
    exports
  end
end

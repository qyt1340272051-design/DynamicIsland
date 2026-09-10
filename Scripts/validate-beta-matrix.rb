#!/usr/bin/env ruby

require "date"
require "json"

root_dir = File.expand_path("..", __dir__)
matrix_path = File.join(root_dir, "docs", "beta-device-matrix.json")
errors = []

begin
  matrix = JSON.parse(File.read(matrix_path))
rescue Errno::ENOENT
  abort "Beta matrix is missing: #{matrix_path}"
rescue JSON::ParserError => error
  abort "Beta matrix is not valid JSON: #{error.message}"
end

errors << "schemaVersion must be 1" unless matrix["schemaVersion"] == 1
errors << "targetVersion must be v0.4.0-beta.1" unless matrix["targetVersion"] == "v0.4.0-beta.1"

begin
  Date.iso8601(matrix.fetch("lastUpdated"))
rescue KeyError, Date::Error, TypeError
  errors << "lastUpdated must be an ISO 8601 calendar date"
end

scenarios = matrix["scenarios"]
unless scenarios.is_a?(Array)
  abort "Beta matrix validation failed:\n- scenarios must be an array"
end

required_ids = (1..9).map { |number| format("DI-B%02d", number) }
actual_ids = scenarios.map { |scenario| scenario["id"] if scenario.is_a?(Hash) }.compact
errors << "scenario IDs must be exactly #{required_ids.join(", ")}" unless actual_ids.sort == required_ids
errors << "scenario IDs must be unique" unless actual_ids.uniq.length == actual_ids.length

allowed_architectures = %w[arm64 x86_64]
allowed_topologies = %w[single-built-in dual external-only single-external]
allowed_scaling = %w[default non-default mixed]
allowed_menu_bar_modes = %w[visible auto-hide]
allowed_statuses = %w[pending local-pass passed failed blocked]
required_fields = %w[id title hardwareClass architectures notch topology scaling menuBarModes focus status evidence]

scenarios.each_with_index do |scenario, index|
  unless scenario.is_a?(Hash)
    errors << "scenario #{index + 1} must be an object"
    next
  end

  label = scenario["id"] || "scenario #{index + 1}"
  missing_fields = required_fields.reject { |field| scenario.key?(field) }
  errors << "#{label} is missing: #{missing_fields.join(", ")}" unless missing_fields.empty?

  errors << "#{label} title must not be empty" unless scenario["title"].is_a?(String) && !scenario["title"].empty?
  errors << "#{label} hardwareClass must not be empty" unless scenario["hardwareClass"].is_a?(String) && !scenario["hardwareClass"].empty?
  errors << "#{label} notch must be boolean" unless [true, false].include?(scenario["notch"])
  errors << "#{label} topology is invalid" unless allowed_topologies.include?(scenario["topology"])
  errors << "#{label} scaling is invalid" unless allowed_scaling.include?(scenario["scaling"])
  errors << "#{label} status is invalid" unless allowed_statuses.include?(scenario["status"])

  architectures = scenario["architectures"]
  unless architectures.is_a?(Array) && !architectures.empty? && (architectures - allowed_architectures).empty?
    errors << "#{label} architectures must contain only supported values"
  end

  menu_bar_modes = scenario["menuBarModes"]
  unless menu_bar_modes.is_a?(Array) && !menu_bar_modes.empty? && (menu_bar_modes - allowed_menu_bar_modes).empty?
    errors << "#{label} menuBarModes must contain only supported values"
  end

  focus = scenario["focus"]
  errors << "#{label} focus must contain at least one check" unless focus.is_a?(Array) && !focus.empty?

  evidence = scenario["evidence"]
  errors << "#{label} evidence must be an array" unless evidence.is_a?(Array)
  if evidence.is_a?(Array) && evidence.any? { |entry| !entry.is_a?(String) || entry.empty? }
    errors << "#{label} evidence entries must be non-empty strings"
  end
  if scenario["status"] != "pending" && (!evidence.is_a?(Array) || evidence.empty?)
    errors << "#{label} requires evidence when status is #{scenario["status"]}"
  end
end

notch_values = scenarios.map { |scenario| scenario["notch"] if scenario.is_a?(Hash) }.compact.uniq
errors << "matrix must cover both notch and no-notch Macs" unless notch_values.sort_by(&:to_s) == [false, true]

topologies = scenarios.map { |scenario| scenario["topology"] if scenario.is_a?(Hash) }.compact.uniq
missing_topologies = allowed_topologies - topologies
errors << "matrix is missing topology coverage: #{missing_topologies.join(", ")}" unless missing_topologies.empty?

scaling_modes = scenarios.map { |scenario| scenario["scaling"] if scenario.is_a?(Hash) }.compact.uniq
missing_scaling_modes = allowed_scaling - scaling_modes
errors << "matrix is missing scaling coverage: #{missing_scaling_modes.join(", ")}" unless missing_scaling_modes.empty?

menu_bar_modes = scenarios.flat_map do |scenario|
  scenario.is_a?(Hash) && scenario["menuBarModes"].is_a?(Array) ? scenario["menuBarModes"] : []
end.uniq
missing_menu_bar_modes = allowed_menu_bar_modes - menu_bar_modes
errors << "matrix is missing menu bar coverage: #{missing_menu_bar_modes.join(", ")}" unless missing_menu_bar_modes.empty?

architectures = scenarios.flat_map do |scenario|
  scenario.is_a?(Hash) && scenario["architectures"].is_a?(Array) ? scenario["architectures"] : []
end.uniq
missing_architectures = allowed_architectures - architectures
errors << "matrix is missing architecture coverage: #{missing_architectures.join(", ")}" unless missing_architectures.empty?

unless errors.empty?
  abort "Beta matrix validation failed:\n- #{errors.join("\n- ")}"
end

status_counts = scenarios.group_by { |scenario| scenario["status"] }.transform_values(&:length)
verified_count = status_counts.fetch("local-pass", 0) + status_counts.fetch("passed", 0)
pending_count = status_counts.fetch("pending", 0)
puts "Beta matrix valid: #{scenarios.length} scenarios, #{verified_count} verified, #{pending_count} pending."

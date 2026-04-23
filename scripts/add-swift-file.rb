# scripts/add-swift-file.rb — Register a Swift file in GhosttyTabs.xcodeproj.
# Invoke via scripts/add-swift-file.sh (which sets GEM_HOME to the cocoapods
# libexec so `require 'xcodeproj'` resolves under the system Ruby).
#
# Usage (through the wrapper):
#   scripts/add-swift-file.sh Sources/Async/Foo.swift
#   scripts/add-swift-file.sh cmuxTests/BarTests.swift
#   scripts/add-swift-file.sh cmuxUITests/BazUITests.swift
#   scripts/add-swift-file.sh path/to/File.swift --target GhosttyTabs
#
# Auto-detects the Xcode target from the path prefix:
#   Sources/       -> GhosttyTabs
#   cmuxTests/     -> cmuxTests
#   cmuxUITests/   -> cmuxUITests
#   CLI/           -> cmux-cli
#
# Behaviour:
#   - Creates the file on disk with a minimal stub if missing.
#   - Creates intermediate PBXGroups in the project as needed.
#   - Adds a PBXFileReference and wires it into the target's Sources build phase.
#   - Skips gracefully if the file is already registered.
#
# Requires the `xcodeproj` Ruby gem (Homebrew ships it: /opt/homebrew/bin/xcodeproj).

require 'xcodeproj'
require 'fileutils'
require 'pathname'

PROJECT_PATH = File.expand_path('../GhosttyTabs.xcodeproj', __dir__)
REPO_ROOT = File.expand_path('..', __dir__)

TARGET_MAPPING = {
  'Sources/'     => 'GhosttyTabs',
  'cmuxTests/'   => 'cmuxTests',
  'cmuxUITests/' => 'cmuxUITests',
  'CLI/'         => 'cmux-cli',
}.freeze

STUB_TEMPLATE = <<~SWIFT
  import Foundation

  // Auto-created by scripts/add-swift-file.rb. Replace this stub with real content.
SWIFT

def die(msg)
  warn "error: #{msg}"
  exit 1
end

file_path = ARGV[0] or die('missing file path (arg 1)')
file_path = file_path.sub(%r{\A\./}, '')

# Optional --target override
explicit_target = nil
if (idx = ARGV.index('--target'))
  explicit_target = ARGV[idx + 1] or die('--target requires a value')
end

target_name = explicit_target || begin
  match = TARGET_MAPPING.find { |prefix, _| file_path.start_with?(prefix) }
  die("cannot auto-detect target for #{file_path}; pass --target <Name>") unless match
  match[1]
end

# Ensure the file exists on disk; create a stub if missing.
abs_path = File.join(REPO_ROOT, file_path)
unless File.exist?(abs_path)
  FileUtils.mkdir_p(File.dirname(abs_path))
  File.write(abs_path, STUB_TEMPLATE)
  puts "created stub: #{file_path}"
end

project = Xcodeproj::Project.open(PROJECT_PATH)

# Walk / build the group hierarchy.
parts = file_path.split('/')
filename = parts.pop
group = project.main_group
parts.each do |part|
  sub = group.children.find do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == part
  end
  group = sub || group.new_group(part, part)
end

# Skip if already referenced in this group.
existing = group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.display_name == filename
end
if existing
  puts "already registered: #{file_path}"
  exit 0
end

file_ref = group.new_file(filename)

target = project.targets.find { |t| t.name == target_name }
die("target not found: #{target_name}") unless target

target.add_file_references([file_ref])

project.save
puts "registered #{file_path} in target #{target_name}"

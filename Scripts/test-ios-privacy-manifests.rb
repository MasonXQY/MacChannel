#!/usr/bin/env ruby
# Source packaging contract; optionally verify an archived/exported .app as argv[0].
require 'json'
require 'yaml'
require 'open3'

ROOT = File.expand_path('..', __dir__)
EXPECTED = {
  'DropMesh' => {
    'FileTimestamp' => %w[3B52.1 C617.1],
    'DiskSpace' => %w[E174.1],
    'UserDefaults' => %w[CA92.1]
  },
  'DropMeshShare' => { 'FileTimestamp' => %w[3B52.1 C617.1] }
}.freeze

def check_manifest(path, expected)
  abort "FAIL: missing manifest #{path}" unless File.file?(path)
  json, status = Open3.capture2('/usr/bin/plutil', '-convert', 'json', '-o', '-', path)
  abort "FAIL: invalid plist #{path}" unless status.success?
  plist = JSON.parse(json)
  abort 'FAIL: unreviewed collection/tracking declaration' unless plist.keys == ['NSPrivacyAccessedAPITypes']
  rows = plist.fetch('NSPrivacyAccessedAPITypes')
  actual = rows.to_h do |row|
    [row.fetch('NSPrivacyAccessedAPIType').delete_prefix('NSPrivacyAccessedAPICategory'),
     row.fetch('NSPrivacyAccessedAPITypeReasons').sort]
  end
  abort "FAIL: reason contract #{path}" unless actual == expected && rows.length == expected.length
end

project = YAML.load_file(File.join(ROOT, 'iPhone/project.yml'))
EXPECTED.each do |target, reasons|
  folder = target == 'DropMesh' ? 'App' : 'ShareExtension'
  path = "#{folder}/PrivacyInfo.xcprivacy"
  check_manifest(File.join(ROOT, 'iPhone', path), reasons)
  entries = project.fetch('targets').fetch(target).fetch('sources')
  abort "FAIL: explicit resource missing #{target}" unless entries.any? { |s| s['path'] == path && s['buildPhase'] == 'resources' }
  directory = entries.find { |s| s['path'] == folder }
  abort "FAIL: duplicate resource risk #{target}" unless directory.fetch('excludes', []).include?('PrivacyInfo.xcprivacy')
end
host = project.fetch('targets').fetch('DropMeshTestHost').fetch('sources')
abort 'FAIL: test host duplicate manifest' unless host.find { |s| s['path'] == 'ShareExtension' }.fetch('excludes').include?('PrivacyInfo.xcprivacy')

if ARGV[0]
  app = File.expand_path(ARGV[0])
  check_manifest(File.join(app, 'PrivacyInfo.xcprivacy'), EXPECTED.fetch('DropMesh'))
  check_manifest(File.join(app, 'PlugIns/DropMeshShare.appex/PrivacyInfo.xcprivacy'), EXPECTED.fetch('DropMeshShare'))
  puts 'PASS: main and share embedded privacy manifests'
end
puts 'PASS: iOS privacy reasons and source packaging contract'

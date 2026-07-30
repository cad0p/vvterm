#!/usr/bin/env ruby
# frozen_string_literal: true

# assign-icloud-container.rb — assign the VVTerm CloudKit container to the
# OTA App ID, programmatically.
#
# Why this exists: the App Store Connect REST API (JWT — what the CI and the
# `asc` CLI use) CANNOT assign iCloud containers to App IDs. Its
# BundleIdCapability settings for the ICLOUD capability accept only
# ICLOUD_VERSION / data-protection options — the API server itself rejected a
# container attempt with the allowed-enum error on 2026-07-29. The developer
# portal website itself CAN do it, via the private web API that backs
# developer.apple.com (assignCloudContainerToAppId.action), and fastlane's
# spaceship wraps that API (Spaceship::Portal::App#associate_cloud_containers,
# maintained in fastlane master as of June 2026). Xcode's "Automatically
# manage signing" uses the same underlying services.
#
# This is a one-time setup step per OTA App ID (idempotent — safe to re-run).
# After a successful run, recreate the OTA provisioning profiles (profiles
# snapshot the App ID's entitlements at creation time):
#   scripts/create-adhoc-profiles.sh ... --set-secrets
#
# Usage:
#   gem install spaceship   # once (or use any existing fastlane install)
#   ruby scripts/assign-icloud-container.rb
#
# Auth: an Apple ID in the developer team, Account Holder or Admin role
# (container management is restricted to those roles). Interactive 2FA is
# supported; or set FASTLANE_USER / FASTLANE_PASSWORD to skip the prompts.
# Overrides: APP_ID / CONTAINER_ID env vars for non-VVTerm reuse.

require 'spaceship'

APP_ID = ENV.fetch('APP_ID', 'it.pcad.vvterm.ota')
CONTAINER_ID = ENV.fetch('CONTAINER_ID', 'iCloud.it.pcad.vvterm')

Spaceship::Portal.login
Spaceship::Portal.select_team

app = Spaceship::Portal::App.find(APP_ID)
abort "ERROR: App ID #{APP_ID} not found in the developer portal" if app.nil?

container = Spaceship::Portal::CloudContainer.find(CONTAINER_ID)
abort "ERROR: iCloud container #{CONTAINER_ID} not found for this team" if container.nil?

current = app.details.associated_cloud_containers.map(&:identifier)
if current.include?(container.identifier)
  puts "OK: #{container.identifier} already assigned to #{APP_ID} — nothing to do."
  exit 0
end

# The portal API replaces the full assignment set — merge, don't clobber.
updated = app.associate_cloud_containers(app.details.associated_cloud_containers + [container])
now = updated.associated_cloud_containers.map(&:identifier)

if now.include?(container.identifier)
  puts "OK: assigned #{container.identifier} to #{APP_ID} (containers now: #{now.join(', ')})"
else
  abort "ERROR: assignment did not stick — portal returned: [#{now.join(', ')}]"
end

puts 'Next: re-run scripts/create-adhoc-profiles.sh with --set-secrets so the new'
puts 'entitlement lands in freshly created profiles.'

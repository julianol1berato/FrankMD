# frozen_string_literal: true

# Start the daily notes backup scheduler only inside the web server, so
# console sessions, rake tasks and tests never spawn the background thread.
Rails.application.config.after_initialize do
  NotesBackupScheduler.start if defined?(Rails::Server)
end

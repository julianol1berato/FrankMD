# frozen_string_literal: true

# Background thread that triggers the daily notes backup inside the web server.
# FrankMD has no database and therefore no job queue, so the thread wakes once
# a minute and lets NotesBackupService#due? decide whether a run is needed;
# that check also catches up on a backup missed while the server was down.
class NotesBackupScheduler
  CHECK_INTERVAL = 60

  class << self
    def start(interval: CHECK_INTERVAL)
      return @thread if @thread&.alive?

      @thread = Thread.new do
        loop do
          sleep interval
          tick
        end
      end
      @thread.name = "frankmd-notes-backup"
      @thread
    end

    def tick(now: Time.now)
      Rails.application.executor.wrap do
        service = NotesBackupService.new
        service.run!(now: now) if service.due?(now)
      end
    rescue NotesBackupService::AlreadyRunningError
      # A manual "Back up now" or another instance is already uploading.
      nil
    rescue StandardError => e
      Rails.logger.error("[Backup] #{NotesBackupService.error_message(e)}")
      nil
    end
  end
end

# frozen_string_literal: true

require "json"
require "rubygems/package"
require "securerandom"
require "tempfile"
require "zlib"

# Daily snapshot of the notes directory to S3-compatible storage (AWS S3,
# Backblaze B2, Wasabi, MinIO).
#
# Each run uploads one .tar.gz to <prefix>/daily/YYYY-MM-DD.tar.gz, and the
# first successful run of each month also writes <prefix>/monthly/YYYY-MM.tar.gz.
# Old daily snapshots are expired by a bucket lifecycle rule, never by FrankMD,
# so the backup credentials only need PutObject permission.
#
# Run state lives in .frankmd/ at the notes root (hidden from the explorer and
# left out of the archive) because the app has no database.
class NotesBackupService
  class Error < StandardError; end
  class NotConfiguredError < Error; end
  class AlreadyRunningError < Error; end
  class ConnectionTimeoutError < Error; end

  STATE_DIR = ".frankmd"
  STATUS_FILE = "backup-status.json"
  RUN_LOCK_FILE = "backup.lock"
  CONNECTION_TEST_KEY = ".frankmd-connection-test"
  CONNECTION_TEST_TIMEOUT = 10
  DEFAULT_TIME = "01:00"
  TIME_FORMAT = /\A([01]?\d|2[0-3]):([0-5]\d)\z/
  # A failed run is retried after this long instead of waiting a whole day.
  RETRY_INTERVAL = 3600
  MAX_ERROR_LENGTH = 500

  # Left out of the snapshot: the .fed file (it holds API keys, including the
  # backup credentials), lock and state files, git metadata, and the temporary
  # files that atomic writes leave behind for an instant.
  EXCLUDED_ROOT_ENTRIES = [ Config::CONFIG_FILE, NotesService::FILESYSTEM_LOCK_FILENAME, STATE_DIR, ".git" ].freeze
  TEMP_FILE_PATTERN = /\A\..+\.[0-9a-f]{12}\.tmp\z/

  TAR_BLOCK_SIZE = 512

  def self.valid_time?(value)
    value.to_s.strip.match?(TIME_FORMAT)
  end

  # Short, user-facing description of a failure (no backtrace, no secrets).
  def self.error_message(error)
    "#{error.class.name.demodulize}: #{error.message}".truncate(MAX_ERROR_LENGTH)
  end

  def initialize(base_path: nil, config: nil, client: nil)
    @base_path = Pathname.new(base_path || ENV.fetch("NOTES_PATH", Rails.root.join("notes")))
    @config = config || Config.new(base_path: @base_path)
    @client = client
  end

  def enabled?
    @config.get("backup_enabled") == true
  end

  def configured?
    @config.feature_available?(:notes_backup)
  end

  def status
    path = state_dir.join(STATUS_FILE)
    return {} unless path.file?

    JSON.parse(path.read)
  rescue JSON::ParserError, SystemCallError
    {}
  end

  # True once today's scheduled time has passed and no backup has succeeded
  # since then, so a run missed while the server was down happens at the next
  # check. A failed run is retried after RETRY_INTERVAL.
  def due?(now = Time.now)
    return false unless enabled? && configured?

    scheduled = scheduled_time_on(now)
    return false if now < scheduled

    current = status
    last_success = parse_time(current["last_success_at"])
    return false if last_success && last_success >= scheduled

    last_attempt = parse_time(current["last_attempt_at"])
    last_attempt.nil? || last_attempt < scheduled || now - last_attempt >= RETRY_INTERVAL
  end

  # Build and upload one snapshot. Returns the updated status hash; on failure
  # the error is recorded in the status and re-raised.
  def run!(now: Time.now)
    raise NotConfiguredError, "Backup storage is not configured" unless configured?

    with_run_lock do
      update_status("last_attempt_at" => now.iso8601)
      begin
        upload_snapshot(now)
      rescue StandardError => e
        update_status("last_error" => self.class.error_message(e))
        raise
      end
    end
  end

  # Write a small marker object to confirm the bucket and credentials work,
  # using only PutObject, the one permission a backup needs.
  #
  # The SDK's open timeout does not cover DNS lookups, which can take half a
  # minute for a wrong endpoint, so the request runs on its own thread and the
  # caller stops waiting after `timeout` seconds. The abandoned request ends
  # by itself once the lookup or connection fails.
  def test_connection!(timeout: CONNECTION_TEST_TIMEOUT)
    raise NotConfiguredError, "Backup storage is not configured" unless configured?

    s3 = client
    params = {
      bucket: @config.get("backup_s3_bucket"),
      key: object_key(CONNECTION_TEST_KEY),
      body: "FrankMD connection test #{Time.now.utc.iso8601}\n"
    }
    request = Thread.new { s3.put_object(**params) }
    request.report_on_exception = false

    # join re-raises the request's own error when it fails in time
    raise ConnectionTimeoutError, "No response from the storage endpoint within #{timeout} seconds" unless request.join(timeout)

    true
  end

  private

  def upload_snapshot(now)
    Tempfile.create([ "frankmd-backup-", ".tar.gz" ], Rails.root.join("tmp")) do |archive|
      archive.binmode
      NotesService.new(base_path: @base_path).with_shared_lock { write_archive(archive) }

      daily_key = object_key("daily/#{now.strftime('%Y-%m-%d')}.tar.gz")
      put_archive(archive, daily_key)

      month = now.strftime("%Y-%m")
      changes = { "last_success_at" => now.iso8601, "last_error" => nil, "last_key" => daily_key, "last_size" => archive.size }
      if status["last_monthly"] != month
        put_archive(archive, object_key("monthly/#{month}.tar.gz"))
        changes["last_monthly"] = month
      end

      update_status(changes)
    end
  end

  def put_archive(archive, key)
    archive.rewind
    client.put_object(bucket: @config.get("backup_s3_bucket"), key: key, body: archive, content_type: "application/gzip")
  end

  # Write a gzipped ustar archive of the notes directory. Entries keep their
  # real mtime (Gem::Package::TarWriter stamps the archive time instead) so a
  # restore preserves the file finder's recency order.
  def write_archive(io)
    gzip = Zlib::GzipWriter.new(io)
    each_entry(@base_path) do |path, name, stat|
      if stat.directory?
        write_tar_header(gzip, "#{name}/", size: 0, stat: stat, typeflag: "5")
      else
        write_tar_header(gzip, name, size: stat.size, stat: stat)
        copied = File.open(path, "rb") { |file| IO.copy_stream(file, gzip, stat.size) }
        # A file that shrank while being read (an external editor) is padded
        # so the archive stays well-formed.
        gzip.write("\0" * (stat.size - copied)) if copied < stat.size
        pad_tar_block(gzip, stat.size)
      end
    end
    gzip.write("\0" * (TAR_BLOCK_SIZE * 2))
    gzip.finish
    io.flush
  end

  # Yield every directory and regular file below dir, sorted, without
  # following symlinks out of the notes directory.
  def each_entry(dir, relative = nil, &block)
    dir.children.sort.each do |path|
      basename = path.basename.to_s
      next if relative.nil? && EXCLUDED_ROOT_ENTRIES.include?(basename)
      next if basename.match?(TEMP_FILE_PATTERN)

      stat = path.lstat
      name = relative ? "#{relative}/#{basename}" : basename
      if stat.directory?
        yield path, name, stat
        each_entry(path, name, &block)
      elsif stat.file?
        yield path, name, stat
      end
    end
  end

  def write_tar_header(io, name, size:, stat:, typeflag: "0")
    base, prefix = split_tar_name(name)
    io.write Gem::Package::TarHeader.new(
      name: base, prefix: prefix, size: size, mode: stat.mode & 0o7777,
      mtime: stat.mtime.to_i, typeflag: typeflag
    ).to_s
  end

  # ustar stores up to 100 bytes of name plus a 155-byte prefix, split at "/".
  def split_tar_name(name)
    return [ name, "" ] if name.bytesize <= 100

    trailing = name.end_with?("/") ? "/" : ""
    parts = name.chomp("/").split("/")
    (1...parts.size).each do |index|
      base = parts[index..].join("/") + trailing
      next if base.bytesize > 100

      prefix = parts[0...index].join("/")
      return [ base, prefix ] if prefix.bytesize <= 155

      break
    end
    raise Error, "Path too long for the backup archive: #{name}"
  end

  def pad_tar_block(io, size)
    remainder = size % TAR_BLOCK_SIZE
    io.write("\0" * (TAR_BLOCK_SIZE - remainder)) unless remainder.zero?
  end

  def client
    @client ||= begin
      require "aws-sdk-s3"

      options = {
        access_key_id: @config.get("backup_s3_access_key_id"),
        secret_access_key: @config.get("backup_s3_secret_access_key"),
        region: @config.get("backup_s3_region").presence || UploadStorage::DEFAULT_S3_REGION
      }

      endpoint = @config.get("backup_s3_endpoint").presence
      if endpoint
        options[:endpoint] = endpoint
        options[:force_path_style] = @config.get("backup_s3_force_path_style") ? true : false
        # Recent SDKs add CRC checksums to every request by default, which some
        # S3-compatible services reject; send them only when an API requires it.
        options[:request_checksum_calculation] = "when_required"
        options[:response_checksum_validation] = "when_required"
      end

      Aws::S3::Client.new(options)
    end
  end

  def object_key(name)
    prefix = UploadStorage.sanitize_s3_key(@config.get("backup_s3_prefix"))
    prefix.present? ? "#{prefix}/#{name}" : name
  end

  def scheduled_time_on(now)
    match = @config.get("backup_time").to_s.strip.match(TIME_FORMAT) || DEFAULT_TIME.match(TIME_FORMAT)
    local = now.getlocal
    Time.local(local.year, local.month, local.day, match[1].to_i, match[2].to_i)
  end

  def parse_time(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def with_run_lock
    FileUtils.mkdir_p(state_dir, mode: 0o700)
    File.open(state_dir.join(RUN_LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
      raise AlreadyRunningError, "A backup is already running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      yield
    end
  end

  def update_status(changes)
    current = status.merge(changes)
    FileUtils.mkdir_p(state_dir, mode: 0o700)
    temporary = state_dir.join(".#{STATUS_FILE}.#{SecureRandom.hex(6)}.tmp")
    File.write(temporary, JSON.pretty_generate(current))
    File.rename(temporary, state_dir.join(STATUS_FILE))
    current
  ensure
    FileUtils.rm_f(temporary) if temporary
  end

  def state_dir
    @base_path.join(STATE_DIR)
  end
end

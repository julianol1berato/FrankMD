# frozen_string_literal: true

require "test_helper"
require "aws-sdk-s3"
require "rubygems/package"
require "zlib"

class NotesBackupServiceTest < ActiveSupport::TestCase
  # Records uploads instead of talking to S3.
  class FakeS3Client
    attr_reader :uploads

    def initialize(error: nil, delay: nil)
      @uploads = []
      @error = error
      @delay = delay
    end

    def put_object(bucket:, key:, body:, **options)
      sleep @delay if @delay
      raise @error if @error

      @uploads << { bucket: bucket, key: key, data: body.respond_to?(:read) ? body.read : body.to_s, options: options }
      {}
    end
  end

  def setup
    setup_test_notes_dir
    write_config(<<~CONFIG)
      backup_enabled = true
      backup_time = 01:00
      backup_s3_bucket = notes-backup
      backup_s3_access_key_id = AKIATEST
      backup_s3_secret_access_key = test-secret
    CONFIG
    @client = FakeS3Client.new
  end

  def teardown
    teardown_test_notes_dir
  end

  # === run! ===

  test "run! uploads a daily snapshot and a monthly one on the first run of the month" do
    create_test_note("hello.md", "# Hello")

    status = service.run!(now: Time.local(2026, 10, 15, 1, 0))

    keys = @client.uploads.map { |upload| upload[:key] }
    assert_equal [ "frankmd-backups/daily/2026-10-15.tar.gz", "frankmd-backups/monthly/2026-10.tar.gz" ], keys
    assert @client.uploads.all? { |upload| upload[:bucket] == "notes-backup" }
    assert_equal "application/gzip", @client.uploads.first[:options][:content_type]
    assert_equal "frankmd-backups/daily/2026-10-15.tar.gz", status["last_key"]
    assert_equal "2026-10", status["last_monthly"]
    assert_nil status["last_error"]
    assert_equal @client.uploads.first[:data].bytesize, status["last_size"]
  end

  test "run! skips the monthly snapshot once the month has one" do
    create_test_note("hello.md")
    service.run!(now: Time.local(2026, 10, 15, 1, 0))
    @client.uploads.clear

    service.run!(now: Time.local(2026, 10, 16, 1, 0))

    assert_equal [ "frankmd-backups/daily/2026-10-16.tar.gz" ], @client.uploads.map { |upload| upload[:key] }
  end

  test "run! persists the status for later runs" do
    create_test_note("hello.md")
    service.run!(now: Time.local(2026, 10, 15, 1, 0))

    status = service.status
    assert_equal Time.local(2026, 10, 15, 1, 0).iso8601, status["last_success_at"]
    assert_equal Time.local(2026, 10, 15, 1, 0).iso8601, status["last_attempt_at"]
  end

  test "snapshot contains notes and folders with their content" do
    create_test_note("hello.md", "# Hello")
    create_test_note("Projetos/Backend/Notas de reunião.md", "Reunião")
    create_test_folder("Empty")
    create_test_note(".hugo_template.md", "---\ntitle: {{title}}\n---")

    service.run!(now: Time.local(2026, 10, 15, 1, 0))
    entries = archive_entries(@client.uploads.first[:data])

    assert_equal "# Hello", entries["hello.md"][:data]
    assert_equal "Reunião", entries["Projetos/Backend/Notas de reunião.md"][:data].force_encoding(Encoding::UTF_8)
    assert entries["Projetos/"][:directory]
    assert entries["Empty/"][:directory]
    assert entries.key?(".hugo_template.md"), "hidden notes such as the Hugo template are kept"
  end

  test "snapshot leaves out config, lock, state, git metadata and temporary files" do
    create_test_note("hello.md")
    create_test_note(".frankmd-filesystem.lock", "")
    create_test_note(".git/HEAD", "ref: refs/heads/master")
    create_test_note("Projetos/.draft.md.0123456789ab.tmp", "partial")

    service.run!(now: Time.local(2026, 10, 15, 1, 0))
    names = archive_entries(@client.uploads.first[:data]).keys

    assert_includes names, "hello.md"
    refute_includes names, ".fed"
    refute_includes names, ".frankmd-filesystem.lock"
    refute names.any? { |name| name.start_with?(".frankmd/") || name == ".frankmd/" }
    refute names.any? { |name| name.start_with?(".git") }
    refute names.any? { |name| name.end_with?(".tmp") }
  end

  test "snapshot does not follow symlinks out of the notes directory" do
    outside = Rails.root.join("tmp", "outside_#{SecureRandom.hex(4)}.txt")
    File.write(outside, "secret")
    File.symlink(outside, @test_notes_dir.join("link.md"))
    create_test_note("hello.md")

    service.run!(now: Time.local(2026, 10, 15, 1, 0))
    names = archive_entries(@client.uploads.first[:data]).keys

    assert_includes names, "hello.md"
    refute_includes names, "link.md"
  ensure
    FileUtils.rm_f(outside) if outside
  end

  test "snapshot keeps each file's modification time" do
    note = create_test_note("old.md")
    mtime = Time.local(2020, 1, 2, 3, 4, 5)
    File.utime(mtime, mtime, note)

    service.run!(now: Time.local(2026, 10, 15, 1, 0))

    assert_equal mtime.to_i, archive_entries(@client.uploads.first[:data])["old.md"][:mtime]
  end

  test "snapshot stores paths longer than 100 bytes" do
    path = "#{'a' * 60}/#{'b' * 60}/note.md"
    create_test_note(path, "deep")

    service.run!(now: Time.local(2026, 10, 15, 1, 0))

    assert_equal "deep", archive_entries(@client.uploads.first[:data])[path][:data]
  end

  test "run! fails loudly instead of skipping a file whose name does not fit the archive" do
    create_test_note("#{'x' * 120}.md")

    error = assert_raises(NotesBackupService::Error) { service.run!(now: Time.local(2026, 10, 15, 1, 0)) }

    assert_match "Path too long", error.message
    assert_match "Path too long", service.status["last_error"]
    assert_empty @client.uploads
  end

  test "run! records the error and re-raises when the upload fails" do
    create_test_note("hello.md")
    @client = FakeS3Client.new(error: Aws::S3::Errors::AccessDenied.new(nil, "Access Denied"))

    assert_raises(Aws::S3::Errors::AccessDenied) { service.run!(now: Time.local(2026, 10, 15, 1, 0)) }

    status = service.status
    assert_equal "AccessDenied: Access Denied", status["last_error"]
    assert_equal Time.local(2026, 10, 15, 1, 0).iso8601, status["last_attempt_at"]
    assert_nil status["last_success_at"]
  end

  test "run! requires bucket and credentials" do
    write_config("backup_enabled = true\nbackup_s3_bucket = notes-backup\n")

    assert_raises(NotesBackupService::NotConfiguredError) { service.run! }
    assert_empty @client.uploads
  end

  test "run! refuses to start while another run holds the lock" do
    lock_path = @test_notes_dir.join(".frankmd", "backup.lock")
    FileUtils.mkdir_p(lock_path.dirname)

    File.open(lock_path, File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      assert_raises(NotesBackupService::AlreadyRunningError) { service.run! }
    end
    assert_empty @client.uploads
  end

  test "object keys use the sanitized prefix" do
    write_config(<<~CONFIG)
      backup_s3_bucket = notes-backup
      backup_s3_prefix = "my notes/../backups"
      backup_s3_access_key_id = AKIATEST
      backup_s3_secret_access_key = test-secret
    CONFIG
    create_test_note("hello.md")

    service.run!(now: Time.local(2026, 10, 15, 1, 0))

    assert_equal "my_notes/backups/daily/2026-10-15.tar.gz", @client.uploads.first[:key]
  end

  # === due? ===

  test "due? is false while backups are disabled" do
    write_config(File.read(@test_notes_dir.join(".fed")).sub("backup_enabled = true", "backup_enabled = false"))

    refute service.due?(Time.local(2026, 10, 15, 9, 0))
  end

  test "due? waits for the scheduled time" do
    refute service.due?(Time.local(2026, 10, 15, 0, 59))
    assert service.due?(Time.local(2026, 10, 15, 1, 0))
  end

  test "due? is false after a backup succeeded since the scheduled time" do
    write_status("last_success_at" => Time.local(2026, 10, 15, 1, 0, 30).iso8601)

    refute service.due?(Time.local(2026, 10, 15, 18, 0))
    assert service.due?(Time.local(2026, 10, 16, 1, 0))
  end

  test "due? catches up on a backup missed while the server was down" do
    write_status("last_success_at" => Time.local(2026, 10, 13, 1, 0).iso8601)

    assert service.due?(Time.local(2026, 10, 15, 9, 30))
  end

  test "due? retries a failed run after the retry interval" do
    write_status(
      "last_success_at" => Time.local(2026, 10, 14, 1, 0).iso8601,
      "last_attempt_at" => Time.local(2026, 10, 15, 1, 0).iso8601
    )

    refute service.due?(Time.local(2026, 10, 15, 1, 30))
    assert service.due?(Time.local(2026, 10, 15, 2, 0))
  end

  test "due? falls back to 01:00 for an invalid backup time" do
    write_config(File.read(@test_notes_dir.join(".fed")).sub("backup_time = 01:00", "backup_time = 25:99"))

    refute service.due?(Time.local(2026, 10, 15, 0, 30))
    assert service.due?(Time.local(2026, 10, 15, 1, 0))
  end

  test "valid_time? accepts HH:MM only" do
    assert NotesBackupService.valid_time?("01:00")
    assert NotesBackupService.valid_time?("23:59")
    assert NotesBackupService.valid_time?("7:05")
    refute NotesBackupService.valid_time?("24:00")
    refute NotesBackupService.valid_time?("1am")
    refute NotesBackupService.valid_time?("")
  end

  # === test_connection! ===

  test "test_connection! uploads a marker object" do
    assert service.test_connection!

    assert_equal [ "frankmd-backups/.frankmd-connection-test" ], @client.uploads.map { |upload| upload[:key] }
  end

  test "test_connection! gives up when the endpoint does not answer in time" do
    @client = FakeS3Client.new(delay: 5)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(NotesBackupService::ConnectionTimeoutError) { service.test_connection!(timeout: 0.2) }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_match "0.2 seconds", error.message
  end

  test "test_connection! reports the endpoint's own error when it fails in time" do
    @client = FakeS3Client.new(error: Seahorse::Client::NetworkingError.new(SocketError.new("getaddrinfo failed")))

    assert_raises(Seahorse::Client::NetworkingError) { service.test_connection! }
  end

  # === S3 client ===

  test "uses AWS defaults when no endpoint is configured" do
    Aws::S3::Client.expects(:new).with do |options|
      options[:region] == "us-east-1" &&
        options[:access_key_id] == "AKIATEST" &&
        !options.key?(:endpoint) &&
        !options.key?(:request_checksum_calculation)
    end.returns(@client)

    NotesBackupService.new.test_connection!
  end

  test "configures custom endpoints for S3-compatible services" do
    write_config(<<~CONFIG)
      backup_s3_bucket = notes-backup
      backup_s3_access_key_id = AKIATEST
      backup_s3_secret_access_key = test-secret
      backup_s3_region = us-west-004
      backup_s3_endpoint = https://s3.us-west-004.backblazeb2.com
      backup_s3_force_path_style = true
    CONFIG

    Aws::S3::Client.expects(:new).with(
      has_entries(
        region: "us-west-004",
        endpoint: "https://s3.us-west-004.backblazeb2.com",
        force_path_style: true,
        request_checksum_calculation: "when_required",
        response_checksum_validation: "when_required"
      )
    ).returns(@client)

    NotesBackupService.new.test_connection!
  end

  test "custom endpoints use path-style URLs unless turned off" do
    write_config(<<~CONFIG)
      backup_s3_bucket = notes-backup
      backup_s3_access_key_id = AKIATEST
      backup_s3_secret_access_key = test-secret
      backup_s3_endpoint = http://seaweedfs:8333
    CONFIG

    Aws::S3::Client.expects(:new).with(has_entries(force_path_style: true)).returns(@client)

    NotesBackupService.new.test_connection!
  end

  private

  def service
    NotesBackupService.new(client: @client)
  end

  def write_config(content)
    @test_notes_dir.join(".fed").write(content)
  end

  def write_status(status)
    path = @test_notes_dir.join(".frankmd", "backup-status.json")
    FileUtils.mkdir_p(path.dirname)
    path.write(JSON.generate(status))
  end

  def archive_entries(data)
    entries = {}
    Zlib::GzipReader.wrap(StringIO.new(data)) do |gzip|
      Gem::Package::TarReader.new(gzip).each do |entry|
        entries[entry.full_name] = {
          directory: entry.directory?,
          data: entry.file? ? entry.read.to_s : nil,
          mtime: entry.header.mtime
        }
      end
    end
    entries
  end
end

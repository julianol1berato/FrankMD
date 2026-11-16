# frozen_string_literal: true

require "test_helper"
require "aws-sdk-s3"

class BackupControllerTest < ActionDispatch::IntegrationTest
  def setup
    setup_test_notes_dir
  end

  def teardown
    teardown_test_notes_dir
  end

  # === show ===

  test "show returns settings, status and masks secrets" do
    write_config(<<~CONFIG)
      backup_enabled = true
      backup_s3_bucket = notes-backup
      backup_s3_access_key_id = AKIATEST
      backup_s3_secret_access_key = super-secret-value
    CONFIG

    get backup_url, as: :json
    assert_response :success

    data = JSON.parse(response.body)
    settings = data["settings"]
    assert_equal true, settings["backup_enabled"]
    assert_equal "notes-backup", settings["backup_s3_bucket"]
    assert_equal "01:00", settings["backup_time"]
    assert_equal "frankmd-backups", settings["backup_s3_prefix"]
    assert_equal true, settings["backup_s3_access_key_id_configured"]
    assert_equal true, settings["backup_s3_secret_access_key_configured"]
    refute settings.key?("backup_s3_secret_access_key")
    refute_includes response.body, "super-secret-value"
    refute_includes response.body, "AKIATEST"
    assert_equal true, data["configured"]
    assert_equal({}, data["status"])
  end

  test "show reports an unconfigured backup" do
    get backup_url, as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal false, data["configured"]
    assert_equal false, data["settings"]["backup_s3_secret_access_key_configured"]
  end

  # === update ===

  test "update saves backup settings to the .fed file" do
    patch backup_url, params: {
      backup_enabled: true,
      backup_time: "02:30",
      backup_s3_bucket: "notes-backup",
      backup_s3_endpoint: "https://s3.eu-central-1.wasabisys.com",
      backup_s3_access_key_id: "AKIATEST",
      backup_s3_secret_access_key: "secret"
    }, as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "Backup settings saved", data["message"]
    assert_equal true, data["configured"]

    config = Config.new
    assert_equal true, config.get("backup_enabled")
    assert_equal "02:30", config.get("backup_time")
    assert_equal "https://s3.eu-central-1.wasabisys.com", config.get("backup_s3_endpoint")
    assert_equal "secret", config.get("backup_s3_secret_access_key")
  end

  test "update keeps stored secrets when they are left blank" do
    write_config("backup_s3_access_key_id = AKIATEST\nbackup_s3_secret_access_key = secret\n")

    patch backup_url, params: {
      backup_s3_bucket: "notes-backup",
      backup_s3_access_key_id: "",
      backup_s3_secret_access_key: ""
    }, as: :json
    assert_response :success

    config = Config.new
    assert_equal "AKIATEST", config.get("backup_s3_access_key_id")
    assert_equal "secret", config.get("backup_s3_secret_access_key")
    assert_equal "notes-backup", config.get("backup_s3_bucket")
  end

  test "update rejects an invalid backup time" do
    patch backup_url, params: { backup_time: "25:00" }, as: :json
    assert_response :unprocessable_entity

    assert_equal "Backup time must use the HH:MM format", JSON.parse(response.body)["error"]
    assert_equal "01:00", Config.new.get("backup_time")
  end

  test "update ignores keys outside the backup settings" do
    patch backup_url, params: { theme: "dark", aws_secret_access_key: "nope" }, as: :json
    assert_response :unprocessable_entity

    assert_nil Config.new.get("aws_secret_access_key")
  end

  # === run_now ===

  test "run_now uploads a backup and returns the new status" do
    configure_backup
    create_test_note("hello.md")
    client = Object.new
    def client.put_object(**) = {}
    Aws::S3::Client.stubs(:new).returns(client)

    post backup_run_url, as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "Backup uploaded", data["message"]
    assert_match %r{\Afrankmd-backups/daily/\d{4}-\d{2}-\d{2}\.tar\.gz\z}, data["status"]["last_key"]
  end

  test "run_now requires a configured backup" do
    post backup_run_url, as: :json
    assert_response :unprocessable_entity

    assert_equal "Backup storage is not configured", JSON.parse(response.body)["error"]
  end

  test "run_now reports a run already in progress" do
    configure_backup
    NotesBackupService.any_instance.stubs(:run!).raises(NotesBackupService::AlreadyRunningError)

    post backup_run_url, as: :json
    assert_response :conflict

    assert_equal "A backup is already running", JSON.parse(response.body)["error"]
  end

  test "run_now reports upload failures" do
    configure_backup
    NotesBackupService.any_instance.stubs(:run!).raises(Aws::S3::Errors::AccessDenied.new(nil, "Access Denied"))

    post backup_run_url, as: :json
    assert_response :bad_gateway

    assert_equal "Backup failed: AccessDenied: Access Denied", JSON.parse(response.body)["error"]
  end

  # === test_connection ===

  test "test_connection confirms the bucket accepts uploads" do
    configure_backup
    NotesBackupService.any_instance.expects(:test_connection!).returns(true)

    post backup_test_url, as: :json
    assert_response :success

    assert_equal "Connection OK: the bucket accepted a test upload", JSON.parse(response.body)["message"]
  end

  test "test_connection reports failures" do
    configure_backup
    NotesBackupService.any_instance.stubs(:test_connection!).raises(Aws::S3::Errors::NoSuchBucket.new(nil, "The specified bucket does not exist"))

    post backup_test_url, as: :json
    assert_response :bad_gateway

    assert_equal "Backup failed: NoSuchBucket: The specified bucket does not exist", JSON.parse(response.body)["error"]
  end

  test "test_connection gives up on an endpoint that does not answer" do
    configure_backup
    NotesBackupService.any_instance.stubs(:test_connection!).raises(NotesBackupService::ConnectionTimeoutError)

    post backup_test_url, as: :json
    assert_response :gateway_timeout

    assert_equal "The storage endpoint did not respond within 10 seconds. Check the endpoint address and the Path-style URLs option.",
      JSON.parse(response.body)["error"]
  end

  test "test_connection requires a configured backup" do
    post backup_test_url, as: :json
    assert_response :unprocessable_entity
  end

  private

  def write_config(content)
    @test_notes_dir.join(".fed").write(content)
  end

  def configure_backup
    write_config(<<~CONFIG)
      backup_s3_bucket = notes-backup
      backup_s3_access_key_id = AKIATEST
      backup_s3_secret_access_key = secret
    CONFIG
  end
end

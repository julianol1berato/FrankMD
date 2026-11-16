# frozen_string_literal: true

require "test_helper"
require "aws-sdk-s3"

class NotesBackupSchedulerTest < ActiveSupport::TestCase
  def setup
    setup_test_notes_dir
  end

  def teardown
    thread = NotesBackupScheduler.instance_variable_get(:@thread)
    thread&.kill
    thread&.join
    NotesBackupScheduler.instance_variable_set(:@thread, nil)
    teardown_test_notes_dir
  end

  test "tick runs a backup when one is due" do
    now = Time.local(2026, 10, 15, 1, 0)
    NotesBackupService.any_instance.stubs(:due?).with(now).returns(true)
    NotesBackupService.any_instance.expects(:run!).with(now: now).once

    NotesBackupScheduler.tick(now: now)
  end

  test "tick does nothing when no backup is due" do
    NotesBackupService.any_instance.stubs(:due?).returns(false)
    NotesBackupService.any_instance.expects(:run!).never

    NotesBackupScheduler.tick
  end

  test "tick logs failures instead of killing the scheduler thread" do
    NotesBackupService.any_instance.stubs(:due?).returns(true)
    NotesBackupService.any_instance.stubs(:run!).raises(Aws::S3::Errors::AccessDenied.new(nil, "Access Denied"))
    Rails.logger.expects(:error).with("[Backup] AccessDenied: Access Denied")

    assert_nil NotesBackupScheduler.tick
  end

  test "tick ignores a run that is already in progress" do
    NotesBackupService.any_instance.stubs(:due?).returns(true)
    NotesBackupService.any_instance.stubs(:run!).raises(NotesBackupService::AlreadyRunningError)
    Rails.logger.expects(:error).never

    assert_nil NotesBackupScheduler.tick
  end

  test "start keeps a single background thread" do
    first = NotesBackupScheduler.start(interval: 3600)
    second = NotesBackupScheduler.start(interval: 3600)

    assert first.alive?
    assert_same first, second
    assert_equal "frankmd-notes-backup", first.name
  end
end

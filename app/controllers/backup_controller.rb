# frozen_string_literal: true

class BackupController < ApplicationController
  # Disable automatic parameter wrapping (Rails wraps JSON params under controller name)
  wrap_parameters false

  before_action :set_config

  # GET /backup
  # Returns backup settings (secrets only as *_configured flags) and run status
  def show
    render json: payload
  end

  # PATCH /backup
  # Updates backup settings. Secrets are write-only: a blank value keeps the
  # stored one, so the dialog never needs to read them back.
  def update
    updates = params.permit(*Config::BACKUP_KEYS).to_h
    Config::SENSITIVE_KEYS.each { |key| updates.delete(key) if updates[key].blank? }

    if updates.empty?
      render json: { error: t("errors.no_valid_settings") }, status: :unprocessable_entity
      return
    end

    if updates.key?("backup_time") && !NotesBackupService.valid_time?(updates["backup_time"])
      render json: { error: t("errors.invalid_backup_time") }, status: :unprocessable_entity
      return
    end

    if @config.update(updates)
      render json: payload.merge(message: t("success.backup_settings_saved"))
    else
      render json: { error: t("errors.failed_to_save") }, status: :unprocessable_entity
    end
  end

  # POST /backup/run
  # Uploads a snapshot now, regardless of the schedule
  def run_now
    backup_service.run!
    render json: payload.merge(message: t("success.backup_completed"))
  rescue NotesBackupService::NotConfiguredError
    render json: { error: t("errors.backup_not_configured") }, status: :unprocessable_entity
  rescue NotesBackupService::AlreadyRunningError
    render json: { error: t("errors.backup_already_running") }, status: :conflict
  rescue StandardError => e
    render json: payload.merge(error: t("errors.backup_failed", message: NotesBackupService.error_message(e))),
      status: :bad_gateway
  end

  # POST /backup/test
  # Checks that the bucket accepts uploads with the configured credentials
  def test_connection
    backup_service.test_connection!
    render json: { message: t("success.backup_connection_ok") }
  rescue NotesBackupService::NotConfiguredError
    render json: { error: t("errors.backup_not_configured") }, status: :unprocessable_entity
  rescue NotesBackupService::ConnectionTimeoutError
    render json: { error: t("errors.backup_connection_timeout", seconds: NotesBackupService::CONNECTION_TEST_TIMEOUT) },
      status: :gateway_timeout
  rescue StandardError => e
    render json: { error: t("errors.backup_failed", message: NotesBackupService.error_message(e)) },
      status: :bad_gateway
  end

  private

  def set_config
    @config = Config.new
  end

  def backup_service
    @backup_service ||= NotesBackupService.new(config: @config)
  end

  def payload
    settings = Config::BACKUP_KEYS.each_with_object({}) do |key, hash|
      if Config::SENSITIVE_KEYS.include?(key)
        hash["#{key}_configured"] = @config.get(key).present?
      else
        hash[key] = @config.get(key)
      end
    end

    { settings: settings, configured: backup_service.configured?, status: backup_service.status }
  end
end

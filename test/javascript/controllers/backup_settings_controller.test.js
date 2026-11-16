/**
 * @vitest-environment jsdom
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import { get, patch, post } from "@rails/request.js"
import BackupSettingsController from "../../../app/javascript/controllers/backup_settings_controller.js"

vi.mock("@rails/request.js", () => ({ get: vi.fn(), patch: vi.fn(), post: vi.fn() }))

const messages = {
  saving: "Saving…",
  testing: "Testing connection…",
  running: "Backing up…",
  request_failed: "Request failed",
  never: "No backup yet",
  secret_configured: "Configured; leave blank to keep",
  secret_missing: "Not set"
}

function backupPayload(overrides = {}) {
  return {
    settings: {
      backup_enabled: true,
      backup_time: "01:00",
      backup_s3_bucket: "notes-backup",
      backup_s3_prefix: "frankmd-backups",
      backup_s3_region: "us-west-004",
      backup_s3_endpoint: "https://s3.us-west-004.backblazeb2.com",
      backup_s3_force_path_style: false,
      backup_s3_access_key_id_configured: true,
      backup_s3_secret_access_key_configured: false,
      ...overrides.settings
    },
    configured: true,
    status: overrides.status || {}
  }
}

function jsonResponse(data, ok = true) {
  return { ok, json: Promise.resolve(data) }
}

describe("BackupSettingsController", () => {
  let application
  let controller
  let element

  const field = (name) => element.querySelector(`[name="${name}"]`)
  const toggle = (key) => element.querySelector(`[data-key="${key}"]`)
  const message = () => element.querySelector('[data-backup-settings-target="message"]')

  beforeEach(async () => {
    vi.clearAllMocks()
    get.mockResolvedValue(jsonResponse(backupPayload()))

    document.body.innerHTML = `
      <div data-controller="backup-settings" data-backup-settings-messages-value='${JSON.stringify(messages)}'>
        <button type="button" data-backup-settings-target="toggle" data-key="backup_enabled" aria-pressed="false" data-action="click->backup-settings#toggle"></button>
        <input name="backup_time" data-backup-settings-target="field">
        <input name="backup_s3_bucket" data-backup-settings-target="field">
        <input name="backup_s3_prefix" data-backup-settings-target="field">
        <input name="backup_s3_region" data-backup-settings-target="field">
        <input name="backup_s3_endpoint" data-backup-settings-target="field">
        <button type="button" data-backup-settings-target="toggle" data-key="backup_s3_force_path_style" aria-pressed="false" data-action="click->backup-settings#toggle"></button>
        <input type="password" name="backup_s3_access_key_id" data-backup-settings-target="secret">
        <input type="password" name="backup_s3_secret_access_key" data-backup-settings-target="secret">
        <button type="button" data-backup-settings-target="button" data-action="click->backup-settings#save">Save</button>
        <button type="button" data-backup-settings-target="button" data-action="click->backup-settings#testConnection">Test</button>
        <button type="button" data-backup-settings-target="button" data-action="click->backup-settings#runNow">Run</button>
        <p class="hidden" data-backup-settings-target="message"></p>
        <span data-backup-settings-target="lastBackup">No backup yet</span>
        <p class="hidden" data-backup-settings-target="lastError"></p>
      </div>
    `
    element = document.querySelector('[data-controller="backup-settings"]')
    application = Application.start()
    application.register("backup-settings", BackupSettingsController)
    await vi.waitFor(() => {
      controller = application.getControllerForElementAndIdentifier(element, "backup-settings")
      expect(controller).toBeTruthy()
    })
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  it("loads settings into the fields and toggles", async () => {
    await controller.load()

    expect(get).toHaveBeenCalledWith("/backup", { responseKind: "json" })
    expect(field("backup_s3_bucket").value).toBe("notes-backup")
    expect(field("backup_time").value).toBe("01:00")
    expect(field("backup_s3_endpoint").value).toBe("https://s3.us-west-004.backblazeb2.com")
    expect(toggle("backup_enabled").getAttribute("aria-pressed")).toBe("true")
    expect(toggle("backup_s3_force_path_style").getAttribute("aria-pressed")).toBe("false")
  })

  it("never fills secrets and only hints whether they are configured", async () => {
    await controller.load()

    expect(field("backup_s3_access_key_id").value).toBe("")
    expect(field("backup_s3_access_key_id").placeholder).toBe(messages.secret_configured)
    expect(field("backup_s3_secret_access_key").placeholder).toBe(messages.secret_missing)
  })

  it("shows the last successful backup and the last error", async () => {
    get.mockResolvedValue(jsonResponse(backupPayload({
      status: {
        last_success_at: "2026-10-15T01:00:00-03:00",
        last_size: 1536,
        last_key: "frankmd-backups/daily/2026-10-15.tar.gz",
        last_error: "AccessDenied: Access Denied"
      }
    })))

    await controller.load()

    const lastBackup = element.querySelector('[data-backup-settings-target="lastBackup"]').textContent
    expect(lastBackup).toContain("1.5 KB")
    expect(lastBackup).toContain("frankmd-backups/daily/2026-10-15.tar.gz")
    const lastError = element.querySelector('[data-backup-settings-target="lastError"]')
    expect(lastError.textContent).toBe("AccessDenied: Access Denied")
    expect(lastError.classList.contains("hidden")).toBe(false)
  })

  it("flips a switch on click", () => {
    toggle("backup_enabled").click()
    expect(toggle("backup_enabled").getAttribute("aria-pressed")).toBe("true")
    toggle("backup_enabled").click()
    expect(toggle("backup_enabled").getAttribute("aria-pressed")).toBe("false")
  })

  it("saves fields and toggles, sends only filled secrets and clears them", async () => {
    await controller.load()
    patch.mockResolvedValue(jsonResponse({ ...backupPayload(), message: "Backup settings saved" }))
    field("backup_s3_bucket").value = "  other-bucket  "
    field("backup_s3_secret_access_key").value = "new-secret"

    await controller.save()

    expect(patch).toHaveBeenCalledWith("/backup", {
      body: {
        backup_time: "01:00",
        backup_s3_bucket: "other-bucket",
        backup_s3_prefix: "frankmd-backups",
        backup_s3_region: "us-west-004",
        backup_s3_endpoint: "https://s3.us-west-004.backblazeb2.com",
        backup_enabled: true,
        backup_s3_force_path_style: false,
        backup_s3_secret_access_key: "new-secret"
      },
      responseKind: "json"
    })
    expect(field("backup_s3_secret_access_key").value).toBe("")
    expect(message().textContent).toBe("Backup settings saved")
    expect(message().classList.contains("hidden")).toBe(false)
  })

  it("shows the server error when a request fails", async () => {
    post.mockResolvedValue(jsonResponse({ error: "Backup failed: AccessDenied: Access Denied" }, false))

    await controller.testConnection()

    expect(post).toHaveBeenCalledWith("/backup/test", { responseKind: "json" })
    expect(message().textContent).toBe("Backup failed: AccessDenied: Access Denied")
    expect(message().classList.contains("text-[var(--theme-error)]")).toBe(true)
  })

  it("runs a backup now and refreshes the status from the response", async () => {
    post.mockResolvedValue(jsonResponse({
      ...backupPayload({ status: { last_success_at: "2026-10-15T14:00:00Z", last_size: 2048 } }),
      message: "Backup uploaded"
    }))

    await controller.runNow()

    expect(post).toHaveBeenCalledWith("/backup/run", { responseKind: "json" })
    expect(message().textContent).toBe("Backup uploaded")
    expect(element.querySelector('[data-backup-settings-target="lastBackup"]').textContent).toContain("2.0 KB")
  })

  it("disables the buttons while a request is in flight", async () => {
    let resolveRequest
    post.mockReturnValue(new Promise((resolve) => { resolveRequest = resolve }))
    const buttons = element.querySelectorAll('[data-backup-settings-target="button"]')

    const pending = controller.runNow()
    expect([...buttons].every((button) => button.disabled)).toBe(true)
    expect(message().textContent).toBe(messages.running)

    resolveRequest(jsonResponse({ message: "Backup uploaded" }))
    await pending
    expect([...buttons].every((button) => !button.disabled)).toBe(true)
  })

  it("reports a generic failure when the request throws", async () => {
    post.mockRejectedValue(new Error("network down"))

    await controller.runNow()

    expect(message().textContent).toBe(messages.request_failed)
  })
})

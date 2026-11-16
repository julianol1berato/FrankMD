import { Controller } from "@hotwired/stimulus"
import { get, patch, post } from "@rails/request.js"

// BackupSettingsController
// Backup section of the settings dialog. Loads GET /backup when the section
// opens, saves with PATCH /backup and triggers POST /backup/test and
// POST /backup/run. Secrets are write-only: the server only reports whether
// they are set, and a blank secret field keeps the stored value.

export default class extends Controller {
  static targets = ["field", "toggle", "secret", "button", "message", "lastBackup", "lastError"]

  static values = {
    messages: { type: Object, default: {} }
  }

  async load() {
    try {
      const response = await get("/backup", { responseKind: "json" })
      if (!response.ok) return

      this.render(await response.json)
    } catch (error) {
      console.warn("Failed to load backup settings:", error)
    }
  }

  toggle(event) {
    const button = event.currentTarget
    button.setAttribute("aria-pressed", String(button.getAttribute("aria-pressed") !== "true"))
  }

  async save() {
    await this.request(patch, "/backup", this.messagesValue.saving, { body: this.formData() })
    this.secretTargets.forEach((input) => { input.value = "" })
  }

  async testConnection() {
    await this.request(post, "/backup/test", this.messagesValue.testing)
  }

  async runNow() {
    await this.request(post, "/backup/run", this.messagesValue.running)
  }

  // === Private ===

  async request(method, url, pendingMessage, options = {}) {
    this.setBusy(true)
    this.showMessage(pendingMessage, false)

    try {
      const response = await method(url, { ...options, responseKind: "json" })
      const data = await response.json.catch(() => ({}))

      if (data.settings) this.render(data)
      if (response.ok) {
        this.showMessage(data.message, false)
      } else {
        this.showMessage(data.error || this.messagesValue.request_failed, true)
      }
    } catch (error) {
      console.warn("Backup request failed:", error)
      this.showMessage(this.messagesValue.request_failed, true)
    } finally {
      this.setBusy(false)
    }
  }

  formData() {
    const data = {}
    this.fieldTargets.forEach((input) => { data[input.name] = input.value.trim() })
    this.toggleTargets.forEach((button) => {
      data[button.dataset.key] = button.getAttribute("aria-pressed") === "true"
    })
    this.secretTargets.forEach((input) => {
      const value = input.value.trim()
      if (value) data[input.name] = value
    })
    return data
  }

  render(data) {
    const settings = data.settings || {}

    this.fieldTargets.forEach((input) => {
      const value = settings[input.name]
      input.value = value === null || value === undefined ? "" : String(value)
    })
    this.toggleTargets.forEach((button) => {
      button.setAttribute("aria-pressed", String(settings[button.dataset.key] === true))
    })
    this.secretTargets.forEach((input) => {
      input.placeholder = settings[`${input.name}_configured`]
        ? this.messagesValue.secret_configured
        : this.messagesValue.secret_missing
    })

    this.renderStatus(data.status || {})
  }

  renderStatus(status) {
    if (this.hasLastBackupTarget) {
      this.lastBackupTarget.textContent = status.last_success_at
        ? this.describeBackup(status)
        : this.messagesValue.never
    }

    if (this.hasLastErrorTarget) {
      this.lastErrorTarget.textContent = status.last_error || ""
      this.lastErrorTarget.classList.toggle("hidden", !status.last_error)
    }
  }

  describeBackup(status) {
    const date = new Date(status.last_success_at)
    const when = Number.isNaN(date.getTime()) ? status.last_success_at : date.toLocaleString()
    const parts = [when]
    if (Number.isFinite(status.last_size)) parts.push(this.formatSize(status.last_size))
    if (status.last_key) parts.push(status.last_key)
    return parts.join(" · ")
  }

  formatSize(bytes) {
    if (bytes < 1024) return `${bytes} B`
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }

  setBusy(busy) {
    this.buttonTargets.forEach((button) => { button.disabled = busy })
  }

  showMessage(message, isError) {
    if (!this.hasMessageTarget) return

    this.messageTarget.textContent = message || ""
    this.messageTarget.classList.toggle("hidden", !message)
    this.messageTarget.classList.toggle("text-[var(--theme-error)]", isError)
    this.messageTarget.classList.toggle("text-[var(--theme-text-muted)]", !isError)
  }
}

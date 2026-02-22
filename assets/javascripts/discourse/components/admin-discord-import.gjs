import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { fn, hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import DButton from "discourse/components/d-button";

// ---------------------------------------------------------------------------
// Helper: get CSRF token
// ---------------------------------------------------------------------------
function csrfToken() {
  return document.querySelector("meta[name=csrf-token]")?.content ?? "";
}

// ---------------------------------------------------------------------------
// Helper: sanitize a string into a valid Discourse username
// Rules: a-z 0-9 . _ -  max 20 chars, must start/end alphanumeric,
//        no consecutive specials.
// ---------------------------------------------------------------------------
function sanitizeUsername(name) {
  let s = (name || "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "_")   // invalid chars → _
    .replace(/^[^a-z0-9]+/, "")       // strip leading non-alphanumeric
    .replace(/[^a-z0-9]+$/, "")       // strip trailing non-alphanumeric
    .replace(/[._-]{2,}/g, "_")       // collapse consecutive specials
    .slice(0, 20);
  if (s.length < 3) s = s.padEnd(3, "0");
  return s || "user";
}

// ---------------------------------------------------------------------------
// Helper: post FormData to a URL, return parsed JSON
// ---------------------------------------------------------------------------
async function postFormData(url, formData) {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "X-CSRF-Token": csrfToken(),
      "Accept": "application/json",
    },
    body: formData,
  });
  if (!response.ok) {
    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      const json = await response.json();
      throw new Error(json.error || `HTTP ${response.status}`);
    }
    throw new Error(`HTTP ${response.status}: ${response.statusText}`);
  }
  return response.json();
}

// ---------------------------------------------------------------------------
// Sub-component: topic search picker
// ---------------------------------------------------------------------------
class TopicPickerInput extends Component {
  @tracked searchTerm = "";
  @tracked searchResults = [];
  @tracked searching = false;
  @tracked selectedTitle = null;

  @action
  async onSearchInput(event) {
    const term = event.target.value;
    this.searchTerm = term;
    if (term.length < 2) {
      this.searchResults = [];
      return;
    }
    this.searching = true;
    try {
      const result = await ajax("/search.json", { data: { q: term } });
      this.searchResults = result.topics ?? [];
    } finally {
      this.searching = false;
    }
  }

  @action
  selectTopic(topic) {
    this.selectedTitle = topic.title;
    this.searchTerm = topic.title;
    this.searchResults = [];
    this.args.onChange(topic.id);
  }

  <template>
    <div class="topic-picker">
      <input
        type="text"
        class="topic-search-input"
        placeholder="Search for a topic…"
        value={{this.searchTerm}}
        {{on "input" this.onSearchInput}}
      />
      {{#if this.searching}}
        <span class="searching">…</span>
      {{/if}}
      {{#if this.searchResults.length}}
        <ul class="topic-search-results">
          {{#each this.searchResults as |topic|}}
            <li>
              <button type="button" {{on "click" (fn this.selectTopic topic)}}>
                {{topic.title}}
              </button>
            </li>
          {{/each}}
        </ul>
      {{/if}}
      {{#if this.selectedTitle}}
        <span class="topic-selected-label">→ {{this.selectedTitle}}</span>
      {{/if}}
    </div>
  </template>
}

// ---------------------------------------------------------------------------
// Sub-component: user dropdown for each Discord user
// ---------------------------------------------------------------------------
class UserMappingRow extends Component {
  @tracked searchTerm = this.args.initial?.username ?? "";
  @tracked searchResults = [];
  @tracked searching = false;
  @tracked selected = this.args.initial ?? null; // { id, username, name } | { new: true, username } | "omit" | "anonymous" | null

  get isNewUser() {
    return this.selected?.new === true;
  }

  @action
  async onSearchInput(event) {
    const term = event.target.value;
    this.searchTerm = term;

    // In new-user mode: update the pending username, don't search
    if (this.isNewUser) {
      this.selected = { new: true, username: term };
      this.args.onChange(this.args.discordUser.discord_id, { type: "new", username: term });
      return;
    }

    if (term.length < 2) {
      this.searchResults = [];
      return;
    }
    this.searching = true;
    try {
      const result = await ajax("/u/search/users.json", {
        data: { term, include_staged_users: true },
      });
      this.searchResults = result.users ?? [];
    } finally {
      this.searching = false;
    }
  }

  @action
  selectUser(user) {
    this.selected = user;
    this.searchTerm = user.username;
    this.searchResults = [];
    this.args.onChange(this.args.discordUser.discord_id, user.id);
  }

  @action
  selectSpecial(value) {
    this.selected = value;
    this.searchTerm = value === "omit" ? "Omit" : "Anonymous";
    this.searchResults = [];
    this.args.onChange(this.args.discordUser.discord_id, value);
  }

  @action
  selectNewUser() {
    const username = sanitizeUsername(this.args.discordUser.name);
    this.selected = { new: true, username };
    this.searchTerm = username;
    this.searchResults = [];
    this.args.onChange(this.args.discordUser.discord_id, { type: "new", username });
  }

  <template>
    <div class="discord-user-row">
      <div class="discord-user-info">
        <img
          class="discord-avatar"
          src={{@discordUser.avatar_url}}
          alt=""
          width="32"
          height="32"
        />
        <div>
          <strong>{{@discordUser.nickname}}</strong>
          <span class="discord-username">@{{@discordUser.name}}</span>
        </div>
      </div>
      <div class="discourse-user-select">
        <input
          type="text"
          class="discourse-user-search-input {{if this.isNewUser "new-user-mode"}}"
          placeholder={{if this.isNewUser "Username for new user…" "Search users…"}}
          value={{this.searchTerm}}
          {{on "input" this.onSearchInput}}
        />
        {{#if this.searching}}
          <span class="searching">…</span>
        {{/if}}
        {{#if this.isNewUser}}
          <span class="new-user-badge">New staged user</span>
        {{/if}}
        {{#if this.searchResults.length}}
          <ul class="user-search-results">
            {{#each this.searchResults as |user|}}
              <li>
                <button
                  type="button"
                  {{on "click" (fn this.selectUser user)}}
                >
                  @{{user.username}} — {{user.name}}
                </button>
              </li>
            {{/each}}
            <li class="special-divider">──────</li>
            <li>
              <button type="button" {{on "click" (fn this.selectSpecial "omit")}}>
                Omit
              </button>
            </li>
            <li>
              <button type="button" {{on "click" (fn this.selectSpecial "anonymous")}}>
                Anonymous
              </button>
            </li>
          </ul>
        {{/if}}
        {{#if (eq this.searchResults.length 0)}}
          <div class="quick-specials">
            <button
              type="button"
              class="btn-small {{if (eq this.selected "omit") "active"}}"
              {{on "click" (fn this.selectSpecial "omit")}}
            >Omit</button>
            <button
              type="button"
              class="btn-small {{if (eq this.selected "anonymous") "active"}}"
              {{on "click" (fn this.selectSpecial "anonymous")}}
            >Anonymous</button>
            <button
              type="button"
              class="btn-small {{if this.isNewUser "active"}}"
              {{on "click" this.selectNewUser}}
            >New</button>
          </div>
        {{/if}}
      </div>
    </div>
  </template>
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------
export default class AdminDiscordImport extends Component {
  @service site;

  // Phase: "upload" | "configure" | "importing" | "results"
  @tracked phase = "upload";
  @tracked selectedFile = null;
  @tracked analyzing = false;
  @tracked analyzeError = null;

  // Data from analyze response
  @tracked channels = [];  // with .config attached
  @tracked users = [];

  // User mappings: { discord_id -> discourse_user_id | "omit" | "anonymous" }
  userMappings = {};

  // Duplicate post handling: "ignore" | "update"
  @tracked duplicateMode = "ignore";

  // Confirmation modal
  @tracked showConfirmModal = false;
  @tracked importError = null;

  // Results
  @tracked importResults = [];

  // ---------------------------------------------------------------------------
  // Phase 1 — file selection
  // ---------------------------------------------------------------------------

  @action
  onFileChange(event) {
    this.selectedFile = event.target.files[0] ?? null;
    this.analyzeError = null;
  }

  @action
  async analyzeArchive() {
    if (!this.selectedFile) return;
    this.analyzing = true;
    this.analyzeError = null;
    try {
      const fd = new FormData();
      fd.append("file", this.selectedFile);
      const result = await postFormData("/discordimport/analyze", fd);

      // Attach editable config to each channel
      this.channels = (result.channels ?? []).map((ch) => ({
        ...ch,
        config: {
          action: "skip",       // "skip" | "existing" | "create"
          topic_id: null,
          topic_search: "",
          new_topic_title: ch.channel_name,
          new_topic_category_id: null,
          split_threads: false,
        },
      }));

      // Pre-populate user mappings from suggestions
      this.users = result.users ?? [];
      this.userMappings = {};
      this.users.forEach((u) => {
        if (u.suggested_discourse_user_id) {
          this.userMappings[u.discord_id] = u.suggested_discourse_user_id;
        }
      });

      this.phase = "configure";
    } catch (e) {
      this.analyzeError = e.message;
    } finally {
      this.analyzing = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Phase 2 — channel config helpers
  // ---------------------------------------------------------------------------

  @action
  setChannelAction(channel, event) {
    this.channels = this.channels.map((ch) =>
      ch === channel
        ? { ...ch, config: { ...ch.config, action: event.target.value } }
        : ch
    );
  }

  @action
  setChannelTopicId(channel, topicId) {
    this.channels = this.channels.map((ch) =>
      ch === channel
        ? { ...ch, config: { ...ch.config, topic_id: topicId } }
        : ch
    );
  }

  @action
  setChannelTitle(channel, event) {
    this.channels = this.channels.map((ch) =>
      ch === channel
        ? { ...ch, config: { ...ch.config, new_topic_title: event.target.value } }
        : ch
    );
  }

  @action
  setChannelCategory(channel, event) {
    this.channels = this.channels.map((ch) =>
      ch === channel
        ? { ...ch, config: { ...ch.config, new_topic_category_id: parseInt(event.target.value, 10) || null } }
        : ch
    );
  }

  @action
  toggleSplitThreads(channel) {
    this.channels = this.channels.map((ch) =>
      ch === channel
        ? { ...ch, config: { ...ch.config, split_threads: !ch.config.split_threads } }
        : ch
    );
  }

  @action
  setDuplicateMode(event) {
    this.duplicateMode = event.target.value;
  }

  // ---------------------------------------------------------------------------
  // User mapping callback (passed to UserMappingRow)
  // ---------------------------------------------------------------------------

  @action
  onUserMappingChange(discordId, value) {
    this.userMappings = { ...this.userMappings, [discordId]: value };
  }

  // ---------------------------------------------------------------------------
  // Confirmation summary helpers
  // ---------------------------------------------------------------------------

  get channelsToImport() {
    return this.channels.filter((ch) => ch.config.action !== "skip");
  }

  get confirmSummary() {
    const mapped = Object.values(this.userMappings).filter(
      (v) => v !== "omit" && v !== "anonymous"
    ).length;
    const anonymous = Object.values(this.userMappings).filter(
      (v) => v === "anonymous"
    ).length;
    const omitted = Object.values(this.userMappings).filter(
      (v) => v === "omit"
    ).length;
    const unmapped = this.users.length - mapped - anonymous - omitted;
    return { mapped, anonymous, omitted: omitted + unmapped };
  }

  @action
  openConfirmModal() {
    if (this.channelsToImport.length === 0) return;
    this.importError = null;
    this.showConfirmModal = true;
  }

  @action
  closeConfirmModal() {
    this.showConfirmModal = false;
  }

  // ---------------------------------------------------------------------------
  // Import
  // ---------------------------------------------------------------------------

  @action
  async runImport() {
    this.showConfirmModal = false;
    this.phase = "importing";
    this.importError = null;

    const channelConfigs = this.channelsToImport.map((ch) => ({
      channel_id: ch.channel_id,
      action: ch.config.action,
      topic_id: ch.config.topic_id,
      new_topic_title: ch.config.new_topic_title,
      new_topic_category_id: ch.config.new_topic_category_id,
      split_threads: ch.config.split_threads,
    }));

    try {
      const fd = new FormData();
      fd.append("file", this.selectedFile);
      fd.append("channel_configs", JSON.stringify(channelConfigs));
      fd.append("user_mappings", JSON.stringify(this.userMappings));
      fd.append("duplicate_mode", this.duplicateMode);

      const result = await postFormData("/discordimport/import", fd);
      this.importResults = result.results ?? [];
      this.phase = "results";
    } catch (e) {
      this.importError = e.message;
      this.phase = "configure";
    }
  }

  @action
  reset() {
    this.phase = "upload";
    this.selectedFile = null;
    this.channels = [];
    this.users = [];
    this.userMappings = {};
    this.importResults = [];
    this.analyzeError = null;
    this.importError = null;
  }

  // ---------------------------------------------------------------------------
  // Template
  // ---------------------------------------------------------------------------

  <template>
    <div class="discord-import-page">
      <h1>Discord Import</h1>

      {{!-- ===== PHASE: UPLOAD ===== --}}
      {{#if (eq this.phase "upload")}}
        <div class="discord-import-upload">
          <label for="discord-archive-input">
            Archive (.zip or .tar.gz)
          </label>
          <input
            id="discord-archive-input"
            type="file"
            accept=".zip,.tar.gz,.tgz"
            {{on "change" this.onFileChange}}
          />

          {{#if this.analyzeError}}
            <p class="discord-import-error">{{this.analyzeError}}</p>
          {{/if}}

          <DButton
            @action={{this.analyzeArchive}}
            @label="discordimport.analyze_btn"
            @disabled={{(if this.selectedFile false true)}}
            @isLoading={{this.analyzing}}
            class="btn-primary"
          />
        </div>
      {{/if}}

      {{!-- ===== PHASE: CONFIGURE ===== --}}
      {{#if (eq this.phase "configure")}}
        {{#if this.importError}}
          <p class="discord-import-error">{{this.importError}}</p>
        {{/if}}

        {{!-- SECTION: Options --}}
        <section class="discord-import-options">
          <h2>Options</h2>
          <fieldset class="duplicate-mode-fieldset">
            <legend>Duplicate Posts</legend>
            <label>
              <input
                type="radio"
                name="duplicate-mode"
                value="ignore"
                checked={{eq this.duplicateMode "ignore"}}
                {{on "change" this.setDuplicateMode}}
              />
              Ignore — skip posts already imported
            </label>
            <label>
              <input
                type="radio"
                name="duplicate-mode"
                value="update"
                checked={{eq this.duplicateMode "update"}}
                {{on "change" this.setDuplicateMode}}
              />
              Update — overwrite existing post content
            </label>
          </fieldset>
        </section>

        {{!-- SECTION A: Channels --}}
        <section class="discord-import-channels">
          <h2>Channels</h2>
          {{#each this.channels as |channel|}}
            <div class="discord-channel-block">
              <div class="discord-channel-header">
                <strong>#{{channel.channel_name}}</strong>
                <span class="channel-meta">
                  {{channel.message_count}} messages
                  {{#if channel.threads.length}}
                    · {{channel.threads.length}} threads
                  {{/if}}
                </span>
              </div>

              <div class="discord-channel-config">
                <label>Action</label>
                <select {{on "change" (fn this.setChannelAction channel)}}>
                  <option value="skip" selected={{eq channel.config.action "skip"}}>Skip</option>
                  <option value="existing" selected={{eq channel.config.action "existing"}}>Add to existing topic</option>
                  <option value="create" selected={{eq channel.config.action "create"}}>Create new topic</option>
                </select>

                {{#if (eq channel.config.action "existing")}}
                  <label>Topic</label>
                  <TopicPickerInput
                    @onChange={{(fn this.setChannelTopicId channel)}}
                  />
                {{/if}}

                {{#if (eq channel.config.action "create")}}
                  <label>Title</label>
                  <input
                    type="text"
                    value={{channel.config.new_topic_title}}
                    {{on "input" (fn this.setChannelTitle channel)}}
                  />
                  <label>Category</label>
                  <select
                    {{on "change" (fn this.setChannelCategory channel)}}
                  >
                    <option value="">— select category —</option>
                    {{#each this.site.categories as |cat|}}
                      <option value={{cat.id}}>{{cat.name}}</option>
                    {{/each}}
                  </select>
                {{/if}}

                {{#if channel.threads.length}}
                  {{#if (eq channel.config.action "skip")}}
                    {{!-- thread option irrelevant when skipping --}}
                  {{else}}
                    <label class="split-threads-label">
                      <input
                        type="checkbox"
                        checked={{channel.config.split_threads}}
                        {{on "change" (fn this.toggleSplitThreads channel)}}
                      />
                      Split threads into separate topics
                    </label>
                    <p class="split-threads-hint">
                      Creates a new topic for each thread in the same category.
                      When unchecked, thread messages are appended to the primary topic.
                    </p>
                  {{/if}}
                {{/if}}
              </div>
            </div>
          {{/each}}
        </section>

        {{!-- SECTION B: Users --}}
        <section class="discord-import-users">
          <h2>Users</h2>
          <div class="users-table-header">
            <span>Discord User</span>
            <span>Discourse User</span>
          </div>
          {{#each this.users as |discordUser|}}
            <UserMappingRow
              @discordUser={{discordUser}}
              @onChange={{this.onUserMappingChange}}
              @initial={{
                (if discordUser.suggested_discourse_user_id
                  (hash
                    id=discordUser.suggested_discourse_user_id
                    username=discordUser.suggested_discourse_username
                  )
                  null
                )
              }}
            />
          {{/each}}
        </section>

        <DButton
          @action={{this.openConfirmModal}}
          @label="discordimport.confirm_btn"
          @disabled={{(if this.channelsToImport.length false true)}}
          class="btn-primary discord-import-confirm-btn"
        />
      {{/if}}

      {{!-- ===== PHASE: IMPORTING ===== --}}
      {{#if (eq this.phase "importing")}}
        <div class="discord-import-progress">
          <p>Importing… please wait.</p>
        </div>
      {{/if}}

      {{!-- ===== PHASE: RESULTS ===== --}}
      {{#if (eq this.phase "results")}}
        <div class="discord-import-results">
          <h2>Import Complete</h2>
          {{#each this.importResults as |result|}}
            <div class="import-result-block">
              <strong>#{{result.channel_name}}</strong>
              <span>
                {{result.posts_created}} posts imported
                {{#if result.posts_updated}}
                  · {{result.posts_updated}} updated
                {{/if}}
                {{#if result.posts_skipped}}
                  · {{result.posts_skipped}} skipped
                {{/if}}
              </span>
              <a href={{result.topic_url}} target="_blank" rel="noopener noreferrer">
                View Topic
              </a>
              {{#if result.thread_results.length}}
                <ul class="thread-results">
                  {{#each result.thread_results as |tr|}}
                    <li>
                      Thread: {{tr.thread_name}} —
                      {{tr.posts_created}} posts
                      {{#if tr.posts_updated}}· {{tr.posts_updated}} updated{{/if}}
                      ·
                      <a href={{tr.topic_url}} target="_blank" rel="noopener noreferrer">View</a>
                    </li>
                  {{/each}}
                </ul>
              {{/if}}
            </div>
          {{/each}}
          <DButton
            @action={{this.reset}}
            @label="Import Another"
            class="btn-default"
          />
        </div>
      {{/if}}

      {{!-- ===== CONFIRMATION MODAL ===== --}}
      {{#if this.showConfirmModal}}
        <div class="discord-import-modal-overlay">
          <div class="discord-import-modal">
            <h2>Confirm Import</h2>
            <p>You are about to import:</p>
            <ul>
              {{#each this.channelsToImport as |ch|}}
                <li>
                  <strong>#{{ch.channel_name}}</strong>
                  ({{ch.message_count}} messages
                  {{#if ch.threads.length}}
                    · {{ch.threads.length}} threads
                    {{#if ch.config.split_threads}}split{{else}}merged{{/if}}
                  {{/if}})
                  →
                  {{#if (eq ch.config.action "existing")}}
                    existing topic ID {{ch.config.topic_id}}
                  {{else}}
                    new topic "{{ch.config.new_topic_title}}"
                  {{/if}}
                </li>
              {{/each}}
            </ul>
            <p>
              Users: {{this.confirmSummary.mapped}} mapped,
              {{this.confirmSummary.anonymous}} anonymous,
              {{this.confirmSummary.omitted}} omitted.
            </p>
            <p><strong>This cannot be undone.</strong></p>
            <div class="modal-actions">
              <DButton
                @action={{this.closeConfirmModal}}
                @label="discordimport.confirm_cancel"
                class="btn-default"
              />
              <DButton
                @action={{this.runImport}}
                @label="discordimport.confirm_go"
                class="btn-danger"
              />
            </div>
          </div>
        </div>
      {{/if}}
    </div>
  </template>
}

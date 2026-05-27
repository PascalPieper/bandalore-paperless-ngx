# Feature Roadmap & Implementation Plan

> Companion to `PROJECT_AUDIT.md`. Read the audit first — terminology like *consumption plugin*, *parser plugin*, *workflow*, *PaperlessTask*, *CustomField*, *AIClient*, *LLM index* below refer to the systems documented there.
>
> The fork already ships with most of the *plumbing* (OCR, RAG, vector index, IMAP, custom fields, workflows). The features below are mostly **orchestration + UI + a few new domain models**, with two notable exceptions that need new infrastructure:
>
> 1. **Audio capture on Windows** (transcription / meetings) — needs a **native companion**, see §6.
> 2. **Web/link archiving** — needs a new fetch parser, see §7.
>
> Each section follows the same shape: *goal* → *what already exists* → *what to add (backend / frontend / AI)* → *suggested libraries* → *risks / open questions*.

---

## 0. Cross-cutting Decisions (apply to all features)

* **Reuse the `Document` model wherever the artefact "is a document"**. Receipts, invoices, transcripts, archived emails, web-page captures all become `Document` rows with the right `DocumentType` and a few targeted `CustomField`s. This keeps search, permissions, soft-delete, sharing, workflows, audit log, the LLM index, and the existing UI for free.
* **Add new domain concepts as their own Django apps** under `src/`: `paperless_receipts/`, `paperless_finance/`, `paperless_people/`, `paperless_transcribe/`, `paperless_archive/`, `paperless_research/`. Each ships with `apps.py`, `models.py`, `views.py`, `serialisers.py`, `tasks.py`, `migrations/`, `tests/`. Register them in `paperless/settings.py:INSTALLED_APPS`.
* **AI orchestration goes through the existing `paperless_ai.client.AIClient`** so that the user's `AIConfig` (Ollama vs OpenAI-like, model, endpoint) is honoured everywhere. Tool calls follow the pattern of `paperless_ai/base_model.py:DocumentClassifierSchema` (a pydantic schema → `get_function_tool` → `chat_with_tools`).
* **All new background work uses `@shared_task` with a `PaperlessTask.TaskType`** so the user sees progress in `/tasks/`. Add new enum values:
  ```python
  RECEIPT_EXTRACT = "receipt_extract", _("Receipt Extraction")
  INVOICE_EXTRACT = "invoice_extract", _("Invoice Extraction")
  STATEMENT_MATCH = "statement_match", _("Statement Reconciliation")
  TEXT_SUMMARIZE  = "text_summarize",  _("Text Summarization & Translation")
  LINK_ARCHIVE    = "link_archive",    _("Link Archive Fetch")
  TRANSCRIBE      = "transcribe",      _("Audio Transcription")
  RESEARCH        = "research",        _("Research Document Build")
  ```
* **All new API endpoints carry `@extend_schema`** and a corresponding TypeScript service under `src-ui/src/app/services/rest/`.
* **All new outbound HTTP** (Finom API, web fetches, LLM endpoints) is validated by `paperless.network.validate_outbound_http_url`.
* **All new "things" inherit `ModelWithOwner`** + register with `auditlog` under `if settings.AUDIT_LOG_ENABLED:`.
* **Internationalisation**: wrap human-facing strings in `gettext_lazy` (backend) and Angular `i18n` (frontend) from day one.

---

## 1. Receipt Scanning (Spend Tracking)

### Goal
Drop a photo or PDF of a receipt into Paperless → it becomes a `Document` with `DocumentType=Receipt`, auto-tagged, with extracted **vendor / date / line items / total / currency / payment status**, contributing to a *total spendings* dashboard and reconcilable against bank statements.

### Already in place
* OCR for PDFs and images (`tesseract.py`).
* `CustomField.FieldDataType.MONETARY` with `value_monetary_amount` generated decimal column → spending sums via `Sum("custom_fields__value_monetary_amount")`.
* `Document.created` (DateField) — perfect for "date of issuing".
* Workflows can auto-tag on `CONSUMPTION` based on content match → already enough for crude rule-based tagging.
* RAG classifier (`paperless_ai/ai_classifier.py`) — covers title/tags/correspondent extraction; we extend its schema.

### What to add

**1a) Receipt extraction task** — *new app `paperless_receipts/`*
* New `CustomField` seeds (run once via data migration): `receipt.total` (monetary), `receipt.subtotal` (monetary), `receipt.tax` (monetary), `receipt.currency` (string, 3 chars), `receipt.vendor` (string, mirrors correspondent), `receipt.payment_method` (select: cash/card/transfer/other), `receipt.paid` (boolean), `receipt.item_count` (integer), `receipt.line_items` (longtext, JSON).
* Seed `DocumentType` "Receipt" with auto-matching keywords.
* `@shared_task receipt_extract(document_id)` triggered by:
  * a `Workflow` with `DOCUMENT_ADDED` trigger filtered on `document_type=Receipt`, or
  * a new `ConsumeTaskPlugin` that runs after `ConsumerPlugin` *only when* a receipt classifier flags the doc (preferred: it gets the fields before the user even sees the document).
* Implementation (pseudocode):
  ```python
  class ReceiptSchema(BaseModel):
      vendor: str
      date: date
      currency: str
      subtotal: Decimal
      tax: Decimal
      total: Decimal
      items: list[ReceiptLineItem]
      payment_method: Literal["cash","card","transfer","other","unknown"]

  def extract_receipt(doc: Document) -> ReceiptSchema:
      client = AIClient()
      tool = get_function_tool(ReceiptSchema)
      msg = ChatMessage(role="user", content=RECEIPT_PROMPT.format(content=doc.content[:8000]))
      result = client.llm.chat_with_tools(tools=[tool], user_msg=msg, chat_history=[])
      kwargs = client.llm.get_tool_calls_from_response(result, error_on_no_tool_call=True)[0].tool_kwargs
      return ReceiptSchema(**kwargs)
  ```
* On success: populate `CustomFieldInstance`s, set `Document.created` to the extracted date, attach the "Receipt" type.

**1a) Spendings dashboard** — *frontend*
* New dashboard widget in `components/dashboard/widgets/` querying a new aggregate endpoint:
  * `GET /api/finance/spendings/?from=…&to=…&group_by=month|vendor|tag` → returns `{period, currency, total}`.
* Backend view: `StatisticsView` already exists in `documents/views.py` — extend or add `SpendingStatisticsView`. Use `Document.objects.annotate(total=Sum("custom_fields__value_monetary_amount", filter=Q(custom_fields__field__name="receipt.total")))`.

**1b) Statement reconciliation** — *new app `paperless_finance/`*
* Models:
  * `BankAccount(owner, name, provider, iban, currency, external_id)` — `provider` is a select of `manual | finom | csv-import`.
  * `BankStatement(account, start_date, end_date, source_file→Document, imported_at)` — the *Kontoauszug screen* shows one of these.
  * `StatementLine(statement, posted_at, amount, currency, counterparty, raw_description, balance_after, hash)` — unique `(statement, hash)`.
  * `StatementMatch(line, document, confidence, matched_at, matched_by_user)` — many-to-many bridge.
* Ingestion paths:
  1. **Manual CSV / MT940 / CAMT.053 upload** — `mt-940` (`pip install mt-940`) or `camt-053` (`pip install camtparser`) parsers.
  2. **Finom API** (REST + OAuth2). Add `FinomClient` in `paperless_finance/finom.py`; configure via `ApplicationConfiguration` (new fields `finom_client_id`, `finom_client_secret`, `finom_token`, expirations). Schedule a Celery beat task `finom_sync_statements` (daily). Finom currently exposes REST (`https://api.finom.co/`) — confirm exact endpoints at integration time; abstract behind a `BankProvider` interface so other providers (Tink, GoCardless Open Banking, Plaid) can be added.
  3. **Webhook** for push notifications (later).
* Matching algorithm (`paperless_finance/matching.py`):
  * Stage 1: deterministic — amount ± epsilon AND date within ±5 days AND currency match.
  * Stage 2: similarity — `rapidfuzz.process.extract` between `StatementLine.counterparty/description` and `Document.correspondent.name + title + content[:500]`.
  * Stage 3 (optional, behind feature flag): LLM disambiguation when multiple Stage 2 candidates → ask `AIClient` to pick one with a confidence score.
* UI:
  * New route `/finance/statements` → `StatementsListComponent`.
  * `/finance/statements/:id` → split view, statement lines on the left, documents on the right, drag-drop or "auto-match" button.
  * Reconciliation status badge on each `Document` ("Matched to BBVA-2026-04-12 line").

**1c) Auto-tagging / date / currency** — *already covered by 1a* (receipt schema) **plus**:
* Add a `WorkflowAction` preset in a data migration that on a successful receipt extraction:
  * adds tag `Receipt` and a tag for the currency (`EUR`, `USD`, …),
  * sets `Correspondent` from `ReceiptSchema.vendor` (creating it if missing via `paperless_ai.matching.match_correspondents_by_name`).

**1d) "Has been paid" toggle** — *frontend*
* Add a toolbar button in `document-detail` that flips `CustomFieldInstance(field="receipt.paid")` to `true` and writes a Note ("Marked as paid by <user> at <ts>"). Keep server-side `WorkflowTrigger.WorkflowTriggerType.DOCUMENT_UPDATED` listening if any downstream action needs it (e.g. notify dashboard).

### Suggested libraries
| Need | Library |
| --- | --- |
| OCR (already) | `ocrmypdf`, `tesseract` |
| HEIC support (phone photos) | already supported via `image/heic` in tesseract MIME map |
| CSV bank import | `pandas` (heavy) or stdlib `csv` |
| MT940 / CAMT.053 | `mt-940`, `camtparser` |
| Finom REST | `httpx` (already transitively present via llama-index), `oauthlib` |
| Currency normalisation | `babel.numbers` (already in deps) |
| Receipt-specific OCR boost (optional) | `donut-python` or Azure DI's "prebuilt-receipt" model — `azure-ai-documentintelligence` is **already** a dep; if `LLM_BACKEND` is OpenAI-like the existing `RemoteDocumentParser` can be reused |

### Risks
* Receipt OCR quality on phone photos is fragile. Pre-processing helpers (`Pillow` rotate/contrast, `opencv-python-headless` for deskew/crop) may be required. Consider exposing this as a `OcrPreprocessing` configurable.
* Finom API is country/feature-limited — fall back to CSV import for v1.

---

## 2. Invoice Scanning (Income Tracking)

Architecturally **identical to §1** with the polarity flipped. Re-use:
* the same extraction pipeline (different prompt + schema: `InvoiceSchema { invoice_number, issue_date, due_date, customer, vendor, line_items, subtotal, tax, total, currency, payment_terms, paid }`),
* the same `paperless_finance` reconciliation,
* the same dashboard endpoint (filter by sign of amount or by `DocumentType=Invoice`).

**Key differences:**
* Seed `DocumentType` "Invoice".
* New `CustomField`s: `invoice.number` (string, unique check via Workflow not DB constraint), `invoice.issue_date`, `invoice.due_date` (both date), `invoice.customer` (string), `invoice.paid` (bool), `invoice.amount` (monetary), `invoice.currency` (string), `invoice.line_items` (longtext).
* Dashboard widget renders **profits** by summing `invoice.amount` where `invoice.paid=true`.
* "Has been paid" button mirrors §1d.

**Outgoing invoice generation** (creating invoices, not just reading them) is *out of scope* of this plan — that's a different system.

---

## 3. Text Documents — Summaries, Tagging, Recipient, Favourites, AI Search

### Goal
Any text-bearing document is automatically (a) summarised into bullet points in both original language and English, (b) tagged with semantic labels, (c) linked to a *recipient* (a Person, see §7), (d) favouritable into categories, and (e) searchable via natural language.

### Already in place
* `Document.content`, `Document.created`, `Document.added` ✅ (3c).
* `langdetect` for language detection ✅.
* RAG classifier for tags ✅ (3b — extend its prompt).
* `paperless_ai.chat.stream_chat_with_documents` for chat-style search.
* Full-text search via Tantivy.
* `Correspondent` ≈ "recipient" — but we'll add a richer Person model in §7; until then map "direct recipient" to a `CustomField(documentlink → People)` or directly to `Correspondent`.

### What to add

**3a) Summarisation + translation**
* New `@shared_task summarize_document(document_id)` enqueued by a `DOCUMENT_ADDED` workflow (or by `ConsumerPlugin` post-step). Output is stored on the Document via two new `CustomField`s (longtext): `summary.bullets_native`, `summary.bullets_en`, plus `summary.language` (string).
* Prompt template (place in `paperless_ai/prompts/summary.py`):
  ```
  You are a summarisation assistant. Given the document below, do TWO things:
  1) Detect the language (ISO 639-1).
  2) Produce 5-10 concise bullet points capturing the essential information.
  3) Translate the bullets to English (skip if already English).
  Return JSON: {language, bullets_native: [...], bullets_en: [...]}.
  ```
* Use `AIClient` + a pydantic `SummarySchema` tool call.
* Long docs: chunk via `truncate_content` from `paperless_ai/indexing.py` (already wired to PromptHelper), summarise per chunk, then "summary of summaries".

**3b) Automatic tags**
* Extend the existing RAG `DocumentClassifierSchema` (see `paperless_ai/base_model.py`) to include a fixed top-level taxonomy: `Notes | Official Documents | Protocol | Correspondence | Research | Reference | Other`. Seed those tags. After the LLM returns suggested tag names, resolve them via `paperless_ai.matching.match_tags_by_name`; create new tags only if `auto_create_tags` is enabled (new `ApplicationConfiguration` field).
* Add a per-doc tag for the detected language (e.g. `lang:de`, `lang:en`) — seeded via data migration with sensible colours.

**3c) Creation date / added date** — *no change needed* (already on `Document`).

**3d) Direct recipient**
* Until §7 lands: store as `CustomField(documentlink → Correspondent)` or simply continue using the existing `Document.correspondent`.
* After §7: add a `CustomField(documentlink → Person)` called `recipient`.
* The summary task can extract recipient hints (Dear X, To: X) and pre-fill.

**3e) Favourites with categories**
* New model `paperless_favorites.Favorite`:
  ```python
  class FavoriteCategory(ModelWithOwner):
      name = CharField(...)
      icon = CharField(...)  # bootstrap-icon name
      color = CharField(...)

  class Favorite(ModelWithOwner):
      document = FK(Document, related_name="favorites", on_delete=CASCADE)
      category = FK(FavoriteCategory, on_delete=SET_NULL, null=True)
      note = CharField(blank=True)
      created = DateTimeField(auto_now_add=True)
      class Meta:
          constraints = [UniqueConstraint(fields=["document","owner","category"], name="unique_fav")]
  ```
* DRF ViewSets + routes; star icon in document-list + a "Favourites" entry in the sidebar with category facets.
* The categories also feed into the natural-language search (§3f) as filters: "show me my favourite contracts".

**3f) AI-driven natural-language search**
* `paperless_ai.chat.stream_chat_with_documents` already does RAG over a *user-selected* list. Extend the contract to accept **no `documents` list** → search the entire visible corpus:
  * Add `GET /api/search/ai/?q=…` (new view `AISearchView`).
  * Stage 1: ask the LLM to convert `q` into a structured query (`{keywords, filters: {tags, types, date_range, correspondents}, semantic_query}`) via a `QueryPlanSchema` tool.
  * Stage 2: run a *hybrid* retrieval — Tantivy keyword search filtered by the structured filters, plus FAISS top-k on `semantic_query`. Merge by reciprocal-rank fusion.
  * Stage 3: stream the LLM's answer with references (re-use the `CHAT_METADATA_DELIMITER` trailer convention from `paperless_ai/chat.py`).
* Frontend: new search bar at the top of `app-frame` that, when prefixed with `?` or invoked via Cmd+K, opens an inline answer panel with cited documents (component `components/chat/ai-search.component.ts`, sharing `chat.service.ts` infra).

### Risks
* Summaries can hallucinate; keep them advisory and store the model+timestamp used (`summary.model`, `summary.generated_at` fields) for reproducibility/regen.
* RAG over the whole corpus requires the LLM index to be kept up-to-date — make sure `update_llm_index` is configured and `llm_index_enabled` is on; surface a banner in the dashboard if it isn't.

---

## 4. E-mail Integration

### Already in place
* IMAP + Gmail/Outlook OAuth via `paperless_mail`.
* `MailRule` system that converts attachments and/or full `.eml` into Documents.
* `MailDocumentParser` to render `.eml` as PDF via Gotenberg.
* `ProcessedMail` ledger to avoid double-processing.

### What to add

**4a) Archive important e-mails as Documents**
* Extend `MailRule` with a new `ConsumptionScope` value `EML_ALWAYS_IMPORTANT` and/or a new boolean `auto_classify_importance`.
* New `@shared_task classify_mail_importance(message_uid, rule_id)` invoked **before** `consume_file` is enqueued. Calls `AIClient` with a small prompt + the email headers/snippet, returns `{important: bool, reason: str, suggested_tags: [...]}` via a pydantic schema. If `important=true`, proceed; otherwise mark as read and skip.

**4b) Smarter attachment routing**
* New optional `MailRule.attachment_routing` JSON field with regex/MIME-based hints, plus a fallback LLM step:
  * For each attachment, call AI: "Classify this filename + first 4 KB OCR text → {receipt|invoice|contract|other}".
  * Map the result to a `DocumentType` and tag set before calling `consume_file`. Implementation lives in `paperless_mail/preprocessor.py` as a new `MailAttachmentClassifier(MailMessagePreprocessor)` subclass (the abstract base is already there).

**4c) Read sent e-mails**
* IMAP usually exposes a `Sent`/`[Gmail]/Sent Mail` folder. Allow `MailRule.folder` to point at it and add a new boolean `treat_as_outgoing` so the resulting Document is tagged `Outgoing` and `correspondent` is taken from `To:` instead of `From:`.
* For Outlook/Gmail OAuth, the existing token already includes scopes for the whole mailbox; no additional permission grant needed.

### Risks
* Volume — large mailboxes can flood. Throttle via the existing scheduler.
* PII — log carefully (don't log full bodies).

---

## 5. Transcription (Meetings / Dictation)

### Goal
User taps a global hotkey → both Windows system audio (loopback) *and* microphone are captured → at stop, the recording is uploaded to Paperless → transcribed → cleaned (small-talk filter, summary) → stored as a `Document(DocumentType=Transcript)` with attached screenshots and a list of attendees (`Person`s, §7).

### Reality check
The browser cannot capture **system loopback audio on Windows** — `getDisplayMedia({audio:true})` only works for tabs/the entire screen on Chromium, and is unreliable for system mix. **A native helper is required.**

### Architecture

```
┌─────────────────────────────────────────┐         REST + WS
│  Paperless-Capture (Windows .exe)       │ ─────────────────┐
│  - Tray icon + global hotkey            │                  ▼
│  - WASAPI loopback (system) + WASAPI    │     ┌────────────────────────────┐
│    capture (mic) via PyAudioWPatch /    │     │  paperless_transcribe app  │
│    soundcard + sounddevice              │     │  POST /api/transcripts/    │
│  - Mixes to single WAV/Opus chunked     │     │    upload (resumable)      │
│  - Captures screenshots (mss)           │     │  POST /api/transcripts/    │
│  - Stores attendees / notes             │     │    {id}/screenshot         │
│  - Calls REST API w/ token              │     │  POST /api/transcripts/    │
└─────────────────────────────────────────┘     │    {id}/finalize           │
                                                │  → enqueues transcribe task│
                                                └────────────┬───────────────┘
                                                             ▼
                                                 ┌───────────────────────┐
                                                 │ whisper.cpp / faster-  │
                                                 │ whisper / OpenAI       │
                                                 │ transcription API      │
                                                 └────────────┬──────────┘
                                                              ▼
                                                  Document(type=Transcript)
                                                  + CustomFields(attendees,
                                                    duration, conclusion_only)
                                                  + linked Screenshots
                                                  + linked People (§7)
```

### Companion app (separate repo: `paperless-capture`)
* Language: **Python + PySide6** (cross-platform tray UI; easier than C# for shared logic with the backend) or **Tauri/Rust + a small webview** (smaller distributable). Recommend **Python + PyInstaller** for v1 to share schemas with backend.
* Key libs:
  * `PyAudioWPatch` (fork of PyAudio with WASAPI loopback) — captures *system* audio.
  * `sounddevice` — captures the microphone.
  * `numpy` to mix two streams to mono PCM; resample to 16 kHz.
  * `opuslib` or `pyogg` to compress chunks.
  * `mss` for screenshots.
  * `keyboard` or `pynput` for global hotkey.
  * `httpx` for resumable upload (use **tus protocol** with the `tuspy` server-side plugin, or simple chunked POSTs).
  * `pystray` + a small Qt dialog for end-of-recording form (title, attendees autocompletion against `/api/people/?search=`).
* Authentication via a long-lived API token (`/api/token/` endpoint already exists).

**5a/b/c/d/e — Server side: `paperless_transcribe/`**
* Models:
  * `TranscriptionSession(owner, started_at, ended_at, raw_audio_file→FileField, status, source: enum{microphone|loopback|mixed})`
  * `TranscriptionSegment(session, start_ms, end_ms, speaker, text, language)`
  * `TranscriptionScreenshot(session, captured_at, image→FileField)`
  * `TranscriptionAttendee(session, person→FK(Person, §7), role)`
* Resumable upload endpoint (Django chunked, or `django-tus`).
* On `finalize`, enqueue `transcribe(session_id)`:
  1. Run `faster-whisper` (`pip install faster-whisper`, ships with CPU build) on the WAV — model size from `AIConfig.transcription_model` (`tiny|base|small|medium|large-v3`). GPU optional via `torch` (already a dep).
  2. Diarize speakers via `pyannote.audio` (heavy dep, optional behind feature flag `TRANSCRIPTION_DIARIZATION_ENABLED`).
  3. Build segments → `TranscriptionSegment` rows.
  4. **5e** small-talk filter / condensation: hand the full transcript to `AIClient` with a `CondenseSchema {summary: str, conclusions: [str], action_items: [{owner, due, text}], filtered_transcript: str}`.
  5. Render final document content (Markdown → HTML → PDF via Gotenberg) including the filtered transcript + screenshots inlined + attendee list.
  6. Create the `Document` (the existing `ConsumableDocument` + `consume_file` pipeline works — just feed the generated PDF in). Auto-tag `Transcript`, `Meeting`. Link to people via a `CustomField(documentlink → Person)` named `attendees`.

### Risks / open questions
* **No system audio on iOS/macOS browser** — companion app is per-platform; release Windows first.
* Privacy: recording system audio may capture content the user doesn't own. Add a clear consent dialog + watermark in the produced document.
* Whisper accuracy on heavily accented or technical speech — let the user choose model size + language hint.
* The companion app shouldn't be required for users that don't transcribe — keep the whole `paperless_transcribe` app behind an installed-apps flag.

---

## 6. Folder / Link Archive (Web Pages, Drive Links, …)

### Goal
Save a URL or a Google Drive link → Paperless fetches it, renders/snapshots it, produces a summary and tags, stores it as a `Document` so it's searchable and survives link rot.

### What to add — *new app `paperless_archive/`*
* Model `LinkArchive(url, kind: enum{webpage|gdrive|onedrive|s3|generic_file}, document→OneToOne(Document), fetched_at, http_status, content_hash, sha256, original_title)`.
* `@shared_task archive_link(url, owner_id, kind=None, …)` flow:
  1. Validate URL through `paperless.network.validate_outbound_http_url`.
  2. Detect `kind`. For Drive/OneDrive: if credentials are configured (per-user OAuth via allauth providers), use the API; else fall back to public-fetch.
  3. Fetch:
     * **Webpages**: render via **Playwright (chromium-headless)** for JS-heavy pages → save PDF + screenshot + extracted Readability text (`readability-lxml`). Alternative: `monolith` CLI to capture a fully-inlined HTML.
     * **Drive folders**: list files, download each (respecting quotas) → recursively archive into a *folder Document* (use the existing `root_document/version_index` mechanism, or model a new `DocumentBundle`).
  4. Hand the PDF to `consume_file` like any other document; auto-tag `WebArchive`, `Link`, plus the source domain as a tag.
* **6a)** Summary + tags: the existing §3a summary task runs on the resulting document automatically (it's just another `DOCUMENT_ADDED`).
* Reverse-lookup: `LinkArchive.url` indexed unique-per-owner so duplicates are detected; offer "refresh" action that re-fetches and creates a *version* (using `root_document` versioning).

### Suggested libraries
| Need | Library |
| ---- | ------- |
| Render JS-heavy pages | `playwright` (`playwright install chromium`) — heavy dep, but most accurate |
| Lightweight HTML fetch | `httpx` + `readability-lxml` + `beautifulsoup4` |
| Single-file HTML | `monolith` (Rust binary) — optional |
| Drive/OneDrive | `google-api-python-client` / `msgraph-sdk` (OAuth handled via allauth) |

### Risks
* Playwright adds ~400 MB to the image; consider shipping a separate `paperless-archiver` worker container that listens on a dedicated celery queue (`-Q link_archive`).
* Authenticated content (paywalls, intranets) — out of scope of v1.
* Robots.txt / ToS compliance: honour `robots.txt` by default (use `urllib.robotparser`); make this overrideable per-user but not globally.

---

## 7. People Archive

### Goal
A proper `Person` directory with tags, search, categories, used as `recipient` (§3d), `attendees` (§5d), and a richer alternative to `Correspondent`.

### Why not just use `Correspondent`?
`Correspondent` is a `MatchingModel` (matching rule + name) — it's designed to *attach the right name to incoming docs*, not to hold a contact card. We **keep `Correspondent`** for matching and **add `Person`** for the contact record, with an optional `Correspondent ↔ Person` FK so the two stay in sync.

### Model — *new app `paperless_people/`*
```python
class PersonCategory(ModelWithOwner):
    name = CharField(...)         # Freelancer / Influencer / Investor / Client / …
    color = CharField(...)
    icon = CharField(...)

class Person(ModelWithOwner):
    full_name = CharField(...)
    aliases = JSONField(default=list)        # list[str]
    email = EmailField(blank=True, null=True, db_index=True)
    secondary_emails = JSONField(default=list)
    phone = CharField(blank=True, max_length=64)
    date_of_birth = DateField(null=True, blank=True)
    company = CharField(blank=True, max_length=128)
    job_title = CharField(blank=True, max_length=128)
    address = TextField(blank=True)
    website = URLField(blank=True)
    notes = TextField(blank=True)            # free-form
    summary = TextField(blank=True)          # AI-generated, refreshable
    categories = ManyToManyField(PersonCategory, related_name="people", blank=True)
    tags = ManyToManyField(Tag, blank=True, related_name="people")  # reuse tag system
    correspondent = OneToOneField(Correspondent, on_delete=SET_NULL, null=True, blank=True, related_name="person")
    avatar = ImageField(upload_to="people/avatars/", null=True, blank=True)
    created = DateTimeField(auto_now_add=True)
    modified = DateTimeField(auto_now=True)

    class Meta:
        constraints = [UniqueConstraint(fields=["owner","email"], name="unique_person_email", condition=Q(email__isnull=False))]
```

* ViewSet + serialiser; `search_fields = ["full_name","email","aliases","company","summary"]`, `filterset_fields = ["categories","tags"]`.
* Embedding hook: on save, push `Person.full_name + summary + notes` into the LLM index (extend `indexing.py` to support arbitrary `IndexableEntity`s by introducing a small `LlamaIndexable` protocol — or simpler, mirror each Person as a hidden Document of type `PersonProfile`).
* AI assist: button "Generate / refresh summary" — calls `AIClient` with all documents in which this person appears (joined via `correspondent` and any `CustomField(documentlink→Person)`).
* Frontend: route `/people` + `/people/:id`, list with category facets, contact-card detail page with linked documents grid.

**7b)** Search by tags / summary is automatic given the model above + DRF filters. For full-text fuzzy across `aliases` and `summary`, use Postgres trigram (`django.contrib.postgres.indexes.GinIndex` + `TrigramSimilarity`) when the DB is Postgres; otherwise `rapidfuzz` in-memory fallback for small datasets.

**7c)** Categories: see `PersonCategory` model.

---

## 8. "Summary Paper AI" — Natural-Language Research Documents

### Goal
User asks a natural question → backend gathers the most relevant artefacts (documents, transcripts, people, statements, …) → composes a **research document** with citations and stores it as a `Document(DocumentType=Research)`.

### What to add — *new app `paperless_research/`*

* Model `ResearchQuery(owner, question, created, status, document→FK(Document, null=True), parameters JSON)`.
* `@shared_task research(query_id)`:
  1. **Plan**: ask LLM to produce a `ResearchPlanSchema {sub_questions: [...], required_artefact_types: [...], filters: {date_range, tags, people, ...}}`.
  2. **Retrieve**: for each sub-question, do hybrid retrieval (Tantivy + FAISS, as in §3f); also pull related `Person`/`StatementLine` rows.
  3. **Synthesize**: per sub-question, ask LLM for a paragraph with `[doc_id]` citation tokens. Use `AIClient.run_chat` with streaming.
  4. **Assemble**: render Markdown with sections (Intro / Per-sub-question / Findings / Open questions / Sources). Convert to PDF via Gotenberg.
  5. **Consume** the resulting PDF through `consume_file` so it becomes a normal `Document(type=Research)`; link back to source documents using a `CustomField(documentlink → Document, many=true)` called `sources`.
  6. **References**: also write a sidecar JSON in `Note` or a `ResearchCitation` model so the frontend can render hover-cards.
* Endpoint: `POST /api/research/` `{question, scope}` → returns a `task_id`; frontend listens on `/ws/status/` and navigates to the resulting Document when ready.
* UI: a "Research" entry in the sidebar, plus a Cmd+K modal "Ask a question across everything" that mirrors §3f but with a "Save as research document" toggle.

### Risks
* Long-running, LLM-heavy → must be a celery task with progress reporting (`ProgressManager`) and cancellation (`PaperlessTask` already supports REVOKED).
* Citation hallucination — *only* include `[doc_id]` for ids that were actually retrieved; post-validate before persisting.
* Costs — for OpenAI-like backends, surface token-usage in `PaperlessTask.result_data`.

---

## 9. Suggested Implementation Order & Milestones

| Milestone | Scope | Why this order |
| --- | --- | --- |
| **M1** | §0 cross-cutting + §3a–b (summary/tagging) + §3e (favourites) + §3f (NL search) | Lowest-risk; leverages existing AI plumbing; immediately useful |
| **M2** | §1 Receipts (incl. dashboard) and §2 Invoices in parallel | Share most of the codebase; deliver financial visibility |
| **M3** | §7 People + §3d (recipient using Person) | Foundational for §5 and §8 |
| **M4** | §4 E-mail enhancements | Builds on §1/§2 (attachment routing) and §7 (people-from-email auto-creation) |
| **M5** | §1b Finance / statement reconciliation | Needs Receipts & Invoices already populated |
| **M6** | §6 Link Archive | Standalone, can slip in earlier if Playwright container is acceptable |
| **M7** | §5 Transcription server + Windows companion | Most complex; companion app is its own project |
| **M8** | §8 Research Document AI | Capstone — depends on all the rest being indexed |

---

## 10. Library Shopping List (new deps)

| Area | pip package |
| --- | --- |
| Receipts/Invoices schema | (none — pydantic already in via llama-index) |
| Banking import | `mt-940`, `camtparser` |
| Finom client | `httpx` (existing), `authlib` |
| Transcription | `faster-whisper`, optional `pyannote.audio`, optional `openai-whisper` |
| Link archive | `playwright`, `readability-lxml`, `beautifulsoup4` (likely already transitive) |
| Drive/OneDrive | `google-api-python-client`, `msgraph-sdk` |
| People trigram (Postgres) | none — uses `django.contrib.postgres` |
| Person avatars | `Pillow` (already present transitively via ocrmypdf chain) |
| Resumable uploads | `django-tus` (or hand-rolled chunked POSTs) |

### Frontend
| Area | npm package |
| --- | --- |
| Charts (spendings dashboard) | `apexcharts` + `ng-apexcharts` *or* `ngx-charts` |
| Markdown rendering for summaries/research | `marked` + `dompurify` |
| Audio waveform (transcript review) | `wavesurfer.js` |
| Cmd+K palette | `ngx-command-bar` (or roll your own with Angular CDK overlay) |

---

## 11. Native / Windows Concerns Summary

| Feature | Browser-only OK? | Needs companion? |
| --- | --- | --- |
| Receipts / Invoices upload | ✅ (file input, drag-drop, camera via `<input capture>`) | No |
| E-mail integration | ✅ (server-side IMAP) | No |
| Text doc AI | ✅ | No |
| Favourites / People / Research | ✅ | No |
| Link archive | ✅ (paste URL) | No |
| Transcription microphone-only | ✅ (`getUserMedia({audio:true})`) | No |
| Transcription with **system audio loopback** | ❌ | **Yes — Windows companion (PySide6/PyAudioWPatch)** |
| Global hotkey | ❌ (browsers can't capture system-wide keys) | Yes (same companion) |
| OS-level file dialogs / shell extensions | partial via File System Access API | Optional later |

The Paperless backend itself runs in a Linux container — it does **not** install natively on Windows, and we should not try to change that. Windows users either:
* run Docker Desktop / WSL2 hosting the backend, and
* (for transcription) install the standalone **paperless-capture** companion that uploads via HTTPS to the backend.

---

## 12. Guidance for Subsequent LLM Sessions

When extending this plan or starting implementation, point the next assistant at the relevant section + these anchor files:

* Receipts/Invoices: `documents/models.py` (`CustomField`, `CustomFieldInstance`), `paperless_ai/client.py`, `paperless_ai/base_model.py`.
* Statements: think *new app*; mimic `paperless_mail` structure (models / mail.py-equivalent / tasks.py / views.py / oauth.py).
* Text AI: `paperless_ai/ai_classifier.py`, `paperless_ai/chat.py`, `paperless_ai/indexing.py`.
* E-mail: `paperless_mail/mail.py`, `paperless_mail/preprocessor.py`, `paperless_mail/models.py:MailRule`.
* Transcription server: re-read `documents/tasks.py:consume_file` to understand the canonical "produce a Document from a generated file" flow.
* Link archive: `documents/consumer.py` (how `ConsumableDocument` is built) + `paperless/network.py`.
* People: `documents/permissions.py` (`get_objects_for_user_owner_aware`), `documents/models.py:MatchingModel`/`Correspondent`.
* Research: `paperless_ai/chat.py` (streaming + reference trailer pattern) + `documents/tasks.py:consume_file` (final document creation).

Always:
* Add a `PaperlessTask.TaskType` value for any new background work.
* Route LLM calls through `AIClient` (don't import `llama-index` directly elsewhere).
* Add a TS interface in `src-ui/src/app/data/` AND a service in `services/rest/` for every new resource.
* Provide a `@extend_schema` block; the OpenAPI ↔ TS contract must stay in sync.
* Write at least one pytest covering the happy path + permissions (owner-aware).
* Respect ruff/mypy: every new file starts type-clean.

*End of feature plan.*

